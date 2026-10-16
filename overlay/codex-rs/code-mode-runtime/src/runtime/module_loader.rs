//! Running the script as an ES module, and settling the promises that tie it to the host.

use rquickjs::Ctx;
use rquickjs::Error;
use rquickjs::Module;
use rquickjs::Promise;
use rquickjs::Value;
use rquickjs::loader::ImportAttributes;
use rquickjs::loader::Loader;
use rquickjs::loader::Resolver;
use rquickjs::module::Declared;
use rquickjs::promise::PromiseState;
use serde_json::Value as JsonValue;

use super::CompletionState;
use super::SharedState;
use super::exit_requested;
use super::is_terminating;
use super::value::error_text;
use super::value::json_to_value;
use super::value::throw_string;
use super::value::value_to_error_text;

/// Scripts get no module system at all: every `import`, static or dynamic, fails with the
/// same message the V8 runtime produced.
pub(super) struct RejectImports;

impl Resolver for RejectImports {
    fn resolve<'js>(
        &mut self,
        ctx: &Ctx<'js>,
        _base: &str,
        name: &str,
        _attributes: Option<ImportAttributes<'js>>,
    ) -> rquickjs::Result<String> {
        Err(throw_string(
            ctx,
            &format!("Unsupported import in exec: {name}"),
        ))
    }
}

impl Loader for RejectImports {
    fn load<'js>(
        &mut self,
        ctx: &Ctx<'js>,
        name: &str,
        _attributes: Option<ImportAttributes<'js>>,
    ) -> rquickjs::Result<Module<'js, Declared>> {
        Err(throw_string(
            ctx,
            &format!("Unsupported import in exec: {name}"),
        ))
    }
}

/// Runs queued promise jobs (QuickJS's microtask checkpoint) until none are left, or until the
/// cell exits or is being terminated.
pub(super) fn run_pending_jobs(ctx: &Ctx<'_>) {
    loop {
        if is_terminating(ctx) {
            break;
        }
        if !ctx.execute_pending_job() {
            break;
        }
    }
}

pub(super) fn evaluate_main_module<'js>(
    ctx: &Ctx<'js>,
    source_text: &str,
) -> Result<Option<Promise<'js>>, String> {
    let promise = match Module::evaluate(ctx.clone(), "exec_main.mjs", source_text) {
        Ok(promise) => promise,
        Err(Error::Exception) => {
            let exception = ctx.catch();
            return Err(value_to_error_text(ctx, &exception));
        }
        Err(error) => return Err(error.to_string()),
    };
    run_pending_jobs(ctx);
    Ok(Some(promise))
}

pub(super) fn resolve_tool_response<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    id: &str,
    response: Result<JsonValue, String>,
) -> Result<(), String> {
    let pending = state
        .borrow_mut()
        .pending_tool_calls
        .remove(id)
        .ok_or_else(|| format!("unknown tool call `{id}`"))?;

    // Restoring the handles also releases them: live promises retain their results.
    let resolve = pending
        .resolve
        .restore(ctx)
        .map_err(|error| error_text(ctx, error))?;
    let reject = pending
        .reject
        .restore(ctx)
        .map_err(|error| error_text(ctx, error))?;
    match response {
        Ok(result) => {
            let value = json_to_value(ctx, &result)
                .ok_or_else(|| "failed to serialize tool response".to_string())?;
            resolve
                .call::<_, ()>((value,))
                .map_err(|error| error_text(ctx, error))
        }
        Err(error_message) => {
            let value = rquickjs::String::from_str(ctx.clone(), &error_message)
                .map_err(|_| "failed to allocate tool error".to_string())?
                .into_value();
            reject
                .call::<_, ()>((value,))
                .map_err(|error| error_text(ctx, error))
        }
    }
}

pub(super) fn completion_state<'js>(
    ctx: &Ctx<'js>,
    pending_promise: Option<&Promise<'js>>,
) -> CompletionState {
    // exit() can leave the module promise pending: QuickJS never rejects an async function's
    // promise with an uncatchable error. This runtime belongs to the exiting cell; never pump
    // or await it again.
    if exit_requested(ctx) {
        return CompletionState::Completed { error_text: None };
    }

    let Some(promise) = pending_promise else {
        return CompletionState::Completed { error_text: None };
    };

    match promise.state() {
        PromiseState::Pending => CompletionState::Pending,
        PromiseState::Resolved => CompletionState::Completed { error_text: None },
        PromiseState::Rejected => {
            // `result` rethrows the rejection reason, which `catch` then hands back.
            let reason = match promise.result::<Value>() {
                Some(Ok(value)) => value,
                Some(Err(_)) => ctx.catch(),
                None => Value::new_undefined(ctx.clone()),
            };
            CompletionState::Completed {
                error_text: Some(value_to_error_text(ctx, &reason)),
            }
        }
    }
}

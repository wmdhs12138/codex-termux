//! The JavaScript side of code mode, on QuickJS.
//!
//! Each `exec` cell gets its own thread, its own QuickJS runtime and context, and is driven by
//! a small command loop: tool results, timer expirations and termination arrive as
//! [`RuntimeCommand`]s, and everything the script produces leaves as [`RuntimeEvent`]s.
//! This is the codex-termux replacement for the V8 implementation (rusty_v8 has no Android
//! build); everything outside this directory is unchanged upstream code.

mod audio;
mod callbacks;
mod globals;
mod module_loader;
mod timers;
mod value;

use std::cell::RefCell;
use std::collections::HashMap;
use std::panic::AssertUnwindSafe;
use std::panic::catch_unwind;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::sync::mpsc as std_mpsc;
use std::thread;

use codex_code_mode_protocol::CodeModeToolKind;
use codex_code_mode_protocol::EnabledToolMetadata;
use codex_code_mode_protocol::ExecuteRequest;
use codex_code_mode_protocol::FunctionCallOutputContentItem;
use codex_code_mode_protocol::enabled_tool_metadata;
use codex_protocol::ToolName;
use rquickjs::Context;
use rquickjs::Ctx;
use rquickjs::Function;
use rquickjs::Persistent;
use rquickjs::Promise;
use rquickjs::Runtime;
use serde_json::Value as JsonValue;
use tokio::sync::mpsc;

use crate::TaskFailureHandler;

const EXIT_SENTINEL: &str = "__codex_code_mode_exit__";

#[derive(Debug)]
pub(crate) enum RuntimeCommand {
    ToolResponse { id: String, result: JsonValue },
    ToolError { id: String, error_text: String },
    TimeoutFired { id: u64 },
    ObservePendingFrontier,
    Terminate,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum PendingRuntimeMode {
    #[cfg(test)]
    Continue,
    PauseUntilResumed,
}

#[derive(Debug)]
pub(crate) enum RuntimeControlCommand {
    Continue,
    Resume,
    Terminate,
}

#[derive(Debug)]
pub(crate) enum RuntimeEvent {
    Started,
    Pending,
    ContentItem(FunctionCallOutputContentItem),
    YieldRequested,
    ToolCall {
        id: String,
        name: ToolName,
        kind: CodeModeToolKind,
        input: Option<JsonValue>,
    },
    Notify {
        call_id: String,
        text: String,
    },
    Result {
        stored_value_writes: HashMap<String, Arc<JsonValue>>,
        error_text: Option<String>,
    },
    ThreadPanicked,
}

/// Lets another thread abort a running script: the QuickJS counterpart of V8's `IsolateHandle`.
/// The runtime's interrupt handler polls the flag, and QuickJS raises an uncatchable error.
#[derive(Clone)]
pub(crate) struct TerminateHandle(Arc<AtomicBool>);

impl TerminateHandle {
    fn new() -> Self {
        Self(Arc::new(AtomicBool::new(false)))
    }

    pub(crate) fn terminate_execution(&self) -> bool {
        self.0.store(true, Ordering::SeqCst);
        true
    }

    fn is_terminated(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

pub(crate) fn spawn_runtime(
    stored_values: HashMap<String, Arc<JsonValue>>,
    request: ExecuteRequest,
    event_tx: mpsc::UnboundedSender<RuntimeEvent>,
    pending_mode: PendingRuntimeMode,
    task_failure_handler: Option<TaskFailureHandler>,
) -> Result<
    (
        std_mpsc::Sender<RuntimeCommand>,
        std_mpsc::Sender<RuntimeControlCommand>,
        TerminateHandle,
    ),
    String,
> {
    let (command_tx, command_rx) = std_mpsc::channel();
    let (control_tx, control_rx) = std_mpsc::channel();
    let runtime_command_tx = command_tx.clone();
    let terminate_handle = TerminateHandle::new();
    let enabled_tools = request
        .enabled_tools
        .iter()
        .map(enabled_tool_metadata)
        .collect::<Vec<_>>();
    let config = RuntimeConfig {
        tool_call_id: request.tool_call_id,
        enabled_tools,
        source: request.source,
        stored_values,
    };

    let runtime_handle = tokio::runtime::Handle::current();
    let thread_terminate_handle = terminate_handle.clone();
    spawn_supervised_runtime_thread(event_tx.clone(), task_failure_handler, move || {
        let _runtime_guard = runtime_handle.enter();
        run_runtime(
            config,
            event_tx,
            command_rx,
            control_rx,
            pending_mode,
            thread_terminate_handle,
            runtime_command_tx,
        );
    });

    Ok((command_tx, control_tx, terminate_handle))
}

fn spawn_supervised_runtime_thread(
    event_tx: mpsc::UnboundedSender<RuntimeEvent>,
    task_failure_handler: Option<TaskFailureHandler>,
    runtime: impl FnOnce() + Send + 'static,
) {
    thread::spawn(move || {
        if catch_unwind(AssertUnwindSafe(runtime)).is_err() {
            if let Some(task_failure_handler) = task_failure_handler {
                task_failure_handler("code-mode V8 runtime thread panicked".to_string());
            }
            let _ = event_tx.send(RuntimeEvent::ThreadPanicked);
        }
    });
}

#[derive(Clone)]
struct RuntimeConfig {
    tool_call_id: String,
    enabled_tools: Vec<EnabledToolMetadata>,
    source: String,
    stored_values: HashMap<String, Arc<JsonValue>>,
}

pub(super) struct PendingToolCall {
    resolve: Persistent<Function<'static>>,
    reject: Persistent<Function<'static>>,
}

pub(super) struct RuntimeState {
    event_tx: mpsc::UnboundedSender<RuntimeEvent>,
    pending_tool_calls: HashMap<String, PendingToolCall>,
    pending_timeouts: HashMap<u64, timers::ScheduledTimeout>,
    stored_values: HashMap<String, Arc<JsonValue>>,
    stored_value_writes: HashMap<String, Arc<JsonValue>>,
    enabled_tools: Vec<EnabledToolMetadata>,
    next_tool_call_id: u64,
    next_timeout_id: u64,
    tool_call_id: String,
    runtime_command_tx: std_mpsc::Sender<RuntimeCommand>,
    terminate: TerminateHandle,
    exit_requested: bool,
}

/// The runtime state is shared with the host functions installed into the script's globals.
/// Everything runs on the cell's own thread, so `Rc<RefCell<..>>` is enough; no borrow is ever
/// held across a call into JavaScript.
pub(super) type SharedState = Rc<RefCell<RuntimeState>>;

/// Drops every QuickJS handle the state owns. It must happen while the context is still alive:
/// a handle that outlives its runtime trips QuickJS's leak assertion and aborts the process.
/// Dropping the timers also aborts their sleep tasks, so nothing outlives the cell.
struct StateCleanup(SharedState);

impl Drop for StateCleanup {
    fn drop(&mut self) {
        if let Ok(mut state) = self.0.try_borrow_mut() {
            state.pending_tool_calls.clear();
            state.pending_timeouts.clear();
        }
    }
}

pub(super) enum CompletionState {
    Pending,
    Completed {
        stored_value_writes: HashMap<String, Arc<JsonValue>>,
        error_text: Option<String>,
    },
}

fn run_runtime(
    config: RuntimeConfig,
    event_tx: mpsc::UnboundedSender<RuntimeEvent>,
    command_rx: std_mpsc::Receiver<RuntimeCommand>,
    control_rx: std_mpsc::Receiver<RuntimeControlCommand>,
    pending_mode: PendingRuntimeMode,
    terminate: TerminateHandle,
    runtime_command_tx: std_mpsc::Sender<RuntimeCommand>,
) {
    let runtime = match Runtime::new() {
        Ok(runtime) => runtime,
        Err(error) => {
            send_result(
                &event_tx,
                HashMap::new(),
                Some(format!("failed to create the JavaScript runtime: {error}")),
            );
            return;
        }
    };
    let interrupt = terminate.clone();
    runtime.set_interrupt_handler(Some(Box::new(move || interrupt.is_terminated())));
    runtime.set_loader(
        module_loader::RejectImports,
        module_loader::RejectImports,
    );
    // Declared after the runtime so the context is dropped first.
    let context = match Context::full(&runtime) {
        Ok(context) => context,
        Err(error) => {
            send_result(
                &event_tx,
                HashMap::new(),
                Some(format!("failed to create the JavaScript context: {error}")),
            );
            return;
        }
    };

    context.with(|ctx| {
        run_in_context(
            &ctx,
            config,
            &event_tx,
            &command_rx,
            &control_rx,
            pending_mode,
            terminate,
            runtime_command_tx,
        );
    });
}

#[allow(clippy::too_many_arguments)]
fn run_in_context<'js>(
    ctx: &Ctx<'js>,
    config: RuntimeConfig,
    event_tx: &mpsc::UnboundedSender<RuntimeEvent>,
    command_rx: &std_mpsc::Receiver<RuntimeCommand>,
    control_rx: &std_mpsc::Receiver<RuntimeControlCommand>,
    pending_mode: PendingRuntimeMode,
    terminate: TerminateHandle,
    runtime_command_tx: std_mpsc::Sender<RuntimeCommand>,
) {
    let state: SharedState = Rc::new(RefCell::new(RuntimeState {
        event_tx: event_tx.clone(),
        pending_tool_calls: HashMap::new(),
        pending_timeouts: HashMap::new(),
        stored_values: config.stored_values,
        stored_value_writes: HashMap::new(),
        enabled_tools: config.enabled_tools,
        next_tool_call_id: 1,
        next_timeout_id: 1,
        tool_call_id: config.tool_call_id,
        runtime_command_tx,
        terminate,
        exit_requested: false,
    }));
    let _cleanup = StateCleanup(Rc::clone(&state));

    if let Err(error_text) = globals::install_globals(ctx, &state) {
        send_result(event_tx, HashMap::new(), Some(error_text));
        return;
    }

    let _ = event_tx.send(RuntimeEvent::Started);

    let pending_promise = match module_loader::evaluate_main_module(ctx, &state, &config.source) {
        Ok(pending_promise) => pending_promise,
        Err(error_text) => {
            send_state_result(&state, event_tx, Some(error_text));
            return;
        }
    };

    match module_loader::completion_state(ctx, &state, pending_promise.as_ref()) {
        CompletionState::Completed {
            stored_value_writes,
            error_text,
        } => {
            send_result(event_tx, stored_value_writes, error_text);
            return;
        }
        CompletionState::Pending => {}
    }

    while let Some(command) = next_runtime_command(event_tx, command_rx, control_rx, pending_mode) {
        match command {
            RuntimeCommand::Terminate => break,
            RuntimeCommand::ToolResponse { id, result } => {
                if let Err(error_text) =
                    module_loader::resolve_tool_response(ctx, &state, &id, Ok(result))
                {
                    send_state_result(&state, event_tx, Some(error_text));
                    return;
                }
            }
            RuntimeCommand::ToolError { id, error_text } => {
                if let Err(runtime_error) =
                    module_loader::resolve_tool_response(ctx, &state, &id, Err(error_text))
                {
                    send_state_result(&state, event_tx, Some(runtime_error));
                    return;
                }
            }
            RuntimeCommand::TimeoutFired { id } => {
                if let Err(runtime_error) = timers::invoke_timeout_callback(ctx, &state, id) {
                    send_state_result(&state, event_tx, Some(runtime_error));
                    return;
                }
            }
            RuntimeCommand::ObservePendingFrontier => {}
        }

        module_loader::run_pending_jobs(ctx, &state);
        match module_loader::completion_state(ctx, &state, pending_promise.as_ref()) {
            CompletionState::Completed {
                stored_value_writes,
                error_text,
            } => {
                send_result(event_tx, stored_value_writes, error_text);
                return;
            }
            CompletionState::Pending => {}
        }
    }
}

fn next_runtime_command(
    event_tx: &mpsc::UnboundedSender<RuntimeEvent>,
    command_rx: &std_mpsc::Receiver<RuntimeCommand>,
    control_rx: &std_mpsc::Receiver<RuntimeControlCommand>,
    pending_mode: PendingRuntimeMode,
) -> Option<RuntimeCommand> {
    loop {
        match command_rx.try_recv() {
            Ok(command) => return Some(command),
            Err(std_mpsc::TryRecvError::Disconnected) => return None,
            Err(std_mpsc::TryRecvError::Empty) => {}
        }

        let _ = event_tx.send(RuntimeEvent::Pending);
        match pending_mode {
            #[cfg(test)]
            PendingRuntimeMode::Continue => return command_rx.recv().ok(),
            PendingRuntimeMode::PauseUntilResumed => match control_rx.recv().ok()? {
                RuntimeControlCommand::Continue => return command_rx.recv().ok(),
                RuntimeControlCommand::Resume => continue,
                RuntimeControlCommand::Terminate => return Some(RuntimeCommand::Terminate),
            },
        }
    }
}

fn send_state_result(
    state: &SharedState,
    event_tx: &mpsc::UnboundedSender<RuntimeEvent>,
    error_text: Option<String>,
) {
    let stored_value_writes = state.borrow().stored_value_writes.clone();
    send_result(event_tx, stored_value_writes, error_text);
}

fn send_result(
    event_tx: &mpsc::UnboundedSender<RuntimeEvent>,
    stored_value_writes: HashMap<String, Arc<JsonValue>>,
    error_text: Option<String>,
) {
    let _ = event_tx.send(RuntimeEvent::Result {
        stored_value_writes,
        error_text,
    });
}

/// Keeps `Promise` in the signature list of this module for the submodules that name it.
#[allow(dead_code)]
type MainPromise<'js> = Promise<'js>;

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::time::Duration;

    use pretty_assertions::assert_eq;
    use tokio::sync::mpsc;

    use super::ExecuteRequest;
    use super::PendingRuntimeMode;
    use super::RuntimeCommand;
    use super::RuntimeControlCommand;
    use super::RuntimeEvent;
    use super::spawn_runtime;
    use super::spawn_supervised_runtime_thread;
    use crate::FunctionCallOutputContentItem;

    fn execute_request(source: &str) -> ExecuteRequest {
        ExecuteRequest {
            tool_call_id: "call_1".to_string(),
            enabled_tools: Vec::new(),
            source: source.to_string(),
            yield_time_ms: Some(1),
            max_output_tokens: None,
        }
    }

    #[tokio::test]
    async fn runtime_thread_panic_before_initialization_is_reported_directly() {
        let (event_tx, event_rx) = mpsc::unbounded_channel();
        drop(event_rx);
        let (failure_tx, mut failure_rx) = mpsc::unbounded_channel();
        spawn_supervised_runtime_thread(
            event_tx,
            Some(std::sync::Arc::new(move |reason| {
                let _ = failure_tx.send(reason);
            })),
            || panic!("runtime thread panic probe"),
        );

        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), failure_rx.recv())
                .await
                .expect("runtime failure timeout")
                .expect("runtime failure"),
            "code-mode V8 runtime thread panicked"
        );
    }

    #[tokio::test]
    async fn runtime_thread_panic_is_forwarded_without_owner_supervision() {
        let (event_tx, mut event_rx) = mpsc::unbounded_channel();
        spawn_supervised_runtime_thread(
            event_tx,
            /*task_failure_handler*/ None,
            || panic!("runtime thread panic probe"),
        );

        assert!(matches!(
            tokio::time::timeout(Duration::from_secs(1), event_rx.recv())
                .await
                .expect("runtime panic event timeout"),
            Some(RuntimeEvent::ThreadPanicked)
        ));
    }

    #[tokio::test]
    async fn terminate_execution_stops_cpu_bound_module() {
        let (event_tx, mut event_rx) = mpsc::unbounded_channel();
        let (_runtime_tx, _runtime_control_tx, runtime_terminate_handle) = spawn_runtime(
            HashMap::new(),
            execute_request("while (true) {}"),
            event_tx,
            PendingRuntimeMode::Continue,
            /*task_failure_handler*/ None,
        )
        .unwrap();

        let started_event = tokio::time::timeout(Duration::from_secs(1), event_rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(started_event, RuntimeEvent::Started));

        assert!(runtime_terminate_handle.terminate_execution());

        let result_event = tokio::time::timeout(Duration::from_secs(1), event_rx.recv())
            .await
            .unwrap()
            .unwrap();
        let RuntimeEvent::Result { error_text, .. } = result_event else {
            panic!("expected runtime result after termination");
        };
        assert!(error_text.is_some());

        assert!(
            tokio::time::timeout(Duration::from_secs(1), event_rx.recv())
                .await
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn pending_mode_freezes_runtime_commands_until_resume() {
        let (event_tx, mut event_rx) = mpsc::unbounded_channel();
        let (runtime_tx, runtime_control_tx, _runtime_terminate_handle) = spawn_runtime(
            HashMap::new(),
            execute_request(
                r#"
await new Promise((resolve) => setTimeout(resolve, 60_000));
text("after");
await new Promise(() => {});
"#,
            ),
            event_tx,
            PendingRuntimeMode::PauseUntilResumed,
            /*task_failure_handler*/ None,
        )
        .unwrap();

        assert!(matches!(
            tokio::time::timeout(Duration::from_secs(1), event_rx.recv())
                .await
                .unwrap()
                .unwrap(),
            RuntimeEvent::Started
        ));
        assert!(matches!(
            tokio::time::timeout(Duration::from_secs(1), event_rx.recv())
                .await
                .unwrap()
                .unwrap(),
            RuntimeEvent::Pending
        ));

        runtime_tx
            .send(RuntimeCommand::TimeoutFired { id: 1 })
            .unwrap();
        assert!(
            tokio::time::timeout(Duration::from_secs(1), event_rx.recv())
                .await
                .is_err()
        );

        runtime_control_tx
            .send(RuntimeControlCommand::Resume)
            .unwrap();

        let content_event = tokio::time::timeout(Duration::from_secs(1), event_rx.recv())
            .await
            .unwrap()
            .unwrap();
        let RuntimeEvent::ContentItem(FunctionCallOutputContentItem::InputText { text }) =
            content_event
        else {
            panic!("expected resumed runtime output");
        };
        assert_eq!(text, "after");
        assert!(matches!(
            tokio::time::timeout(Duration::from_secs(1), event_rx.recv())
                .await
                .unwrap()
                .unwrap(),
            RuntimeEvent::Pending
        ));

        runtime_control_tx
            .send(RuntimeControlCommand::Terminate)
            .unwrap();
    }

    #[tokio::test]
    async fn timers_release_tasks_when_cleared_or_the_cell_finishes() {
        let (event_tx, mut event_rx) = mpsc::unbounded_channel();
        let (_runtime_tx, _runtime_control_tx, _runtime_terminate_handle) = spawn_runtime(
            HashMap::new(),
            execute_request(
                r#"
clearTimeout(setTimeout(() => text("cancelled"), 3_600_000));
await new Promise((resolve) => setTimeout(resolve, 3_600_000));
text("done");
setTimeout(() => text("late"), 3_600_000);
"#,
            ),
            event_tx,
            PendingRuntimeMode::Continue,
            /*task_failure_handler*/ None,
        )
        .unwrap();

        loop {
            match tokio::time::timeout(Duration::from_secs(1), event_rx.recv())
                .await
                .unwrap()
            {
                Some(RuntimeEvent::Pending) => break,
                Some(_) => {}
                None => panic!("runtime closed before the timer was pending"),
            }
        }
        tokio::task::yield_now().await;
        assert_eq!(
            tokio::runtime::Handle::current()
                .metrics()
                .num_alive_tasks(),
            1
        );
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(3_600)).await;
        tokio::time::resume();

        let mut output = Vec::new();
        while let Some(event) = tokio::time::timeout(Duration::from_secs(1), event_rx.recv())
            .await
            .expect("timer runtime should finish")
        {
            match event {
                RuntimeEvent::ContentItem(item) => output.push(item),
                RuntimeEvent::Result { error_text, .. } => assert_eq!(error_text, None),
                _ => {}
            }
        }
        assert_eq!(
            output,
            vec![FunctionCallOutputContentItem::InputText {
                text: "done".to_string()
            }]
        );
        tokio::task::yield_now().await;
        assert_eq!(
            tokio::runtime::Handle::current()
                .metrics()
                .num_alive_tasks(),
            0
        );
    }
}

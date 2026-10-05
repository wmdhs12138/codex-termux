use std::time::Duration;

use rquickjs::Ctx;
use rquickjs::Function;
use rquickjs::Persistent;
use rquickjs::Value;
use rquickjs::convert::Coerced;
use tokio_util::task::AbortOnDropHandle;

use super::RuntimeCommand;
use super::SharedState;
use super::value::error_text;

pub(super) struct ScheduledTimeout {
    callback: Persistent<Function<'static>>,
    // Clearing the timeout or dropping the runtime also cancels its sleep.
    _task: AbortOnDropHandle<()>,
}

/// JavaScript `Number(value)`; `None` when the conversion itself throws (the exception is
/// cleared). `NaN` is returned as `NaN`.
fn number_value<'js>(ctx: &Ctx<'js>, value: &Value<'js>) -> Option<f64> {
    match value.get::<Coerced<f64>>() {
        Ok(Coerced(number)) => Some(number),
        Err(error) => {
            let _ = error_text(ctx, error);
            None
        }
    }
}

pub(super) fn schedule_timeout<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    args: &[Value<'js>],
) -> Result<u64, String> {
    let callback = args
        .first()
        .and_then(Value::as_function)
        .ok_or_else(|| "setTimeout expects a function callback".to_string())?;

    let delay_ms = args
        .get(1)
        .and_then(|delay| number_value(ctx, delay))
        .map(normalize_delay_ms)
        .unwrap_or(0);

    let callback = Persistent::save(ctx, callback.clone());
    let mut state = state.borrow_mut();
    let timeout_id = state.next_timeout_id;
    state.next_timeout_id = state.next_timeout_id.saturating_add(1);
    let runtime_command_tx = state.runtime_command_tx.clone();
    let sleep = tokio::time::sleep(Duration::from_millis(delay_ms));
    let task = tokio::spawn(async move {
        sleep.await;
        let _ = runtime_command_tx.send(RuntimeCommand::TimeoutFired { id: timeout_id });
    });
    state.pending_timeouts.insert(
        timeout_id,
        ScheduledTimeout {
            callback,
            _task: AbortOnDropHandle::new(task),
        },
    );

    Ok(timeout_id)
}

pub(super) fn clear_timeout<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    args: &[Value<'js>],
) -> Result<(), String> {
    let Some(timeout_id) = timeout_id_from_args(ctx, args)? else {
        return Ok(());
    };

    state.borrow_mut().pending_timeouts.remove(&timeout_id);
    Ok(())
}

pub(super) fn invoke_timeout_callback<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    timeout_id: u64,
) -> Result<(), String> {
    let timeout = state.borrow_mut().pending_timeouts.remove(&timeout_id);
    let Some(timeout) = timeout else {
        return Ok(());
    };

    let callback = timeout
        .callback
        .restore(ctx)
        .map_err(|error| error_text(ctx, error))?;
    callback
        .call::<_, Value>(())
        .map(|_| ())
        .map_err(|error| error_text(ctx, error))
}

fn timeout_id_from_args<'js>(
    ctx: &Ctx<'js>,
    args: &[Value<'js>],
) -> Result<Option<u64>, String> {
    let Some(first) = args.first() else {
        return Ok(None);
    };
    if first.is_null() || first.is_undefined() {
        return Ok(None);
    }

    let Some(timeout_id) = number_value(ctx, first) else {
        return Err("clearTimeout expects a numeric timeout id".to_string());
    };
    if !timeout_id.is_finite() || timeout_id <= 0.0 {
        return Ok(None);
    }

    Ok(Some(timeout_id.trunc().min(u64::MAX as f64) as u64))
}

fn normalize_delay_ms(delay_ms: f64) -> u64 {
    if !delay_ms.is_finite() || delay_ms <= 0.0 {
        0
    } else {
        delay_ms.trunc().min(u64::MAX as f64) as u64
    }
}

//! Exercises the host guard separately from the interrupt handler. Simulate
//! QuickJS continuing to execute after exit was requested, including during getters.
//!
//! QuickJS port of upstream's V8 test. `markExit` only flags the exit, so the script keeps
//! running until a helper sees the flag; every case therefore ends in the termination error
//! (which V8 would raise on its next interrupt instead).

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::mpsc as std_mpsc;

use codex_code_mode_protocol::CodeModeToolKind;
use codex_code_mode_protocol::EnabledToolMetadata;
use codex_protocol::ToolName;
use pretty_assertions::assert_eq;
use rquickjs::Context;
use rquickjs::Ctx;
use rquickjs::Error;
use rquickjs::Function;
use rquickjs::Runtime;
use rquickjs::Value;
use rquickjs::function::Rest;
use rquickjs::qjs;
use serde_json::json;
use tokio::sync::mpsc;

use super::super::RuntimeEvent;
use super::super::RuntimeState;
use super::super::SharedState;
use super::super::TerminateHandle;
use super::super::Termination;
use super::super::ToolCallbackMetadata;
use super::super::globals;
use super::super::request_exit;
use crate::FunctionCallOutputContentItem;

// Deliberately leave JS running: the test must verify host-side admission even
// when QuickJS has not processed its interrupt. Returning a value exercises coercion.
fn mark_exit_requested<'js>(ctx: Ctx<'js>, args: Rest<Value<'js>>) -> Value<'js> {
    request_exit(&ctx);
    args.0
        .into_iter()
        .next()
        .unwrap_or_else(|| Value::new_undefined(ctx.clone()))
}

#[tokio::test]
async fn host_callbacks_admit_no_new_effects_after_exit_is_requested() {
    for (label, source) in [
        (
            "ordinary calls",
            r#"
markExit();
text("still working");
image("data:image/png;base64,AAA");
audio("data:audio/mpeg;base64,YXVkaW8=");
generatedImage({image_url: "data:image/png;base64,AAA", output_hint: "late"});
notify("late"); store("phase", "late");
tools.echo("late"); yield_control();
clearTimeout(earlyTimer); setTimeout(() => {}, 60000);
"#,
        ),
        (
            "text conversion",
            r#"text({toJSON() { return markExit("late"); }});"#,
        ),
        (
            "notify conversion",
            r#"notify({toJSON() { return markExit("late"); }});"#,
        ),
        (
            "store conversion",
            r#"store("phase", {toJSON() { return markExit("late"); }});"#,
        ),
        (
            "store key",
            r#"store({toString() { return markExit("phase"); }}, "late");"#,
        ),
        (
            "tool conversion",
            r#"tools.echo({toJSON() { return markExit("late"); }});"#,
        ),
        (
            "image getter",
            r#"image({get image_url() { return markExit("data:image/png;base64,AAA"); }});"#,
        ),
        (
            "audio getter",
            r#"audio({get audio_url() { return markExit("data:audio/mpeg;base64,YXVkaW8="); }});"#,
        ),
        (
            "generated image hint",
            r#"generatedImage({image_url: "data:image/png;base64,AAA", get output_hint() {return markExit("late"); }});"#,
        ),
        (
            "timer delay",
            r#"setTimeout(() => {}, {valueOf() {return markExit(60000); }});"#,
        ),
        (
            "clear timer id",
            r#"clearTimeout({valueOf() {return markExit(earlyTimer); }});"#,
        ),
    ] {
        // Declared before the context so the context is dropped first.
        let runtime = Runtime::new().expect("runtime");
        let context = Context::full(&runtime).expect("context");
        let (event_tx, mut event_rx) = mpsc::unbounded_channel();
        let (runtime_command_tx, _runtime_command_rx) = std_mpsc::channel();
        context.with(|ctx| {
            assert!(
                ctx.store_userdata(Termination::new(TerminateHandle::new()))
                    .is_ok(),
                "{label}: termination state"
            );
            let tool_name = ToolName::plain("echo");
            let state: SharedState = Rc::new(RefCell::new(RuntimeState {
                event_tx,
                pending_tool_calls: HashMap::new(),
                pending_timeouts: HashMap::new(),
                stored_values: HashMap::new(),
                stored_value_writes: HashMap::new(),
                enabled_tools: vec![ToolCallbackMetadata {
                    tool_name: tool_name.clone(),
                    kind: CodeModeToolKind::Function,
                }],
                next_tool_call_id: 1,
                next_timeout_id: 1,
                tool_call_id: "cell".to_string(),
                runtime_command_tx,
            }));
            globals::install_globals(
                &ctx,
                &state,
                &[EnabledToolMetadata {
                    global_name: "echo".to_string(),
                    tool_name,
                    description: String::new(),
                    kind: CodeModeToolKind::Function,
                }],
            )
            .expect("install globals");

            let marker = Function::new(ctx.clone(), mark_exit_requested).expect("exit marker");
            ctx.globals()
                .set("markExit", marker)
                .expect("marker name");
            let program = format!(
                r#"
text("before"); store("phase", "before"); notify("before");
tools.echo("before");
const earlyTimer = setTimeout(() => text("early timer"), 60000);
{source}
"#
            );
            let result = ctx.eval::<(), _>(program);
            assert!(
                matches!(result, Err(Error::Exception)),
                "{label}: script finished without the termination error"
            );
            let exception = ctx.catch();
            assert!(
                // SAFETY: `exception` is a live value of this context.
                unsafe { qjs::JS_IsUncatchableError(exception.as_raw()) },
                "{label}: {exception:?}"
            );

            assert!(
                matches!(event_rx.try_recv(), Ok(RuntimeEvent::ContentItem(
                FunctionCallOutputContentItem::InputText { text }
            )) if text == "before"),
                "{label}: pre-exit output"
            );
            assert!(
                matches!(event_rx.try_recv(), Ok(RuntimeEvent::Notify { text, .. }) if text == "before"),
                "{label}: pre-exit notification"
            );
            assert!(
                matches!(event_rx.try_recv(), Ok(RuntimeEvent::ToolCall { id, input, .. })
                if id == "tool-1" && input == Some(json!("before"))),
                "{label}: pre-exit tool"
            );
            assert!(
                matches!(event_rx.try_recv(), Err(mpsc::error::TryRecvError::Empty)),
                "{label}: emitted an effect after exit"
            );

            let mut state = state.borrow_mut();
            assert_eq!(
                state.stored_value_writes,
                HashMap::from([("phase".to_string(), Arc::new(json!("before")))]),
                "{label}: stored writes"
            );
            assert_eq!(
                state.stored_values, state.stored_value_writes,
                "{label}: cell storage"
            );
            assert_eq!(state.next_tool_call_id, 2, "{label}: allocated tool ID");
            assert_eq!(state.next_timeout_id, 2, "{label}: allocated timeout ID");
            assert!(
                state.pending_tool_calls.contains_key("tool-1"),
                "{label}: lost prior tool"
            );
            assert!(
                state.pending_timeouts.contains_key(&1),
                "{label}: lost prior timer"
            );
            // QuickJS handles must not outlive the context.
            state.pending_tool_calls.clear();
            state.pending_timeouts.clear();
        });
    }
}

//! The host functions code mode exposes to scripts (`tools.*`, `text`, `image`, `store`, ...).
//!
//! Each takes the call's arguments as a slice (missing ones read as `undefined`, like in
//! JavaScript) and returns the JavaScript result, or an error that has already thrown the
//! exception the script will see.

use codex_code_mode_protocol::FunctionCallOutputContentItem;
use rquickjs::Ctx;
use rquickjs::IntoJs;
use rquickjs::Persistent;
use rquickjs::Result;
use rquickjs::Value;
use std::sync::Arc;

use super::EXIT_SENTINEL;
use super::PendingToolCall;
use super::RuntimeEvent;
use super::SharedState;
use super::timers;
use super::value::coerce_to_string;
use super::value::json_to_value;
use super::value::normalize_output_audio;
use super::value::normalize_output_image;
use super::value::serialize_output_text;
use super::value::throw_string;
use super::value::value_to_json;

fn undefined<'js>(ctx: &Ctx<'js>) -> Value<'js> {
    Value::new_undefined(ctx.clone())
}

fn arg<'js>(ctx: &Ctx<'js>, args: &[Value<'js>], index: usize) -> Value<'js> {
    args.get(index).cloned().unwrap_or_else(|| undefined(ctx))
}

fn send_content_item(state: &SharedState, item: FunctionCallOutputContentItem) {
    let _ = state
        .borrow()
        .event_tx
        .send(RuntimeEvent::ContentItem(item));
}

pub(super) fn tool_callback<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    tool_index: usize,
    args: &[Value<'js>],
) -> Result<Value<'js>> {
    let input = if args.is_empty() {
        None
    } else {
        value_to_json(ctx, &args[0]).map_err(|error_text| throw_string(ctx, &error_text))?
    };

    let (tool_name, tool_kind) = {
        let state = state.borrow();
        let Some(tool) = state.enabled_tools.get(tool_index) else {
            return Err(throw_string(ctx, "tool callback data is out of range"));
        };
        (tool.tool_name.clone(), tool.kind)
    };

    let (promise, resolve, reject) = ctx.promise()?;
    let pending = PendingToolCall {
        resolve: Persistent::save(ctx, resolve),
        reject: Persistent::save(ctx, reject),
    };

    let (id, event_tx) = {
        let mut state = state.borrow_mut();
        let id = format!("tool-{}", state.next_tool_call_id);
        state.next_tool_call_id = state.next_tool_call_id.saturating_add(1);
        state.pending_tool_calls.insert(id.clone(), pending);
        (id, state.event_tx.clone())
    };
    let _ = event_tx.send(RuntimeEvent::ToolCall {
        id,
        name: tool_name,
        kind: tool_kind,
        input,
    });
    Ok(promise.into_value())
}

pub(super) fn text_callback<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    args: &[Value<'js>],
) -> Result<Value<'js>> {
    let value = arg(ctx, args, 0);
    let text = serialize_output_text(ctx, &value)
        .map_err(|error_text| throw_string(ctx, &error_text))?;
    send_content_item(state, FunctionCallOutputContentItem::InputText { text });
    Ok(undefined(ctx))
}

pub(super) fn audio_callback<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    args: &[Value<'js>],
) -> Result<Value<'js>> {
    let value = arg(ctx, args, 0);
    let audio_item = normalize_output_audio(ctx, &value)?;
    send_content_item(state, audio_item);
    Ok(undefined(ctx))
}

pub(super) fn image_callback<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    args: &[Value<'js>],
) -> Result<Value<'js>> {
    let value = arg(ctx, args, 0);
    let detail_override = if args.len() < 2 {
        None
    } else {
        let detail = &args[1];
        if detail.is_string() {
            Some(coerce_to_string(ctx, detail).unwrap_or_default())
        } else if detail.is_null() || detail.is_undefined() {
            None
        } else {
            return Err(throw_string(
                ctx,
                "image detail must be a string when provided",
            ));
        }
    };
    let image_item = normalize_output_image(ctx, &value, detail_override)?;
    send_content_item(state, image_item);
    Ok(undefined(ctx))
}

pub(super) fn generated_image_callback<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    args: &[Value<'js>],
) -> Result<Value<'js>> {
    let value = arg(ctx, args, 0);
    let output_hint = generated_image_output_hint(ctx, &value)
        .map_err(|error_text| throw_string(ctx, &error_text))?;
    let image_item = normalize_output_image(ctx, &value, /*detail_override*/ None)?;
    send_content_item(state, image_item);
    if let Some(text) = output_hint {
        send_content_item(state, FunctionCallOutputContentItem::InputText { text });
    }
    Ok(undefined(ctx))
}

fn generated_image_output_hint<'js>(
    ctx: &Ctx<'js>,
    value: &Value<'js>,
) -> std::result::Result<Option<String>, String> {
    let object = value
        .as_object()
        .ok_or_else(|| "generatedImage expects an image generation result object".to_string())?;
    let output_hint = object
        .get::<_, Value>("output_hint")
        .map_err(|_| "failed to read generatedImage output_hint".to_string())?;
    if output_hint.is_undefined() {
        return Ok(None);
    }
    if !output_hint.is_string() {
        return Err("generatedImage output_hint must be a string when provided".to_string());
    }
    Ok(Some(coerce_to_string(ctx, &output_hint).unwrap_or_default()))
}

pub(super) fn store_callback<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    args: &[Value<'js>],
) -> Result<Value<'js>> {
    let Some(key) = coerce_to_string(ctx, &arg(ctx, args, 0)) else {
        return Err(throw_string(ctx, "store key must be a string"));
    };
    let serialized = match value_to_json(ctx, &arg(ctx, args, 1)) {
        Ok(Some(value)) => value,
        Ok(None) => {
            return Err(throw_string(
                ctx,
                &format!("Unable to store {key:?}. Only plain serializable objects can be stored."),
            ));
        }
        Err(error_text) => return Err(throw_string(ctx, &error_text)),
    };
    let serialized = Arc::new(serialized);
    let mut state = state.borrow_mut();
    state
        .stored_values
        .insert(key.clone(), Arc::clone(&serialized));
    state.stored_value_writes.insert(key, serialized);
    Ok(undefined(ctx))
}

pub(super) fn load_callback<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    args: &[Value<'js>],
) -> Result<Value<'js>> {
    let Some(key) = coerce_to_string(ctx, &arg(ctx, args, 0)) else {
        return Err(throw_string(ctx, "load key must be a string"));
    };
    let value = state.borrow().stored_values.get(&key).cloned();
    let Some(value) = value else {
        return Ok(undefined(ctx));
    };
    json_to_value(ctx, &value).ok_or_else(|| throw_string(ctx, "failed to load stored value"))
}

pub(super) fn notify_callback<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    args: &[Value<'js>],
) -> Result<Value<'js>> {
    let value = arg(ctx, args, 0);
    let text = serialize_output_text(ctx, &value)
        .map_err(|error_text| throw_string(ctx, &error_text))?;
    if text.trim().is_empty() {
        return Err(throw_string(ctx, "notify expects non-empty text"));
    }
    {
        let state = state.borrow();
        let _ = state.event_tx.send(RuntimeEvent::Notify {
            call_id: state.tool_call_id.clone(),
            text,
        });
    }
    Ok(undefined(ctx))
}

pub(super) fn set_timeout_callback<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    args: &[Value<'js>],
) -> Result<Value<'js>> {
    let timeout_id = timers::schedule_timeout(ctx, state, args)
        .map_err(|error_text| throw_string(ctx, &error_text))?;
    (timeout_id as f64).into_js(ctx)
}

pub(super) fn clear_timeout_callback<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    args: &[Value<'js>],
) -> Result<Value<'js>> {
    timers::clear_timeout(ctx, state, args).map_err(|error_text| throw_string(ctx, &error_text))?;
    Ok(undefined(ctx))
}

pub(super) fn yield_control_callback<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    _args: &[Value<'js>],
) -> Result<Value<'js>> {
    let _ = state.borrow().event_tx.send(RuntimeEvent::YieldRequested);
    Ok(undefined(ctx))
}

pub(super) fn exit_callback<'js>(
    ctx: &Ctx<'js>,
    state: &SharedState,
    _args: &[Value<'js>],
) -> Result<Value<'js>> {
    state.borrow_mut().exit_requested = true;
    Err(throw_string(ctx, EXIT_SENTINEL))
}

//! Conversions between JavaScript values and the Rust side of code mode.
//!
//! QuickJS port of the V8 helpers. Every conversion that crosses the boundary goes
//! through JSON (as it did with V8), and helper errors are thrown as plain strings.

use rquickjs::Ctx;
use rquickjs::Error;
use rquickjs::Object;
use rquickjs::Value;
use rquickjs::convert::Coerced;
use serde_json::Value as JsonValue;

use codex_code_mode_protocol::DEFAULT_IMAGE_DETAIL;
use codex_code_mode_protocol::FunctionCallOutputContentItem;
use codex_code_mode_protocol::ImageDetail;

use super::audio::wav_duration_seconds;

const IMAGE_HELPER_EXPECTS_MESSAGE: &str = "image expects a non-empty image URL string, an object with image_url and optional detail, or a raw MCP image block";
const AUDIO_HELPER_EXPECTS_MESSAGE: &str = "audio expects a non-empty audio URL string, an object with audio_url, or a raw MCP audio block";
const REMOTE_IMAGE_URL_ERROR: &str = "Tool call failed: remote image URLs are not supported in tool outputs. Pass a base64 data URI instead";
const INVALID_IMAGE_URL_ERROR: &str =
    "Tool call failed: invalid image output. Pass a base64 data URI instead";
const INVALID_AUDIO_URL_ERROR: &str =
    "Tool call failed: invalid audio output. Pass a base64 data URI instead";
const CODEX_IMAGE_DETAIL_META_KEY: &str = "codex/imageDetail";
const UNKNOWN_EXCEPTION: &str = "unknown code mode exception";

/// Throws `message` as a plain JavaScript string, like the V8 runtime did, and returns the
/// error that tells QuickJS an exception is pending.
pub(super) fn throw_string<'js>(ctx: &Ctx<'js>, message: &str) -> Error {
    match rquickjs::String::from_str(ctx.clone(), message) {
        Ok(string) => ctx.throw(string.into_value()),
        Err(error) => error,
    }
}

/// Turns an error from a QuickJS call into the text the model should see, consuming the
/// pending exception when there is one.
pub(super) fn error_text<'js>(ctx: &Ctx<'js>, error: Error) -> String {
    match error {
        Error::Exception => {
            let exception = ctx.catch();
            value_to_error_text(ctx, &exception)
        }
        other => other.to_string(),
    }
}

/// JavaScript `String(value)`; `None` when the conversion itself throws (the exception is
/// cleared).
pub(super) fn coerce_to_string<'js>(ctx: &Ctx<'js>, value: &Value<'js>) -> Option<String> {
    match value.get::<Coerced<String>>() {
        Ok(Coerced(string)) => Some(string),
        Err(error) => {
            let _ = error_text(ctx, error);
            None
        }
    }
}

pub(super) fn serialize_output_text<'js>(
    ctx: &Ctx<'js>,
    value: &Value<'js>,
) -> Result<String, String> {
    if value.is_undefined()
        || value.is_null()
        || value.is_bool()
        || value.is_number()
        || value.is_big_int()
        || value.is_string()
    {
        return Ok(coerce_to_string(ctx, value).unwrap_or_default());
    }

    match ctx.json_stringify(value.clone()) {
        Ok(Some(stringified)) => stringified
            .to_string()
            .map_err(|error| error_text(ctx, error)),
        Ok(None) => Ok(coerce_to_string(ctx, value).unwrap_or_default()),
        Err(error) => Err(error_text(ctx, error)),
    }
}

/// JSON-serializes a JavaScript value. `Ok(None)` means "not serializable" (`undefined`,
/// functions, symbols), matching `JSON.stringify` returning `undefined`.
pub(super) fn value_to_json<'js>(
    ctx: &Ctx<'js>,
    value: &Value<'js>,
) -> Result<Option<JsonValue>, String> {
    if value.is_undefined() {
        return Ok(None);
    }

    match ctx.json_stringify(value.clone()) {
        Ok(Some(stringified)) => {
            let text = stringified
                .to_string()
                .map_err(|error| error_text(ctx, error))?;
            serde_json::from_str(&text)
                .map(Some)
                .map_err(|err| format!("failed to serialize JavaScript value: {err}"))
        }
        Ok(None) => Ok(None),
        Err(error) => Err(error_text(ctx, error)),
    }
}

pub(super) fn json_to_value<'js>(ctx: &Ctx<'js>, value: &JsonValue) -> Option<Value<'js>> {
    let json = serde_json::to_string(value).ok()?;
    match ctx.json_parse(json) {
        Ok(value) => Some(value),
        Err(error) => {
            let _ = error_text(ctx, error);
            None
        }
    }
}

pub(super) fn value_to_error_text<'js>(ctx: &Ctx<'js>, value: &Value<'js>) -> String {
    if value.is_object()
        && let Some(object) = value.as_object()
        && let Ok(stack) = object.get::<_, Value>("stack")
        && stack.is_string()
        && let Some(stack) = coerce_to_string(ctx, &stack)
    {
        // V8 stacks start with "Name: message"; QuickJS stacks hold only the frames, which
        // would hide the one thing the model needs. Put the header back.
        let header = coerce_to_string(ctx, value).unwrap_or_default();
        if stack.is_empty() {
            return header;
        }
        if header.is_empty() || stack.starts_with(&header) {
            return stack;
        }
        return format!("{header}\n{stack}");
    }
    coerce_to_string(ctx, value).unwrap_or_else(|| UNKNOWN_EXCEPTION.to_string())
}

/// Reads an optional own-or-inherited property, treating a throwing getter like a missing one.
fn get_property<'js>(ctx: &Ctx<'js>, object: &Object<'js>, key: &str) -> Option<Value<'js>> {
    match object.get::<_, Value>(key) {
        Ok(value) => Some(value),
        Err(error) => {
            let _ = error_text(ctx, error);
            None
        }
    }
}

pub(super) fn normalize_output_image<'js>(
    ctx: &Ctx<'js>,
    value: &Value<'js>,
    detail_override: Option<String>,
) -> Result<FunctionCallOutputContentItem, Error> {
    let result = (|| -> Result<FunctionCallOutputContentItem, String> {
        let (image_url, detail) = if value.is_string() {
            (coerce_to_string(ctx, value).unwrap_or_default(), None)
        } else if value.is_object() && !value.is_array() {
            let object = value
                .as_object()
                .ok_or_else(|| IMAGE_HELPER_EXPECTS_MESSAGE.to_string())?;
            if let Some(image) = parse_non_mcp_output_image(ctx, object)? {
                image
            } else {
                parse_mcp_output_image(ctx, value)?
            }
        } else {
            return Err(IMAGE_HELPER_EXPECTS_MESSAGE.to_string());
        };

        if image_url.is_empty() {
            return Err(IMAGE_HELPER_EXPECTS_MESSAGE.to_string());
        }
        let Some((scheme, _)) = image_url.split_once(':') else {
            return Err(INVALID_IMAGE_URL_ERROR.to_string());
        };
        if scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https") {
            return Err(REMOTE_IMAGE_URL_ERROR.to_string());
        }
        if !scheme.eq_ignore_ascii_case("data") {
            return Err(INVALID_IMAGE_URL_ERROR.to_string());
        }

        let detail = detail_override.or(detail);
        let detail = match detail {
            Some(detail) => {
                let normalized = detail.to_ascii_lowercase();
                Some(match normalized.as_str() {
                    "auto" => ImageDetail::Auto,
                    "low" => ImageDetail::Low,
                    "high" => ImageDetail::High,
                    "original" => ImageDetail::Original,
                    _ => {
                        return Err(
                            "image detail must be one of: auto, low, high, original".to_string()
                        );
                    }
                })
            }
            None => Some(DEFAULT_IMAGE_DETAIL),
        };

        Ok(FunctionCallOutputContentItem::InputImage { image_url, detail })
    })();

    result.map_err(|error_text| throw_string(ctx, &error_text))
}

fn parse_non_mcp_output_image<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
) -> Result<Option<(String, Option<String>)>, String> {
    let Some(image_url) = get_property(ctx, object, "image_url") else {
        return Ok(None);
    };
    if image_url.is_undefined() {
        return Ok(None);
    }
    if !image_url.is_string() {
        return Err(IMAGE_HELPER_EXPECTS_MESSAGE.to_string());
    }
    let detail = parse_image_detail_value(ctx, get_property(ctx, object, "detail"))?;
    Ok(Some((
        coerce_to_string(ctx, &image_url).unwrap_or_default(),
        detail,
    )))
}

fn parse_mcp_output_image<'js>(
    ctx: &Ctx<'js>,
    value: &Value<'js>,
) -> Result<(String, Option<String>), String> {
    let Some(result) = value_to_json(ctx, value)? else {
        return Err(IMAGE_HELPER_EXPECTS_MESSAGE.to_string());
    };
    let JsonValue::Object(result) = result else {
        return Err(IMAGE_HELPER_EXPECTS_MESSAGE.to_string());
    };
    let Some(item_type) = result.get("type").and_then(JsonValue::as_str) else {
        return Err(IMAGE_HELPER_EXPECTS_MESSAGE.to_string());
    };
    if item_type != "image" {
        return Err(format!(
            "image only accepts MCP image blocks, got \"{item_type}\""
        ));
    }
    let data = result
        .get("data")
        .and_then(JsonValue::as_str)
        .ok_or_else(|| "image expected MCP image data".to_string())?;
    if data.is_empty() {
        return Err("image expected MCP image data".to_string());
    }

    let image_url = if data.to_ascii_lowercase().starts_with("data:") {
        data.to_string()
    } else {
        let mime_type = result
            .get("mimeType")
            .or_else(|| result.get("mime_type"))
            .and_then(JsonValue::as_str)
            .filter(|mime_type| !mime_type.is_empty())
            .unwrap_or("application/octet-stream");
        format!("data:{mime_type};base64,{data}")
    };
    let detail = result
        .get("_meta")
        .and_then(JsonValue::as_object)
        .and_then(|meta| meta.get(CODEX_IMAGE_DETAIL_META_KEY))
        .and_then(JsonValue::as_str)
        .filter(|detail| matches!(*detail, "auto" | "low" | "high" | "original"))
        .map(str::to_string);
    Ok((image_url, detail))
}

fn parse_image_detail_value<'js>(
    ctx: &Ctx<'js>,
    value: Option<Value<'js>>,
) -> Result<Option<String>, String> {
    match value {
        Some(value) if value.is_string() => Ok(Some(coerce_to_string(ctx, &value).unwrap_or_default())),
        Some(value) if value.is_null() || value.is_undefined() => Ok(None),
        Some(_) => Err("image detail must be a string when provided".to_string()),
        None => Ok(None),
    }
}

pub(super) fn normalize_output_audio<'js>(
    ctx: &Ctx<'js>,
    value: &Value<'js>,
) -> Result<FunctionCallOutputContentItem, Error> {
    let result = (|| -> Result<FunctionCallOutputContentItem, String> {
        let audio_url = if value.is_string() {
            coerce_to_string(ctx, value).unwrap_or_default()
        } else if value.is_object() && !value.is_array() {
            let object = value
                .as_object()
                .ok_or_else(|| AUDIO_HELPER_EXPECTS_MESSAGE.to_string())?;
            if let Some(audio_url) = parse_non_mcp_output_audio(ctx, object)? {
                audio_url
            } else {
                parse_mcp_output_audio(ctx, value)?
            }
        } else {
            return Err(AUDIO_HELPER_EXPECTS_MESSAGE.to_string());
        };

        if audio_url.is_empty() {
            return Err(AUDIO_HELPER_EXPECTS_MESSAGE.to_string());
        }
        let Some((scheme, _)) = audio_url.split_once(':') else {
            return Err(INVALID_AUDIO_URL_ERROR.to_string());
        };
        if !scheme.eq_ignore_ascii_case("data") {
            return Err(INVALID_AUDIO_URL_ERROR.to_string());
        }

        // Tiny tool-generated clips cannot be encoded reliably by audio models.
        if wav_duration_seconds(&audio_url).is_some_and(|duration| duration < 0.025) {
            return Ok(FunctionCallOutputContentItem::InputText {
                text: "Audio output omitted because the clip is shorter than 25 ms; use a longer clip."
                    .to_string(),
            });
        }

        Ok(FunctionCallOutputContentItem::InputAudio { audio_url })
    })();

    result.map_err(|error_text| throw_string(ctx, &error_text))
}

fn parse_non_mcp_output_audio<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
) -> Result<Option<String>, String> {
    let Some(audio_url) = get_property(ctx, object, "audio_url") else {
        return Ok(None);
    };
    if audio_url.is_undefined() {
        return Ok(None);
    }
    if !audio_url.is_string() {
        return Err(AUDIO_HELPER_EXPECTS_MESSAGE.to_string());
    }
    Ok(Some(coerce_to_string(ctx, &audio_url).unwrap_or_default()))
}

fn parse_mcp_output_audio<'js>(ctx: &Ctx<'js>, value: &Value<'js>) -> Result<String, String> {
    let Some(result) = value_to_json(ctx, value)? else {
        return Err(AUDIO_HELPER_EXPECTS_MESSAGE.to_string());
    };
    let JsonValue::Object(result) = result else {
        return Err(AUDIO_HELPER_EXPECTS_MESSAGE.to_string());
    };
    let Some(item_type) = result.get("type").and_then(JsonValue::as_str) else {
        return Err(AUDIO_HELPER_EXPECTS_MESSAGE.to_string());
    };
    if item_type != "audio" {
        return Err(format!(
            "audio only accepts MCP audio blocks, got \"{item_type}\""
        ));
    }
    let data = result
        .get("data")
        .and_then(JsonValue::as_str)
        .ok_or_else(|| "audio expected MCP audio data".to_string())?;
    if data.is_empty() {
        return Err("audio expected MCP audio data".to_string());
    }

    if data.to_ascii_lowercase().starts_with("data:") {
        Ok(data.to_string())
    } else {
        let mime_type = result
            .get("mimeType")
            .or_else(|| result.get("mime_type"))
            .and_then(JsonValue::as_str)
            .filter(|mime_type| !mime_type.is_empty())
            .unwrap_or("application/octet-stream");
        Ok(format!("data:{mime_type};base64,{data}"))
    }
}

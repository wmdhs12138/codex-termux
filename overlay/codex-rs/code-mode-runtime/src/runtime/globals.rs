use std::rc::Rc;

use rquickjs::Array;
use rquickjs::Ctx;
use rquickjs::Function;
use rquickjs::Object;
use rquickjs::Value;
use rquickjs::function::Rest;

use super::SharedState;
use super::callbacks;

/// Wraps `f` into a JavaScript function named `name`. `f` sees all arguments as a slice.
fn host_function<'js, F>(ctx: &Ctx<'js>, name: &str, f: F) -> Result<Function<'js>, String>
where
    F: Fn(&Ctx<'js>, &[Value<'js>]) -> rquickjs::Result<Value<'js>> + 'js,
{
    Function::new(ctx.clone(), move |ctx: Ctx<'js>, args: Rest<Value<'js>>| {
        f(&ctx, &args.0)
    })
    .and_then(|function| function.with_name(name))
    .map_err(|error| format!("failed to create helper function `{name}`: {error}"))
}

type Callback = for<'js> fn(&Ctx<'js>, &SharedState, &[Value<'js>]) -> rquickjs::Result<Value<'js>>;

pub(super) fn install_globals<'js>(ctx: &Ctx<'js>, state: &SharedState) -> Result<(), String> {
    let global = ctx.globals();
    // Same environment as the V8 runtime: what the exec description promises is plain
    // ECMAScript, so drop the web-ish extras QuickJS-ng adds on top (and the usual V8 removals).
    for name in [
        "console",
        "Atomics",
        "SharedArrayBuffer",
        "WebAssembly",
        "DOMException",
        "InternalError",
        "atob",
        "btoa",
        "performance",
        "queueMicrotask",
    ] {
        global
            .remove(name)
            .map_err(|error| format!("failed to remove global `{name}`: {error}"))?;
    }

    let enabled_tools = state.borrow().enabled_tools.clone();
    let tools = Object::new(ctx.clone())
        .map_err(|error| format!("failed to allocate the tools object: {error}"))?;
    for (tool_index, tool) in enabled_tools.iter().enumerate() {
        let state = Rc::clone(state);
        let function = host_function(ctx, &tool.global_name, move |ctx, args| {
            callbacks::tool_callback(ctx, &state, tool_index, args)
        })?;
        tools
            .set(tool.global_name.as_str(), function)
            .map_err(|error| format!("failed to set tool `{}`: {error}", tool.global_name))?;
    }
    set_global(&global, "tools", tools)?;

    let all_tools = Array::new(ctx.clone())
        .map_err(|error| format!("failed to allocate ALL_TOOLS: {error}"))?;
    for (index, tool) in enabled_tools.iter().enumerate() {
        let item = Object::new(ctx.clone())
            .map_err(|error| format!("failed to allocate ALL_TOOLS item: {error}"))?;
        item.set("name", tool.global_name.as_str())
            .map_err(|_| "failed to set ALL_TOOLS name".to_string())?;
        item.set("description", tool.description.as_str())
            .map_err(|_| "failed to set ALL_TOOLS description".to_string())?;
        all_tools
            .set(index, item)
            .map_err(|_| "failed to append ALL_TOOLS metadata".to_string())?;
    }
    set_global(&global, "ALL_TOOLS", all_tools)?;

    let helpers: [(&str, Callback); 11] = [
        ("clearTimeout", callbacks::clear_timeout_callback),
        ("setTimeout", callbacks::set_timeout_callback),
        ("text", callbacks::text_callback),
        ("image", callbacks::image_callback),
        ("audio", callbacks::audio_callback),
        ("generatedImage", callbacks::generated_image_callback),
        ("store", callbacks::store_callback),
        ("load", callbacks::load_callback),
        ("notify", callbacks::notify_callback),
        ("yield_control", callbacks::yield_control_callback),
        ("exit", callbacks::exit_callback),
    ];
    for (name, callback) in helpers {
        let state = Rc::clone(state);
        let function = host_function(ctx, name, move |ctx, args| callback(ctx, &state, args))?;
        set_global(&global, name, function)?;
    }
    Ok(())
}

fn set_global<'js, V>(global: &Object<'js>, name: &str, value: V) -> Result<(), String>
where
    V: rquickjs::IntoJs<'js>,
{
    global
        .set(name, value)
        .map_err(|error| format!("failed to set global `{name}`: {error}"))
}

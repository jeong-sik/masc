//! Actor Join/Leave Panel — claim and release TRPG actors via REST.
//!
//! Binds DOM event listeners on `#join-panel` elements:
//! - Join button → POST `/api/v1/trpg/actors/claim`
//! - Leave button → POST `/api/v1/trpg/actors/release`
//!
//! On successful claim, hides the join panel and shows the action panel.
//! On release, reverses the swap.

use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use crate::config;

// ─── Marker Resource ────────────────────────

/// Inserted on enter, removed on exit — signals that the join panel is bound.
#[derive(Resource)]
pub struct ActorJoinBound;

// ─── OnEnter System ─────────────────────────

/// Bind DOM event listeners when entering TRPG mode.
pub fn bind_actor_join(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        bind_join_button();
        bind_leave_button();
        clear_join_status();
        restore_join_panel_state();
        log::info!("ActorJoin: bound");
    }

    commands.insert_resource(ActorJoinBound);
}

/// Cleanup when leaving TRPG mode.
pub fn unbind_actor_join(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        clear_join_status();
        log::info!("ActorJoin: unbound");
    }

    commands.remove_resource::<ActorJoinBound>();
}

// ─── Event: Join Button ─────────────────────

#[cfg(target_arch = "wasm32")]
fn bind_join_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("join-btn") else {
        log::warn!("ActorJoin: #join-btn not found");
        return;
    };

    let cb = Closure::wrap(Box::new(move || {
        do_join();
    }) as Box<dyn FnMut()>);

    let _ = btn
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));

    cb.forget();
}

// ─── Event: Leave Button ────────────────────

#[cfg(target_arch = "wasm32")]
fn bind_leave_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("leave-btn") else {
        log::warn!("ActorJoin: #leave-btn not found");
        return;
    };

    let cb = Closure::wrap(Box::new(move || {
        do_leave();
    }) as Box<dyn FnMut()>);

    let _ = btn
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));

    cb.forget();
}

// ─── Join Logic ─────────────────────────────

#[cfg(target_arch = "wasm32")]
fn do_join() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    let actor_id = read_input_value(&doc, "actor-id-input");
    let keeper = read_input_value(&doc, "keeper-input");

    if actor_id.is_empty() {
        set_join_status("Enter an actor ID.", "status-error");
        return;
    }
    if keeper.is_empty() {
        set_join_status("Enter your name.", "status-error");
        return;
    }

    set_join_status("Claiming actor...", "");
    set_join_button_disabled(true);

    let actor_id_clone = actor_id.clone();
    let keeper_clone = keeper.clone();

    wasm_bindgen_futures::spawn_local(async move {
        match claim_actor(&actor_id_clone, &keeper_clone).await {
            Ok(()) => {
                set_claimed_state(&actor_id_clone, &keeper_clone);
                swap_to_action_panel(&actor_id_clone);
                set_join_status("", "");
            }
            Err(e) => {
                let detail = crate::dom::action_panel::friendly_js_error(&e);
                log::warn!("Claim failed: {:?}", e);
                set_join_status(&format!("Claim failed: {}", detail), "status-error");
            }
        }
        set_join_button_disabled(false);
    });
}

// ─── Leave Logic ────────────────────────────

#[cfg(target_arch = "wasm32")]
fn do_leave() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    let actor_id = read_hidden_value(&doc, "claimed-actor-id");
    let keeper = read_hidden_value(&doc, "claimed-keeper");

    if actor_id.is_empty() {
        return;
    }

    set_leave_button_disabled(true);

    let actor_id_clone = actor_id.clone();
    let keeper_clone = keeper.clone();

    wasm_bindgen_futures::spawn_local(async move {
        match release_actor(&actor_id_clone, &keeper_clone).await {
            Ok(()) => {
                clear_claimed_state();
                swap_to_join_panel();
                log::info!("ActorJoin: released {}", actor_id_clone);
            }
            Err(e) => {
                log::warn!("Release failed: {:?}", e);
                // Still swap back — the server may have released anyway
                clear_claimed_state();
                swap_to_join_panel();
            }
        }
        set_leave_button_disabled(false);
    });
}

// ─── HTTP: Claim Actor ──────────────────────

#[cfg(target_arch = "wasm32")]
async fn claim_actor(actor_id: &str, keeper: &str) -> Result<(), JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let url = format!("{}/api/v1/trpg/actors/claim", config::MASC_MCP_URL);
    let room_id = config::current_room_id();

    let body = serde_json::json!({
        "room_id": room_id,
        "actor_id": actor_id,
        "keeper": keeper,
    })
    .to_string();

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(&body));

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    request.headers().set("Content-Type", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        let status = resp.status();
        let text = JsFuture::from(resp.text()?).await?;
        let text_str = text.as_string().unwrap_or_default();
        return Err(JsValue::from_str(&format!(
            "HTTP {} — {}",
            status, text_str
        )));
    }

    log::info!("ActorJoin: claimed {} as {}", actor_id, keeper);
    Ok(())
}

// ─── HTTP: Release Actor ────────────────────

#[cfg(target_arch = "wasm32")]
async fn release_actor(actor_id: &str, keeper: &str) -> Result<(), JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let url = format!("{}/api/v1/trpg/actors/release", config::MASC_MCP_URL);
    let room_id = config::current_room_id();

    let body = serde_json::json!({
        "room_id": room_id,
        "actor_id": actor_id,
        "keeper": keeper,
    })
    .to_string();

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(&body));

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    request.headers().set("Content-Type", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        return Err(JsValue::from_str(&format!("HTTP {}", resp.status())));
    }

    Ok(())
}

// ─── DOM Panel Swap ─────────────────────────

#[cfg(target_arch = "wasm32")]
fn swap_to_action_panel(actor_id: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    set_display(&doc, "join-panel", "none");
    set_display(&doc, "action-panel", "block");
    if let Some(el) = doc.get_element_by_id("player-actor-id") {
        el.set_text_content(Some(actor_id));
    }
}

#[cfg(target_arch = "wasm32")]
fn swap_to_join_panel() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    set_display(&doc, "action-panel", "none");
    set_display(&doc, "join-panel", "block");
    if let Some(el) = doc.get_element_by_id("player-actor-id") {
        el.set_text_content(Some(""));
    }
}

// ─── Claimed State (Hidden Inputs) ──────────

#[cfg(target_arch = "wasm32")]
fn set_claimed_state(actor_id: &str, keeper: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    set_hidden_value(&doc, "claimed-actor-id", actor_id);
    set_hidden_value(&doc, "claimed-keeper", keeper);
}

#[cfg(target_arch = "wasm32")]
fn clear_claimed_state() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    set_hidden_value(&doc, "claimed-actor-id", "");
    set_hidden_value(&doc, "claimed-keeper", "");
}

/// On re-enter TRPG mode, check if a claim is still stored.
/// If so, show the action panel instead of the join panel.
#[cfg(target_arch = "wasm32")]
fn restore_join_panel_state() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let actor_id = read_hidden_value(&doc, "claimed-actor-id");
    if actor_id.is_empty() {
        set_display(&doc, "join-panel", "block");
        set_display(&doc, "action-panel", "none");
    } else {
        set_display(&doc, "join-panel", "none");
        set_display(&doc, "action-panel", "block");
        if let Some(el) = doc.get_element_by_id("player-actor-id") {
            el.set_text_content(Some(&actor_id));
        }
    }
}

// ─── DOM Helpers ────────────────────────────

#[cfg(target_arch = "wasm32")]
fn set_join_status(msg: &str, class: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    if let Some(el) = doc.get_element_by_id("join-status") {
        el.set_text_content(Some(msg));
        el.set_class_name(if class.is_empty() { "" } else { class });
    }
}

#[cfg(target_arch = "wasm32")]
fn clear_join_status() {
    set_join_status("", "");
}

#[cfg(target_arch = "wasm32")]
fn set_join_button_disabled(disabled: bool) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    if let Some(el) = doc.get_element_by_id("join-btn") {
        if let Some(btn) = el.dyn_ref::<web_sys::HtmlButtonElement>() {
            btn.set_disabled(disabled);
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn set_leave_button_disabled(disabled: bool) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    if let Some(el) = doc.get_element_by_id("leave-btn") {
        if let Some(btn) = el.dyn_ref::<web_sys::HtmlButtonElement>() {
            btn.set_disabled(disabled);
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn read_input_value(doc: &web_sys::Document, id: &str) -> String {
    doc.get_element_by_id(id)
        .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
        .map(|v| v.trim().to_string())
        .unwrap_or_default()
}

#[cfg(target_arch = "wasm32")]
fn read_hidden_value(doc: &web_sys::Document, id: &str) -> String {
    doc.get_element_by_id(id)
        .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
        .unwrap_or_default()
}

#[cfg(target_arch = "wasm32")]
fn set_hidden_value(doc: &web_sys::Document, id: &str, value: &str) {
    if let Some(el) = doc.get_element_by_id(id) {
        if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
            input.set_value(value);
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn set_display(doc: &web_sys::Document, id: &str, display: &str) {
    if let Some(el) = doc.get_element_by_id(id) {
        if let Some(html_el) = el.dyn_ref::<web_sys::HtmlElement>() {
            let _ = html_el.style().set_property("display", display);
        }
    }
}

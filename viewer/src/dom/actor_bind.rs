//! Actor Bind/Release Panel — claim and release TRPG actors via REST.
//!
//! Binds DOM event listeners on `#join-panel` elements:
//! - Join button → POST `/api/v1/trpg/actors/claim`
//! - Leave button → POST `/api/v1/trpg/actors/release`
//!
//! On successful claim, hides the bind panel and shows the action panel.
//! On release, reverses the swap.

use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;

#[cfg(target_arch = "wasm32")]
use crate::config;
#[cfg(target_arch = "wasm32")]
use crate::dom::action_panel::friendly_js_error;
#[cfg(target_arch = "wasm32")]
use crate::game::lifecycle::TrpgLifecycleState;
use crate::game::state::{WorkspaceState, TurnProgressState};

// ─── Marker Resource ────────────────────────

/// Inserted on enter, removed on exit — signals that the actor bind panel is bound.
#[derive(Resource)]
pub struct ActorBindBound;

// ─── OnEnter System ─────────────────────────

/// Bind DOM event listeners when entering TRPG mode.
pub fn bind_actor(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        bind_join_button();
        bind_leave_button();
        restore_join_panel_state(); // Restore UI state from hidden inputs if available
        sync_actor_suggestions();
        log::info!("ActorBind: bound");
    }

    commands.insert_resource(ActorBindBound);
}

/// Cleanup when leaving TRPG mode.
pub fn unbind_actor(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    log::info!("ActorBind: unbound");

    commands.remove_resource::<ActorBindBound>();
}

// ─── Interaction State Sync System ──────────

/// Disable join controls when the workspace is not in an interactive state.
/// This prevents confusing claim errors for ended/idle/unavailable workspaces.
pub fn sync_join_panel_interaction_state(
    workspace_state: Res<WorkspaceState>,
    progress: Res<TurnProgressState>,
) {
    let _ = (&workspace_state, &progress);

    #[cfg(target_arch = "wasm32")]
    {
        let lifecycle =
            TrpgLifecycleState::from_workspace_progress(&workspace_state.status, &progress.workspace_status);
        let can_join = lifecycle.accepts_player_input();

        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        let join_visible = doc
            .get_element_by_id("join-panel")
            .map(|panel| {
                let inline = panel.get_attribute("style").unwrap_or_default();
                !inline.to_ascii_lowercase().contains("display: none")
            })
            .unwrap_or(true);
        if join_visible {
            sync_actor_suggestions_for_doc(&doc);
        }

        if let Some(btn) = doc.get_element_by_id("join-btn") {
            if can_join {
                let _ = btn.remove_attribute("disabled");
                let _ = btn.set_attribute("title", "캐릭터를 점유하고 수동 플레이를 시작합니다");
            } else {
                let _ = btn.set_attribute("disabled", "true");
                let _ = btn.set_attribute("title", lifecycle.help_text());
            }
        }

        if join_visible {
            if let Some(help) = doc.get_element_by_id("join-help") {
                let text = if can_join {
                    "참여를 누르면 선택한 캐릭터를 점유(Claim)하고, 해당 캐릭터 행동을 직접 입력할 수 있습니다. 오른쪽 PARTY 카드 Skills의 Lv/Mod를 보고 액션·주사위 판정을 진행하세요."
                } else {
                    lifecycle.help_text()
                };
                help.set_text_content(Some(text));
            }
        }
    }
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
    if btn.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = btn.set_attribute("data-bound", "1");

    let cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        // 1. Get input values
        let actor_id_input = doc
            .get_element_by_id("actor-id-input")
            .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok());
        let keeper_input = doc
            .get_element_by_id("keeper-input")
            .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok());

        let actor_id = actor_id_input.map(|i| i.value()).unwrap_or_default();
        let keeper_name = keeper_input.map(|i| i.value()).unwrap_or_default();

        if actor_id.trim().is_empty() {
            set_join_status(
                "캐릭터 ID가 필요합니다. 오른쪽 PARTY에서 ID를 확인해 입력하세요.",
                "status-error",
            );
            return;
        }

        // 2. Disable button while processing
        if let Some(btn) = doc.get_element_by_id("join-btn") {
            let _ = btn.set_attribute("disabled", "true");
        }
        set_join_status("캐릭터 점유 요청 중...", "");

        // 3. Spawn async claim request
        let actor_id_clone = actor_id.clone();
        wasm_bindgen_futures::spawn_local(async move {
            match claim_actor(&actor_id, &keeper_name).await {
                Ok(_) => {
                    set_join_status(
                        "점유 완료. 아래 액션 입력창에서 행동/주사위를 실행할 수 있습니다.",
                        "status-ok",
                    );
                    swap_to_action_panel(&actor_id_clone);
                }
                Err(e) => {
                    let detail = friendly_js_error(&e);
                    log::warn!("Claim failed: {:?}", detail);
                    set_join_status(
                        &format!("참여 실패: {}", friendly_claim_error(&detail)),
                        "status-error",
                    );

                    // Re-enable button on error
                    if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
                        if let Some(btn) = doc.get_element_by_id("join-btn") {
                            let _ = btn.remove_attribute("disabled");
                        }
                    }
                }
            }
        });
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
    if btn.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = btn.set_attribute("data-bound", "1");

    let cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };

        // Get claimed actor ID from hidden state (or just the UI text if we had it)
        // Ideally we stored it somewhere. For now, let's grab from the DOM display if possible,
        // or rely on the stored hidden input.
        let claimed_id = get_claimed_actor_id_from_dom().unwrap_or_default();
        if claimed_id.is_empty() {
            set_join_status("현재 점유 중인 캐릭터가 없습니다.", "status-error");
            return;
        }

        // Disable button
        if let Some(btn) = doc.get_element_by_id("leave-btn") {
            let _ = btn.set_attribute("disabled", "true");
        }

        // Spawn async release request
        let actor_id = claimed_id.clone();
        wasm_bindgen_futures::spawn_local(async move {
            match release_actor(&actor_id).await {
                Ok(_) => {
                    swap_to_join_panel();
                    set_join_status("점유를 해제했습니다.", "status-ok");
                }
                Err(e) => {
                    let detail = friendly_js_error(&e);
                    log::warn!("Release failed: {:?}", detail);
                    // Force leave on UI anyway? Or show error?
                    // Usually better to let them try again.
                    set_join_status(
                        &format!("나가기 실패: {}", friendly_claim_error(&detail)),
                        "status-error",
                    );

                    if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
                        if let Some(btn) = doc.get_element_by_id("leave-btn") {
                            let _ = btn.remove_attribute("disabled");
                        }
                    }
                }
            }
        });
    }) as Box<dyn FnMut()>);

    let _ = btn
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));

    cb.forget();
}

// ─── HTTP: Claim Actor ──────────────────────

#[cfg(target_arch = "wasm32")]
async fn claim_actor(actor_id: &str, keeper_name: &str) -> Result<(), JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let url = config::build_masc_url("api/v1/trpg/actors/claim");
    let workspace_id = config::current_workspace_id();

    // If keeper_name is empty, default to "Anonymous Viewer"
    let keeper = if keeper_name.trim().is_empty() {
        "Anonymous Viewer"
    } else {
        keeper_name
    };

    let body = serde_json::json!({
        "workspace_id": workspace_id,
        "actor_id": actor_id,
        "keeper_name": keeper
    })
    .to_string();

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(&body));

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    config::apply_auth_headers(&request.headers())?;
    request.headers().set("Content-Type", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        let err_body = JsFuture::from(resp.text()?).await?;
        let err_text = err_body.as_string().unwrap_or_default();
        // Parse error json if possible
        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&err_text) {
            if let Some(detail) = json.get("detail").and_then(|v| v.as_str()) {
                return Err(JsValue::from_str(detail));
            }
        }
        return Err(JsValue::from_str(&format!(
            "HTTP {} - {}",
            resp.status(),
            err_text
        )));
    }

    Ok(())
}

// ─── HTTP: Release Actor ────────────────────

#[cfg(target_arch = "wasm32")]
async fn release_actor(actor_id: &str) -> Result<(), JsValue> {
    use wasm_bindgen_futures::JsFuture;

    let url = config::build_masc_url("api/v1/trpg/actors/release");
    let workspace_id = config::current_workspace_id();

    // Retrieve keeper name from hidden state if possible, or send empty (server might require it?)
    // The current API spec for release requires `keeper_name`.
    let keeper = get_claimed_keeper_from_dom().unwrap_or("Anonymous Viewer".to_string());

    let body = serde_json::json!({
        "workspace_id": workspace_id,
        "actor_id": actor_id,
        "keeper_name": keeper,
        "reason": "Viewer user left"
    })
    .to_string();

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(&body));

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    config::apply_auth_headers(&request.headers())?;
    request.headers().set("Content-Type", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        let err_body = JsFuture::from(resp.text()?).await?;
        let err_text = err_body.as_string().unwrap_or_default();
        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&err_text) {
            if let Some(detail) = json.get("detail").and_then(|v| v.as_str()) {
                return Err(JsValue::from_str(detail));
            }
        }
        return Err(JsValue::from_str(&format!(
            "HTTP {} - {}",
            resp.status(),
            err_text
        )));
    }

    Ok(())
}

// ─── UI Helpers ─────────────────────────────

#[cfg(target_arch = "wasm32")]
fn set_join_status(text: &str, css_class: &str) {
    if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
        if let Some(el) = doc.get_element_by_id("join-status") {
            el.set_text_content(Some(text));
            el.set_class_name(css_class);
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn swap_to_action_panel(actor_id: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    // Hide join panel
    if let Some(el) = doc.get_element_by_id("join-panel") {
        let _ = el.set_attribute("style", "display: none;");
    }

    // Show action panel
    if let Some(el) = doc.get_element_by_id("action-panel") {
        let _ = el.remove_attribute("style"); // removes display:none
    }

    // Update player info display
    if let Some(el) = doc.get_element_by_id("player-actor-id") {
        el.set_text_content(Some(actor_id));
    }

    // Store state in hidden inputs (for persistence across re-renders if needed)
    set_claimed_state(actor_id);
}

#[cfg(target_arch = "wasm32")]
fn swap_to_join_panel() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    // Hide action panel
    if let Some(el) = doc.get_element_by_id("action-panel") {
        let _ = el.set_attribute("style", "display: none;");
    }

    // Show join panel
    if let Some(el) = doc.get_element_by_id("join-panel") {
        let _ = el.remove_attribute("style");
    }

    // Clear player info
    if let Some(el) = doc.get_element_by_id("player-actor-id") {
        el.set_text_content(Some(""));
    }

    // Clear state
    clear_claimed_state();

    // Reset buttons
    if let Some(btn) = doc.get_element_by_id("join-btn") {
        let _ = btn.remove_attribute("disabled");
    }
    if let Some(btn) = doc.get_element_by_id("leave-btn") {
        let _ = btn.remove_attribute("disabled");
    }
}

#[cfg(target_arch = "wasm32")]
fn set_claimed_state(actor_id: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let workspace_id = config::current_workspace_id();

    if let Some(el) = doc.get_element_by_id("claimed-actor-id") {
        if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
            input.set_value(actor_id);
        }
    }

    // Also save keeper name?
    if let Some(k_input) = doc.get_element_by_id("keeper-input") {
        if let Some(input) = k_input.dyn_ref::<web_sys::HtmlInputElement>() {
            let keeper = input.value();
            if let Some(hidden) = doc.get_element_by_id("claimed-keeper") {
                if let Some(h_input) = hidden.dyn_ref::<web_sys::HtmlInputElement>() {
                    h_input.set_value(&keeper);
                }
            }
        }
    }

    if let Some(el) = doc.get_element_by_id("claimed-workspace-id") {
        if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
            input.set_value(&workspace_id);
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn clear_claimed_state() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    if let Some(el) = doc.get_element_by_id("claimed-actor-id") {
        if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
            input.set_value("");
        }
    }
    if let Some(el) = doc.get_element_by_id("claimed-keeper") {
        if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
            input.set_value("");
        }
    }
    if let Some(el) = doc.get_element_by_id("claimed-workspace-id") {
        if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
            input.set_value("");
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn get_claimed_actor_id_from_dom() -> Option<String> {
    let doc = web_sys::window().and_then(|w| w.document())?;
    let el = doc.get_element_by_id("claimed-actor-id")?;
    let input = el.dyn_ref::<web_sys::HtmlInputElement>()?;
    let val = input.value();
    if val.is_empty() {
        None
    } else {
        Some(val)
    }
}

#[cfg(target_arch = "wasm32")]
fn get_claimed_keeper_from_dom() -> Option<String> {
    let doc = web_sys::window().and_then(|w| w.document())?;
    let el = doc.get_element_by_id("claimed-keeper")?;
    let input = el.dyn_ref::<web_sys::HtmlInputElement>()?;
    let val = input.value();
    if val.is_empty() {
        None
    } else {
        Some(val)
    }
}

#[cfg(target_arch = "wasm32")]
fn get_claimed_workspace_id_from_dom() -> Option<String> {
    let doc = web_sys::window().and_then(|w| w.document())?;
    let el = doc.get_element_by_id("claimed-workspace-id")?;
    let input = el.dyn_ref::<web_sys::HtmlInputElement>()?;
    let val = input.value();
    if val.is_empty() {
        None
    } else {
        Some(val)
    }
}

#[cfg(target_arch = "wasm32")]
fn restore_join_panel_state() {
    let Some(actor_id) = get_claimed_actor_id_from_dom() else {
        // No claimed actor, ensure join panel is visible
        swap_to_join_panel();
        return;
    };

    let current_workspace = config::current_workspace_id();
    let claimed_workspace = get_claimed_workspace_id_from_dom().unwrap_or_default();
    if claimed_workspace.trim().is_empty() || claimed_workspace.trim() != current_workspace {
        clear_claimed_state();
        swap_to_join_panel();
        return;
    }

    // Have claimed actor, show action panel
    swap_to_action_panel(&actor_id);
}

#[cfg(target_arch = "wasm32")]
fn friendly_claim_error(raw: &str) -> String {
    let text = raw.trim();
    let lower = text.to_ascii_lowercase();
    if lower.contains("already claimed") || lower.contains("already controlled") {
        "이미 다른 keeper가 점유한 캐릭터입니다.".to_string()
    } else if lower.contains("not found") || lower.contains("unknown actor") {
        "캐릭터 ID를 찾을 수 없습니다.".to_string()
    } else if lower.contains("workspace ended") || lower.contains("session ended") {
        "종료된 세션에서는 참여할 수 없습니다.".to_string()
    } else if lower.contains("unavailable") {
        "현재 세션 상태에서는 참여할 수 없습니다.".to_string()
    } else if text.is_empty() {
        "알 수 없는 오류".to_string()
    } else {
        text.to_string()
    }
}

#[cfg(target_arch = "wasm32")]
fn sync_actor_suggestions() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    sync_actor_suggestions_for_doc(&doc);
}

#[cfg(target_arch = "wasm32")]
fn sync_actor_suggestions_for_doc(doc: &web_sys::Document) {
    let Some(datalist) = doc.get_element_by_id("actor-id-suggestions") else {
        return;
    };
    let Some(input) = doc
        .get_element_by_id("actor-id-input")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    else {
        return;
    };

    let Ok(cards) = doc.query_selector_all("#character-panel .character-card[data-actor-id]") else {
        return;
    };

    let mut ids = Vec::new();
    for idx in 0..cards.length() {
        let Some(node) = cards.item(idx) else {
            continue;
        };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };
        let actor_id = el
            .get_attribute("data-actor-id")
            .unwrap_or_default()
            .trim()
            .to_string();
        if actor_id.is_empty() || actor_id.eq_ignore_ascii_case("dm") {
            continue;
        }
        ids.push(actor_id);
    }
    ids.sort();
    ids.dedup();

    let placeholder = if let Some(first) = ids.first() {
        format!("캐릭터 ID (예: {})", first)
    } else {
        "캐릭터 ID (오른쪽 PARTY 참고)".to_string()
    };
    if input.value().trim().is_empty() && input.placeholder() != placeholder {
        input.set_placeholder(&placeholder);
    }

    let signature = ids.join("|");
    if datalist
        .get_attribute("data-actor-signature")
        .map(|value| value == signature)
        .unwrap_or(false)
    {
        return;
    }

    datalist.set_inner_html("");
    for actor_id in ids.iter() {
        let Ok(option) = doc.create_element("option") else {
            continue;
        };
        let _ = option.set_attribute("value", actor_id);
        let _ = datalist.append_child(&option);
    }
    let _ = datalist.set_attribute("data-actor-signature", &signature);
}

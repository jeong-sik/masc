//! TRPG Action Panel — player action submission and dice rolling.
//!
//! Binds DOM event listeners on `#action-panel` elements:
//! - Submit button / Enter key → MCP Tool `masc_trpg_intervention_submit`
//! - Dice Roll button → MCP Tool `masc_trpg_dice_roll` (Manual override)
//! - Escape key → clear input and blur
//!
//! **Philosophy:**
//! We do NOT directly mutate the game state. We submit *Interventions*.
//! The AI Agents (Keepers) living in this society receive these interventions,
//! contemplate them, and decide whether to act upon them.
//! We are whispers in their ears, not puppeteers.
//!
//! **Closure lifecycle:** Event listeners use `Closure::forget()` intentionally.
//! WASM closures passed to JS must live as long as the DOM element. Since the
//! action panel DOM elements are removed on `OnExit(ViewerMode::Trpg)`, the JS
//! garbage collector reclaims the closure references when the elements are destroyed.
//! The `data-bound` attribute prevents double-binding on re-entry.

use bevy::prelude::*;

#[cfg(target_arch = "wasm32")]
use serde_json::json;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
use crate::config;
#[cfg(target_arch = "wasm32")]
use crate::game::lifecycle::TrpgLifecycleState;
use crate::game::state::{ConnectionStatus, WorkspaceState, TurnProgressState};
#[cfg(target_arch = "wasm32")]
use crate::http::{self, RpcResult};

// ─── Constants ──────────────────────────────

/// Maximum length for action input text.
#[cfg(any(target_arch = "wasm32", test))]
const MAX_ACTION_LEN: usize = 500;

/// Maximum number of entries in the action history panel.
#[cfg(target_arch = "wasm32")]
const MAX_HISTORY_ENTRIES: u32 = 5;

/// Milliseconds before auto-clearing a success status message.
#[cfg(target_arch = "wasm32")]
const STATUS_CLEAR_DELAY_MS: i32 = 3000;

// ─── Pure validation (testable without DOM) ─

/// Validate action input text. Returns `Ok(())` or an error message.
#[cfg(any(target_arch = "wasm32", test))]
pub(crate) fn validate_action_input(text: &str) -> Result<(), &'static str> {
    if text.is_empty() {
        return Err("Enter an action first");
    }
    if text.len() > MAX_ACTION_LEN {
        return Err("Action too long (max 500 chars)");
    }
    Ok(())
}

/// Extract a user-friendly display string from a successful dice roll RPC result.
#[cfg(any(target_arch = "wasm32", test))]
pub(crate) fn format_dice_result(rpc_result_json: &str) -> String {
    // Try to extract total from the MCP tool result content
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(rpc_result_json) {
        // MCP tool results are usually in result.content[0].text
        if let Some(content) = val.get("content").and_then(|c| c.as_array()) {
            if let Some(text) = content
                .first()
                .and_then(|c| c.get("text"))
                .and_then(|t| t.as_str())
            {
                // Try to parse the text as JSON for structured dice results
                if let Ok(inner) = serde_json::from_str::<serde_json::Value>(text) {
                    if let Some(total) = inner.get("total").and_then(|t| t.as_i64()) {
                        return format!("Rolled: {}", total);
                    }
                }
                // Fallback: use the text as-is if short enough
                if text.len() <= 80 {
                    return text.to_string();
                }
            }
        }
        // Direct result with total field
        if let Some(total) = val.get("total").and_then(|t| t.as_i64()) {
            return format!("Rolled: {}", total);
        }
    }
    "Rolled.".to_string()
}

/// Check if connection status allows player input.
#[cfg(any(target_arch = "wasm32", test))]
fn connection_ready(status: &ConnectionStatus) -> bool {
    matches!(status, ConnectionStatus::Connected)
}

// ─── Marker Resource ────────────────────────

#[derive(Resource)]
pub struct ActionPanelBound;

// ─── OnEnter System ─────────────────────────

pub fn bind_action_panel(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        log::info!("ActionPanel: Binding listeners (Intervention Mode)...");
        bind_submit_button();
        bind_enter_key();
        bind_action_input_recommendation();
        bind_escape_key();
        bind_dice_roll_button();
        clear_action_status();
        update_dice_skill_recommendation();

        log::info!("ActionPanel: bound complete");
    }

    commands.insert_resource(ActionPanelBound);
}

pub fn unbind_action_panel(mut commands: Commands) {
    #[cfg(target_arch = "wasm32")]
    {
        clear_action_status();
        clear_action_input();
        set_dice_roll_busy(false);
        log::info!("ActionPanel: unbound");
    }

    commands.remove_resource::<ActionPanelBound>();
}

// ─── Flight Lock ────────────────────────────
//
// Prevents concurrent async operations using a DOM attribute as a mutex.
// Adopted from turn_controls.rs `data-round-flight-owner` pattern.

#[cfg(target_arch = "wasm32")]
fn try_acquire_flight(doc: &web_sys::Document, owner: &str) -> bool {
    let Some(panel) = doc.get_element_by_id("action-panel") else {
        return false;
    };
    if panel.get_attribute("data-action-flight").is_some() {
        return false;
    }
    let _ = panel.set_attribute("data-action-flight", owner);
    true
}

#[cfg(target_arch = "wasm32")]
fn release_flight(doc: &web_sys::Document) {
    if let Some(panel) = doc.get_element_by_id("action-panel") {
        let _ = panel.remove_attribute("data-action-flight");
    }
}

// ─── Event Bindings ─────────────────────────

#[cfg(target_arch = "wasm32")]
fn bind_submit_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("action-submit-btn") else {
        return;
    };
    if btn.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = btn.set_attribute("data-bound", "1");

    let cb = Closure::wrap(Box::new(move || {
        log::info!("ActionPanel: Submit intervention");
        submit_intervention_from_input();
    }) as Box<dyn FnMut()>);

    let _ = btn
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn bind_enter_key() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(input) = doc.get_element_by_id("action-input") else {
        return;
    };
    if input.get_attribute("data-enter-bound").as_deref() == Some("1") {
        return;
    }
    let _ = input.set_attribute("data-enter-bound", "1");

    let cb = Closure::wrap(Box::new(move |event: web_sys::KeyboardEvent| {
        if event.key() == "Enter" {
            submit_intervention_from_input();
        }
    }) as Box<dyn FnMut(web_sys::KeyboardEvent)>);

    let _ = input
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("keydown", cb.as_ref().unchecked_ref()));
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn bind_escape_key() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(input) = doc.get_element_by_id("action-input") else {
        return;
    };
    if input.get_attribute("data-escape-bound").as_deref() == Some("1") {
        return;
    }
    let _ = input.set_attribute("data-escape-bound", "1");

    let cb = Closure::wrap(Box::new(move |event: web_sys::KeyboardEvent| {
        if event.key() == "Escape" {
            if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
                if let Some(el) = doc.get_element_by_id("action-input") {
                    if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
                        input.set_value("");
                        update_dice_skill_recommendation();
                        let _ = input.blur();
                    }
                }
            }
        }
    }) as Box<dyn FnMut(web_sys::KeyboardEvent)>);

    let _ = input
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("keydown", cb.as_ref().unchecked_ref()));
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn bind_action_input_recommendation() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(input) = doc.get_element_by_id("action-input") else {
        return;
    };
    if input.get_attribute("data-reco-bound").as_deref() == Some("1") {
        return;
    }
    let _ = input.set_attribute("data-reco-bound", "1");

    let cb = Closure::wrap(Box::new(move |_event: web_sys::Event| {
        update_dice_skill_recommendation();
    }) as Box<dyn FnMut(web_sys::Event)>);

    let _ = input
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("input", cb.as_ref().unchecked_ref()));
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn bind_dice_roll_button() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("dice-roll-btn") else {
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

        if !try_acquire_flight(&doc, "dice") {
            set_action_status("Action in progress...", "status-pending");
            return;
        }

        log::info!("ActionPanel: Manual Dice Roll (Divine Intervention)");
        set_action_status("Rolling destiny...", "status-pending");
        disable_buttons(true);
        set_dice_roll_busy(true);

        wasm_bindgen_futures::spawn_local(async move {
            let result = roll_dice_intervention().await;

            // Always re-enable buttons and release flight lock
            set_dice_roll_busy(false);
            disable_buttons(false);
            if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
                release_flight(&doc);
            }

            match result {
                Ok(text) => {
                    set_action_status(&text, "status-ok");
                    schedule_status_clear();
                }
                Err(msg) => {
                    set_action_status(&format!("Roll failed: {}", msg), "status-error");
                }
            }
        });
    }) as Box<dyn FnMut()>);

    let _ = btn
        .dyn_ref::<web_sys::EventTarget>()
        .map(|t| t.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref()));
    cb.forget();
}

// ─── Intervention Submission ────────────────

#[cfg(target_arch = "wasm32")]
fn submit_intervention_from_input() {
    // Submitting an intervention is explicit user activity.
    crate::game::round_runner::record_user_activity();

    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(el) = doc.get_element_by_id("action-input") else {
        return;
    };
    let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() else {
        return;
    };

    let text = input.value().trim().to_string();

    // P1: Input validation
    if let Err(msg) = validate_action_input(&text) {
        set_action_status(msg, "status-error");
        return;
    }

    let actor_id_opt = get_active_actor_from_dom();
    let Some(actor_id) = actor_id_opt else {
        set_action_status("No active agent to whisper to.", "status-error");
        return;
    };

    // P1: Flight lock — prevent concurrent submits
    if !try_acquire_flight(&doc, "submit") {
        set_action_status("Action in progress...", "status-pending");
        return;
    }

    input.set_value("");
    update_dice_skill_recommendation();
    set_action_status("Whispering to agent...", "status-pending");
    disable_buttons(true);

    let text_for_history = text.clone();

    wasm_bindgen_futures::spawn_local(async move {
        let result = submit_intervention(&actor_id, &text).await;

        // Always re-enable buttons and release flight lock (P0 fix)
        disable_buttons(false);
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            release_flight(&doc);
        }

        match result {
            Ok(()) => {
                set_action_status("Whisper sent. Waiting for agent...", "status-ok");
                append_to_history(&text_for_history);
                schedule_status_clear();
            }
            Err(msg) => {
                set_action_status(&format!("Failed to reach agent: {}", msg), "status-error");
            }
        }
    });
}

// ─── JSON-RPC: Submit Intervention ──────────

#[cfg(target_arch = "wasm32")]
async fn submit_intervention(actor_id: &str, suggestion: &str) -> Result<(), String> {
    let url = config::build_masc_url("mcp");
    let workspace_id = config::current_workspace_id();

    let params = json!({
        "name": "masc_trpg_intervention_submit",
        "arguments": {
            "session_id": workspace_id,
            "workspace_id": workspace_id,
            "target_actor": actor_id,
            "intervention_type": "human_suggestion",
            "reason": "Viewer user input",
            "payload": {
                "suggestion": suggestion,
                "priority": "high"
            }
        }
    });

    match http::rpc_call(&url, "tools/call", params).await {
        RpcResult::Ok(_) => Ok(()),
        other => Err(other.display_error()),
    }
}

// ─── JSON-RPC: Manual Dice Roll ─────────────

#[cfg(target_arch = "wasm32")]
async fn roll_dice_intervention() -> Result<String, String> {
    let Some(actor_id) = get_active_actor_from_dom() else {
        return Err("No active actor".into());
    };

    let url = config::build_masc_url("mcp");
    let workspace_id = config::current_workspace_id();

    let params = json!({
        "name": "masc_trpg_dice_roll",
        "arguments": {
            "workspace_id": workspace_id,
            "actor_id": actor_id,
            "action": "manual_check",
            "stat_value": 0,
            "dc": 0
        }
    });

    match http::rpc_call(&url, "tools/call", params).await {
        RpcResult::Ok(result_json) => Ok(format_dice_result(&result_json)),
        other => Err(other.display_error()),
    }
}

// ─── UI Helpers ─────────────────────────────

#[cfg(target_arch = "wasm32")]
fn clear_action_status() {
    set_action_status("Ready", "");
}

#[cfg(target_arch = "wasm32")]
fn clear_action_input() {
    if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
        if let Some(el) = doc.get_element_by_id("action-input") {
            if let Some(input) = el.dyn_ref::<web_sys::HtmlInputElement>() {
                input.set_value("");
            }
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn set_action_status(text: &str, css_class: &str) {
    if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
        if let Some(el) = doc.get_element_by_id("action-status") {
            el.set_text_content(Some(text));
            el.set_class_name(css_class);
        }
    }
}

/// Schedule auto-clear of the status message after a delay.
#[cfg(target_arch = "wasm32")]
fn schedule_status_clear() {
    let cb = Closure::once(Box::new(move || {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            if let Some(el) = doc.get_element_by_id("action-status") {
                // Only clear if the current message is a success message
                if el.class_name() == "status-ok" {
                    el.set_text_content(Some("Ready"));
                    el.set_class_name("");
                }
            }
        }
    }) as Box<dyn FnOnce()>);

    if let Some(window) = web_sys::window() {
        let _ = window.set_timeout_with_callback_and_timeout_and_arguments_0(
            cb.as_ref().unchecked_ref(),
            STATUS_CLEAR_DELAY_MS,
        );
    }
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
pub(crate) fn friendly_js_error(val: &JsValue) -> String {
    val.as_string()
        .or_else(|| val.dyn_ref::<js_sys::Error>().map(|e| e.message().into()))
        .unwrap_or_else(|| format!("{:?}", val))
}

#[cfg(target_arch = "wasm32")]
fn get_active_actor_from_dom() -> Option<String> {
    let doc = web_sys::window().and_then(|w| w.document())?;
    get_current_actor_from_doc(&doc)
}

#[cfg(target_arch = "wasm32")]
fn get_current_actor_from_doc(doc: &web_sys::Document) -> Option<String> {
    let panel = doc.get_element_by_id("action-panel")?;
    let actor_id = panel.get_attribute("data-active-actor").unwrap_or_default();
    if actor_id.is_empty() {
        doc.get_element_by_id("player-actor-id")
            .and_then(|el| el.text_content())
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    } else {
        Some(actor_id.trim().to_string())
    }
}

#[cfg(target_arch = "wasm32")]
fn disable_buttons(disabled: bool) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };

    if let Some(btn) = doc.get_element_by_id("action-submit-btn") {
        if disabled {
            let _ = btn.set_attribute("disabled", "true");
        } else {
            let _ = btn.remove_attribute("disabled");
        }
    }
    if let Some(btn) = doc.get_element_by_id("dice-roll-btn") {
        if disabled {
            let _ = btn.set_attribute("disabled", "true");
        } else {
            let _ = btn.remove_attribute("disabled");
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn set_dice_roll_busy(busy: bool) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(btn) = doc.get_element_by_id("dice-roll-btn") else {
        return;
    };
    if busy {
        let _ = btn.class_list().add_1("is-rolling");
        let _ = btn.set_attribute("aria-busy", "true");
        let _ = btn.set_attribute("data-roll-intensity", "high");
    } else {
        let _ = btn.class_list().remove_1("is-rolling");
        let _ = btn.remove_attribute("aria-busy");
        let _ = btn.remove_attribute("data-roll-intensity");
    }
}

#[cfg(target_arch = "wasm32")]
fn parse_skill_modifier(text: &str) -> Option<i32> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    trimmed
        .parse::<i32>()
        .ok()
        .or_else(|| trimmed.trim_start_matches('+').parse::<i32>().ok())
}

#[cfg(target_arch = "wasm32")]
fn parse_skill_level(text: &str) -> Option<i32> {
    text.trim().parse::<i32>().ok()
}

#[cfg(target_arch = "wasm32")]
fn parse_hp_ratio(text: &str) -> Option<f32> {
    let mut values = text
        .split('/')
        .filter_map(|part| {
            let token = part
                .chars()
                .filter(|ch| ch.is_ascii_digit() || *ch == '-')
                .collect::<String>();
            if token.is_empty() {
                None
            } else {
                token.parse::<f32>().ok()
            }
        })
        .take(2);
    let current = values.next()?;
    let max = values.next()?;
    if max <= 0.0 {
        return None;
    }
    Some((current / max).clamp(0.0, 1.0))
}

#[cfg(any(target_arch = "wasm32", test))]
#[derive(Clone, Copy)]
enum ActionIntent {
    Combat,
    Exploration,
    Social,
    Mobility,
    Support,
}

#[cfg(any(target_arch = "wasm32", test))]
impl ActionIntent {
    fn label(self) -> &'static str {
        match self {
            ActionIntent::Combat => "전투",
            ActionIntent::Exploration => "탐색",
            ActionIntent::Social => "대화",
            ActionIntent::Mobility => "기동",
            ActionIntent::Support => "지원",
        }
    }
}

#[cfg(target_arch = "wasm32")]
#[derive(Clone)]
struct SkillEntry {
    name: String,
    level: i32,
    modifier: i32,
}

#[cfg(target_arch = "wasm32")]
#[derive(Clone)]
struct RankedSkill {
    name: String,
    modifier: i32,
    score: i32,
}

#[cfg(any(target_arch = "wasm32", test))]
fn contains_any_keyword(haystack: &str, keywords: &[&str]) -> bool {
    keywords.iter().any(|keyword| haystack.contains(keyword))
}

#[cfg(any(target_arch = "wasm32", test))]
fn detect_action_intents(text: &str) -> Vec<ActionIntent> {
    let normalized = text.trim().to_lowercase();
    if normalized.is_empty() {
        return Vec::new();
    }

    let mut intents = Vec::new();
    if contains_any_keyword(
        &normalized,
        &[
            "attack", "strike", "slash", "shoot", "cast", "smite", "combat", "fight", "hit",
            "공격", "전투", "베기", "찌르", "강타", "타격", "주문", "마법", "사격",
        ],
    ) {
        intents.push(ActionIntent::Combat);
    }
    if contains_any_keyword(
        &normalized,
        &[
            "search",
            "scout",
            "track",
            "investigate",
            "explore",
            "perception",
            "trap",
            "lockpick",
            "탐색",
            "정찰",
            "추적",
            "조사",
            "함정",
            "잠금",
            "탐지",
        ],
    ) {
        intents.push(ActionIntent::Exploration);
    }
    if contains_any_keyword(
        &normalized,
        &[
            "talk",
            "speak",
            "persuade",
            "negotiate",
            "intimidate",
            "deceive",
            "charisma",
            "대화",
            "설득",
            "협상",
            "협박",
            "기만",
            "교섭",
            "말을",
        ],
    ) {
        intents.push(ActionIntent::Social);
    }
    if contains_any_keyword(
        &normalized,
        &[
            "move", "dash", "dodge", "escape", "run", "jump", "climb", "stealth", "sneak", "이동",
            "질주", "회피", "도주", "점프", "등반", "은신", "숨",
        ],
    ) {
        intents.push(ActionIntent::Mobility);
    }
    if contains_any_keyword(
        &normalized,
        &[
            "heal", "cure", "recover", "support", "guard", "protect", "aid", "buff", "치유",
            "회복", "지원", "보호", "방어", "수호", "버프",
        ],
    ) {
        intents.push(ActionIntent::Support);
    }

    intents
}

#[cfg(any(target_arch = "wasm32", test))]
fn intent_skill_bonus(skill_name: &str, intents: &[ActionIntent], hp_ratio: Option<f32>) -> i32 {
    let normalized = skill_name.to_lowercase();
    let mut bonus = 0;

    for intent in intents {
        let matched = match intent {
            ActionIntent::Combat => contains_any_keyword(
                &normalized,
                &[
                    "attack", "slash", "strike", "smite", "weapon", "fire", "arcane", "blast",
                    "assault", "공격", "강타", "베기", "찌르", "타격", "마법", "주문",
                ],
            ),
            ActionIntent::Exploration => contains_any_keyword(
                &normalized,
                &[
                    "search",
                    "scout",
                    "track",
                    "investigate",
                    "perception",
                    "insight",
                    "trap",
                    "lock",
                    "탐색",
                    "정찰",
                    "추적",
                    "조사",
                    "탐지",
                    "함정",
                    "잠금",
                ],
            ),
            ActionIntent::Social => contains_any_keyword(
                &normalized,
                &[
                    "talk",
                    "speech",
                    "persuade",
                    "charm",
                    "intimidate",
                    "deception",
                    "perform",
                    "대화",
                    "설득",
                    "협상",
                    "협박",
                    "기만",
                    "교섭",
                    "매혹",
                ],
            ),
            ActionIntent::Mobility => contains_any_keyword(
                &normalized,
                &[
                    "dodge", "dash", "jump", "climb", "evade", "stealth", "sneak", "agile", "회피",
                    "질주", "도주", "은신", "점프", "등반", "기동",
                ],
            ),
            ActionIntent::Support => contains_any_keyword(
                &normalized,
                &[
                    "heal", "cure", "recover", "protect", "guard", "barrier", "bless", "aid",
                    "ward", "치유", "회복", "방어", "보호", "수호", "가호", "지원",
                ],
            ),
        };
        if matched {
            bonus += 45;
        }
    }

    if hp_ratio.is_some_and(|ratio| ratio <= 0.35)
        && contains_any_keyword(
            &normalized,
            &[
                "guard", "protect", "barrier", "heal", "recover", "ward", "회피", "방어", "보호",
                "치유", "회복", "저항", "수호",
            ],
        )
    {
        bonus += 30;
    }

    bonus
}

#[cfg(any(target_arch = "wasm32", test))]
fn format_reco_context(
    action_text: &str,
    intents: &[ActionIntent],
    hp_ratio: Option<f32>,
) -> String {
    let mut labels = if action_text.trim().is_empty() {
        vec!["기본".to_string()]
    } else if intents.is_empty() {
        vec!["행동문맥".to_string()]
    } else {
        intents
            .iter()
            .take(2)
            .map(|intent| intent.label().to_string())
            .collect::<Vec<_>>()
    };

    if hp_ratio.is_some_and(|ratio| ratio <= 0.35) {
        labels.push("저체력".to_string());
    }
    labels.join("·")
}

#[cfg(target_arch = "wasm32")]
fn update_dice_skill_recommendation() {
    const MAX_RECOMMENDED_SKILLS: usize = 3;

    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(reco) = doc.get_element_by_id("dice-skill-reco") else {
        return;
    };
    let action_text = doc
        .get_element_by_id("action-input")
        .and_then(|el| {
            el.dyn_ref::<web_sys::HtmlInputElement>()
                .map(|input| input.value())
        })
        .unwrap_or_default();
    let intents = detect_action_intents(&action_text);

    let Some(actor_id) = get_current_actor_from_doc(&doc) else {
        reco.set_text_content(Some(
            "추천 스킬: 액터 턴이 시작되면 상위 Modifier 스킬을 보여줍니다.",
        ));
        return;
    };

    let Ok(cards) = doc.query_selector_all(".character-card") else {
        reco.set_text_content(Some("추천 스킬: 캐릭터 데이터를 불러오는 중입니다."));
        return;
    };

    let mut rendered = false;
    for i in 0..cards.length() {
        let Some(node) = cards.item(i) else {
            continue;
        };
        let Some(card) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };
        let Some(card_actor_id) = card.get_attribute("data-actor-id") else {
            continue;
        };
        if card_actor_id.trim() != actor_id {
            continue;
        }
        let hp_ratio = card
            .query_selector(".hp-text")
            .ok()
            .flatten()
            .and_then(|el| el.text_content())
            .and_then(|text| parse_hp_ratio(&text));

        let Ok(rows) = card.query_selector_all(".skills-list .skill-row") else {
            break;
        };
        let mut skills = Vec::<SkillEntry>::new();
        for row_idx in 0..rows.length() {
            let Some(row_node) = rows.item(row_idx) else {
                continue;
            };
            let Some(row) = row_node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            if row.class_list().contains("skill-row-head") {
                continue;
            }

            let skill_name = row
                .query_selector(".skill-name")
                .ok()
                .flatten()
                .and_then(|el| el.text_content())
                .map(|text| text.trim().to_string())
                .unwrap_or_default();
            if skill_name.is_empty() {
                continue;
            }

            let modifier = row
                .query_selector(".skill-mod")
                .ok()
                .flatten()
                .and_then(|el| el.text_content())
                .and_then(|text| parse_skill_modifier(&text));
            let level = row
                .query_selector(".skill-level")
                .ok()
                .flatten()
                .and_then(|el| el.text_content())
                .and_then(|text| parse_skill_level(&text))
                .unwrap_or(0);
            if let Some(modifier) = modifier {
                skills.push(SkillEntry {
                    name: skill_name,
                    level,
                    modifier,
                });
            }
        }

        let ranked = skills
            .into_iter()
            .map(|skill| {
                let score = skill.modifier * 100
                    + skill.level
                    + intent_skill_bonus(&skill.name, &intents, hp_ratio);
                RankedSkill {
                    name: skill.name,
                    modifier: skill.modifier,
                    score,
                }
            })
            .collect::<Vec<_>>();
        let mut ranked = ranked;
        ranked.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.name.cmp(&b.name)));
        ranked.truncate(MAX_RECOMMENDED_SKILLS);
        let summary = ranked
            .into_iter()
            .map(|skill| format!("{} ({:+})", skill.name, skill.modifier))
            .collect::<Vec<_>>()
            .join(" · ");
        let context = format_reco_context(&action_text, &intents, hp_ratio);
        if summary.is_empty() {
            reco.set_text_content(Some(&format!(
                "추천 스킬 [{}]: 표시 가능한 스킬이 없습니다.",
                actor_id
            )));
        } else {
            reco.set_text_content(Some(&format!(
                "추천 스킬 [{} · {}]: {}",
                actor_id, context, summary
            )));
        }
        rendered = true;
        break;
    }

    if !rendered {
        reco.set_text_content(Some(&format!(
            "추천 스킬 [{}]: 표시 가능한 스킬이 없습니다.",
            actor_id
        )));
    }
}

// ─── Action History ─────────────────────────

/// Append a completed action to the action history panel (max 5 entries).
#[cfg(target_arch = "wasm32")]
fn append_to_history(text: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(history) = doc.get_element_by_id("action-history") else {
        return;
    };

    let Ok(entry) = doc.create_element("div") else {
        return;
    };
    entry.set_class_name("history-entry");

    // Truncate display text for readability
    let display = if text.len() > 60 {
        format!("{}...", &text[..60])
    } else {
        text.to_string()
    };
    entry.set_text_content(Some(&display));

    // Prepend (newest first)
    let _ = history.prepend_with_node_1(&entry);

    // Trim to max entries
    while history.child_element_count() > MAX_HISTORY_ENTRIES {
        if let Some(last) = history.last_element_child() {
            last.remove();
        } else {
            break;
        }
    }
}

// ─── System ─────────────────────────────────

#[allow(unused_variables)]
pub fn sync_action_panel_interaction_state(
    workspace_state: Res<WorkspaceState>,
    progress: Res<TurnProgressState>,
    connection: Res<ConnectionStatus>,
) {
    let _ = &workspace_state;
    let _ = &connection;
    #[cfg(target_arch = "wasm32")]
    {
        let active_actor = &progress.current_actor;
        let lifecycle =
            TrpgLifecycleState::from_workspace_progress(&workspace_state.status, &progress.workspace_status);
        let connected = connection_ready(&connection);

        // P2: Connection-aware disable — all three conditions must be true
        let can_act = lifecycle.accepts_player_input()
            && !active_actor.is_empty()
            && active_actor != "dm"
            && connected;

        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            let mut reco_refresh_needed = true;
            if let Some(panel) = doc.get_element_by_id("action-panel") {
                reco_refresh_needed = panel
                    .get_attribute("data-reco-actor")
                    .as_deref()
                    .map(|prev| prev != active_actor)
                    .unwrap_or(true);
                let _ = panel.set_attribute("data-active-actor", active_actor);
                if reco_refresh_needed {
                    let _ = panel.set_attribute("data-reco-actor", active_actor);
                }
            }
            if reco_refresh_needed {
                update_dice_skill_recommendation();
            }

            // Only disable from system sync if no flight is in progress
            // (flight lock handles its own button state)
            let flight_active = doc
                .get_element_by_id("action-panel")
                .and_then(|p| p.get_attribute("data-action-flight"))
                .is_some();

            if !flight_active {
                disable_buttons(!can_act);
            }

            if let Some(input) = doc.get_element_by_id("action-input") {
                let placeholder = if !connected {
                    "Connecting to engine...".to_string()
                } else if can_act {
                    format!("Whisper suggestion to {}...", active_actor)
                } else if !lifecycle.accepts_player_input() {
                    format!("{}...", lifecycle.help_text())
                } else {
                    "Waiting for agent turn...".to_string()
                };
                let _ = input.set_attribute("placeholder", &placeholder);
            }
        }
    }
}

// ─── Tests ──────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_empty_input() {
        assert_eq!(validate_action_input(""), Err("Enter an action first"));
    }

    #[test]
    fn validate_normal_input() {
        assert!(validate_action_input("I attack the goblin").is_ok());
    }

    #[test]
    fn validate_max_length_input() {
        let text = "a".repeat(MAX_ACTION_LEN);
        assert!(validate_action_input(&text).is_ok());
    }

    #[test]
    fn validate_too_long_input() {
        let text = "a".repeat(MAX_ACTION_LEN + 1);
        assert_eq!(
            validate_action_input(&text),
            Err("Action too long (max 500 chars)")
        );
    }

    #[test]
    fn format_dice_with_total() {
        let json = r#"{"total":15,"roll":12,"modifier":3}"#;
        assert_eq!(format_dice_result(json), "Rolled: 15");
    }

    #[test]
    fn format_dice_with_mcp_content() {
        let json = r#"{"content":[{"type":"text","text":"{\"total\":18,\"roll\":15}"}]}"#;
        assert_eq!(format_dice_result(json), "Rolled: 18");
    }

    #[test]
    fn format_dice_with_plain_text_content() {
        let json = r#"{"content":[{"type":"text","text":"Natural 20!"}]}"#;
        assert_eq!(format_dice_result(json), "Natural 20!");
    }

    #[test]
    fn format_dice_fallback() {
        assert_eq!(format_dice_result("not json"), "Rolled.");
        assert_eq!(format_dice_result(r#"{"foo":"bar"}"#), "Rolled.");
    }

    #[test]
    fn connection_ready_variants() {
        assert!(connection_ready(&ConnectionStatus::Connected));
        assert!(!connection_ready(&ConnectionStatus::Disconnected));
        assert!(!connection_ready(&ConnectionStatus::Connecting));
        assert!(!connection_ready(&ConnectionStatus::Failed));
    }

    #[test]
    fn detect_action_intents_combat_and_support() {
        let intents = detect_action_intents("공격하고 회복 마법 준비");
        assert_eq!(intents.len(), 2);
        assert!(matches!(intents[0], ActionIntent::Combat));
        assert!(matches!(intents[1], ActionIntent::Support));
    }

    #[test]
    fn detect_action_intents_empty() {
        assert!(detect_action_intents("   ").is_empty());
    }

    #[test]
    fn intent_skill_bonus_prefers_matching_domain() {
        let intents = detect_action_intents("공격");
        let combat_bonus = intent_skill_bonus("강타", &intents, Some(1.0));
        let social_bonus = intent_skill_bonus("설득", &intents, Some(1.0));
        assert!(combat_bonus > social_bonus);
    }

    #[test]
    fn intent_skill_bonus_adds_low_hp_survival_weight() {
        let intents = detect_action_intents("공격");
        let low_hp_bonus = intent_skill_bonus("방어 태세", &intents, Some(0.2));
        let normal_hp_bonus = intent_skill_bonus("방어 태세", &intents, Some(0.9));
        assert!(low_hp_bonus > normal_hp_bonus);
    }

    #[test]
    fn format_reco_context_includes_intent_and_low_hp() {
        let intents = detect_action_intents("은신 이동");
        let label = format_reco_context("은신 이동", &intents, Some(0.3));
        assert!(label.contains("기동"));
        assert!(label.contains("저체력"));
    }
}

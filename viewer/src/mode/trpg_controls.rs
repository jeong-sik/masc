//! TRPG controls — actor admin CRUD, new game flow, preset system, UI event binding.
//!
//! Extracted from `mod.rs` to reduce file size.
//! All items are `#[cfg(target_arch = "wasm32")]` gated at the module level
//! (the parent `mod trpg_controls` declaration carries the gate).

use serde_json::{json, Value};
use std::collections::HashMap;
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use wasm_bindgen_futures::JsFuture;

use crate::dom::escape::html_escape;
use crate::game::lifecycle::TrpgUiState;

use super::{
    assign_keepers_to_actor_ids, clear_trpg_dom, generate_room_id, mcp_tool_call,
    parse_embedded_tool_payload, render_dedup_popover, set_current_room_id, set_element_display,
    set_new_game_preflight_rows, set_new_game_preflight_status, set_new_game_status,
    set_round_run_fields, unique_non_empty,
};

// ─── Structs ─────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
struct PresetOption {
    id: String,
    title: String,
}

#[derive(Debug, Clone)]
struct NewGameBootstrap {
    keepers: Vec<String>,
    world_presets: Vec<PresetOption>,
    dm_presets: Vec<PresetOption>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ActorAdminRow {
    actor_id: String,
    name: String,
    role: String,
    hp: i32,
    max_hp: i32,
    keeper: String,
    claimed: bool,
}

fn parse_actor_control_map(state_root: &Value) -> HashMap<String, String> {
    let state = state_root.get("state").unwrap_or(state_root);
    state
        .get("actor_control")
        .and_then(Value::as_object)
        .map(|rows| {
            rows.iter()
                .filter_map(|(actor_id, keeper)| {
                    let actor_id = actor_id.trim();
                    let keeper = keeper.as_str().unwrap_or("").trim();
                    if actor_id.is_empty() || keeper.is_empty() {
                        None
                    } else {
                        Some((actor_id.to_string(), keeper.to_string()))
                    }
                })
                .collect::<HashMap<_, _>>()
        })
        .unwrap_or_default()
}

fn parse_keeper_actor_map(state_root: &Value) -> HashMap<String, String> {
    parse_actor_control_map(state_root)
        .into_iter()
        .map(|(actor_id, keeper)| (keeper, actor_id))
        .collect::<HashMap<_, _>>()
}

fn read_new_game_room_id(doc: &web_sys::Document) -> String {
    let ui_room = doc
        .get_element_by_id("new-game-room-id")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
        .map(|input| input.value())
        .unwrap_or_default()
        .trim()
        .to_string();
    if ui_room.is_empty() {
        actor_admin_room_id()
    } else {
        ui_room
    }
}

fn explain_claim_conflict(raw: &str) -> String {
    let msg = raw.trim();
    let normalized = msg.to_ascii_lowercase();
    if normalized.contains("actor already claimed") {
        format!(
            "{} · 이미 다른 keeper가 점유 중입니다. 기존 owner를 확인한 뒤 점유 해제 후 다시 시도하세요.",
            msg
        )
    } else if normalized.contains("keeper already controls actor") {
        format!(
            "{} · keeper는 한 번에 한 actor만 점유할 수 있습니다. 기존 점유를 해제하거나 다른 keeper를 선택하세요.",
            msg
        )
    } else if normalized.contains("actor is not claimed") {
        format!("{} · 이미 점유 해제된 상태입니다.", msg)
    } else {
        msg.to_string()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NewGameFlowStage {
    Idle,
    Bootstrap,
    Preflight,
    ValidatingInput,
    ResolvingPreset,
    GeneratingPool,
    SelectingParty,
    StartingSession,
    ClaimingActors,
    BootingKeepers,
    Finalizing,
    Done,
    Failed,
}

impl NewGameFlowStage {
    fn code(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Bootstrap => "bootstrap",
            Self::Preflight => "preflight",
            Self::ValidatingInput => "validating-input",
            Self::ResolvingPreset => "resolving-preset",
            Self::GeneratingPool => "generating-pool",
            Self::SelectingParty => "selecting-party",
            Self::StartingSession => "starting-session",
            Self::ClaimingActors => "claiming-actors",
            Self::BootingKeepers => "booting-keepers",
            Self::Finalizing => "finalizing",
            Self::Done => "done",
            Self::Failed => "failed",
        }
    }

    fn label_ko(self) -> &'static str {
        match self {
            Self::Idle => "대기",
            Self::Bootstrap => "초기 동기화",
            Self::Preflight => "사전 점검",
            Self::ValidatingInput => "입력 검증",
            Self::ResolvingPreset => "프리셋 확인",
            Self::GeneratingPool => "플레이어 풀 생성",
            Self::SelectingParty => "파티 구성",
            Self::StartingSession => "세션 시작",
            Self::ClaimingActors => "액터 점유",
            Self::BootingKeepers => "키퍼 부팅",
            Self::Finalizing => "최종 동기화",
            Self::Done => "완료",
            Self::Failed => "실패",
        }
    }

    fn css_class(self) -> &'static str {
        match self {
            Self::Done => "is-ok",
            Self::Failed => "is-error",
            Self::Idle => "is-pending",
            _ => "is-active",
        }
    }
}

impl From<&str> for NewGameFlowStage {
    fn from(raw: &str) -> Self {
        match raw.trim() {
            "bootstrap" => Self::Bootstrap,
            "preflight" => Self::Preflight,
            "validating-input" => Self::ValidatingInput,
            "resolving-preset" => Self::ResolvingPreset,
            "generating-pool" => Self::GeneratingPool,
            "selecting-party" => Self::SelectingParty,
            "starting-session" => Self::StartingSession,
            "claiming-actors" => Self::ClaimingActors,
            "booting-keepers" => Self::BootingKeepers,
            "finalizing" => Self::Finalizing,
            "done" => Self::Done,
            "failed" => Self::Failed,
            _ => Self::Idle,
        }
    }
}

// ─── Helpers (moved from mod.rs, only used here) ────────────────

fn parse_keeper_models(raw: &str) -> Vec<String> {
    unique_non_empty(
        raw.split(',')
            .map(|part| part.trim().to_string())
            .collect::<Vec<_>>(),
    )
}

fn selected_player_keepers(doc: &web_sys::Document) -> Vec<String> {
    let Ok(nodes) = doc.query_selector_all("#new-game-player-select option:checked") else {
        return Vec::new();
    };
    let mut keepers = Vec::new();
    for i in 0..nodes.length() {
        let Some(node) = nodes.item(i) else { continue };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };
        let Some(value) = el.get_attribute("value") else {
            continue;
        };
        let value = value.trim();
        if value.is_empty() {
            continue;
        }
        keepers.push(value.to_string());
    }
    unique_non_empty(keepers)
}

fn set_manual_mapping_order(doc: &web_sys::Document, order: &[String]) {
    let Some(panel) = doc.get_element_by_id("new-game-panel") else {
        return;
    };
    let payload = Value::Array(
        order
            .iter()
            .map(|keeper| Value::String(keeper.trim().to_string()))
            .collect::<Vec<_>>(),
    )
    .to_string();
    let _ = panel.set_attribute("data-manual-order", &payload);
}

fn manual_mapping_order(doc: &web_sys::Document) -> Vec<String> {
    let Some(raw) = doc
        .get_element_by_id("new-game-panel")
        .and_then(|panel| panel.get_attribute("data-manual-order"))
    else {
        return Vec::new();
    };
    serde_json::from_str::<Value>(&raw)
        .ok()
        .and_then(|value| value.as_array().cloned())
        .map(|rows| {
            rows.iter()
                .filter_map(Value::as_str)
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
                .collect::<Vec<_>>()
        })
        .map(unique_non_empty)
        .unwrap_or_default()
}

fn normalize_manual_keeper_order(order: Vec<String>, selected: &[String]) -> Vec<String> {
    let selected_unique = unique_non_empty(selected.to_vec());
    if selected_unique.is_empty() {
        return Vec::new();
    }
    let mut normalized = Vec::with_capacity(selected_unique.len());
    for keeper in order {
        let keeper = keeper.trim().to_string();
        if keeper.is_empty() {
            continue;
        }
        if !selected_unique.iter().any(|name| name == &keeper) {
            continue;
        }
        if normalized.iter().any(|name| name == &keeper) {
            continue;
        }
        normalized.push(keeper);
    }
    for keeper in selected_unique {
        if normalized.iter().any(|name| name == &keeper) {
            continue;
        }
        normalized.push(keeper);
    }
    normalized
}

fn manual_player_keeper_order_for_display(
    doc: &web_sys::Document,
    selected: &[String],
) -> Vec<String> {
    normalize_manual_keeper_order(manual_mapping_order(doc), selected)
}

fn manual_player_keeper_order_for_assignment(
    doc: &web_sys::Document,
    selected: &[String],
) -> Result<Vec<String>, String> {
    let selected_unique = unique_non_empty(selected.to_vec());
    if selected_unique.is_empty() {
        return Ok(Vec::new());
    }
    let order = normalize_manual_keeper_order(manual_mapping_order(doc), &selected_unique);
    if order.len() != selected_unique.len() {
        return Err(format!(
            "수동 매핑이 불완전합니다. keeper {}명 중 {}명만 매핑되었습니다.",
            selected_unique.len(),
            order.len()
        ));
    }
    Ok(order)
}

fn current_player_actor_slots_from_actor_admin(doc: &web_sys::Document) -> Vec<String> {
    let Ok(nodes) = doc.query_selector_all("#actor-admin-list .actor-admin-row") else {
        return Vec::new();
    };
    let mut preferred = Vec::new();
    let mut fallback = Vec::new();
    for idx in 0..nodes.length() {
        let Some(node) = nodes.item(idx) else {
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
        let role = el
            .get_attribute("data-role")
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase();
        if role == "player" || role.is_empty() {
            preferred.push(actor_id);
            continue;
        }
        if role != "dm" {
            fallback.push(actor_id);
        }
    }
    let mut slots = if preferred.is_empty() {
        fallback
    } else {
        preferred
    };
    slots = unique_non_empty(slots);
    slots.sort();
    slots
}

fn recommended_manual_mapping_order(
    doc: &web_sys::Document,
    selected: &[String],
) -> (Vec<String>, usize, usize) {
    let selected_unique = unique_non_empty(selected.to_vec());
    if selected_unique.is_empty() {
        return (Vec::new(), 0, 0);
    }

    let keeper_actor_map = keeper_actor_map_from_actor_admin_dom(doc);
    let slot_actors = current_player_actor_slots_from_actor_admin(doc);
    let slot_count = selected_unique.len();

    let mut ordered = vec![String::new(); slot_count];
    let mut matched_count = 0usize;
    for keeper in &selected_unique {
        let Some(actor_id) = keeper_actor_map.get(keeper) else {
            continue;
        };
        let Some(slot_idx) = slot_actors
            .iter()
            .position(|slot_actor| slot_actor == actor_id)
        else {
            continue;
        };
        if slot_idx >= slot_count || !ordered[slot_idx].is_empty() {
            continue;
        }
        ordered[slot_idx] = keeper.clone();
        matched_count += 1;
    }

    let fallback_order = normalize_manual_keeper_order(manual_mapping_order(doc), &selected_unique);
    let mut leftovers = fallback_order
        .into_iter()
        .filter(|keeper| !ordered.iter().any(|picked| picked == keeper))
        .collect::<Vec<_>>();
    for keeper in selected_unique {
        if ordered.iter().any(|picked| picked == &keeper)
            || leftovers.iter().any(|picked| picked == &keeper)
        {
            continue;
        }
        leftovers.push(keeper);
    }

    for slot in &mut ordered {
        if slot.is_empty() {
            let next = leftovers.first().cloned().unwrap_or_default();
            if !next.is_empty() {
                *slot = next.clone();
                leftovers.remove(0);
            }
        }
    }

    let order = ordered
        .into_iter()
        .filter(|keeper| !keeper.trim().is_empty())
        .collect::<Vec<_>>();
    (order, matched_count, slot_actors.len())
}

fn bind_manual_mapping_selects(doc: &web_sys::Document) {
    let Ok(nodes) = doc.query_selector_all("#new-game-manual-table .manual-map-select") else {
        return;
    };
    for idx in 0..nodes.length() {
        let Some(node) = nodes.item(idx) else {
            continue;
        };
        let Some(select) = node.dyn_ref::<web_sys::HtmlSelectElement>() else {
            continue;
        };
        if select.get_attribute("data-bound").as_deref() == Some("1") {
            continue;
        }
        let _ = select.set_attribute("data-bound", "1");

        let slot_idx = select
            .get_attribute("data-slot-index")
            .and_then(|raw| raw.parse::<usize>().ok())
            .unwrap_or(0);
        let cb = Closure::wrap(Box::new(move |_event: web_sys::Event| {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let current_selected = selected_player_keepers(&doc);
            if current_selected.is_empty() {
                set_manual_mapping_order(&doc, &[]);
                return;
            }

            let mut order =
                normalize_manual_keeper_order(manual_mapping_order(&doc), &current_selected);
            let Some(target_select) = doc
                .query_selector(&format!(
                    "#new-game-manual-table .manual-map-select[data-slot-index=\"{}\"]",
                    slot_idx
                ))
                .ok()
                .flatten()
                .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
            else {
                return;
            };
            let picked = target_select.value().trim().to_string();
            if picked.is_empty() {
                return;
            }

            if let Some(existing_idx) = order.iter().position(|name| name == &picked) {
                if existing_idx != slot_idx && slot_idx < order.len() {
                    order.swap(existing_idx, slot_idx);
                }
            } else if slot_idx >= order.len() {
                order.push(picked);
            } else {
                order[slot_idx] = picked;
            }
            let normalized = normalize_manual_keeper_order(order, &current_selected);
            set_manual_mapping_order(&doc, &normalized);
            sync_manual_mapping_table(&doc);
            sync_new_game_wizard_ui(&doc);
        }) as Box<dyn FnMut(_)>);
        let _ = select.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("change", cb.as_ref().unchecked_ref())
        });
        cb.forget();
    }
}

fn sync_manual_mapping_table(doc: &web_sys::Document) {
    let Some(table) = doc.get_element_by_id("new-game-manual-table") else {
        return;
    };
    let busy = new_game_wizard_busy(doc);
    if let Some(reset_btn) = doc
        .get_element_by_id("new-game-manual-reset")
        .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
    {
        reset_btn.set_disabled(busy);
    }
    if let Some(recommend_btn) = doc
        .get_element_by_id("new-game-manual-recommend")
        .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
    {
        recommend_btn.set_disabled(busy);
    }
    let selected = selected_player_keepers(doc);
    if selected.is_empty() {
        table.set_inner_html(
            "<div class=\"room-chip-empty\">플레이어 keeper를 먼저 선택하세요.</div>",
        );
        if let Some(help) = doc.get_element_by_id("new-game-manual-map-help") {
            help.set_text_content(Some(
                "선택한 플레이어 keeper 순서를 actor slot에 고정할 수 있습니다. 플레이어를 선택한 뒤 '점유기준 추천' 또는 수동 변경을 사용하세요.",
            ));
        }
        if let Some(reset_btn) = doc
            .get_element_by_id("new-game-manual-reset")
            .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
        {
            reset_btn.set_disabled(true);
        }
        if let Some(recommend_btn) = doc
            .get_element_by_id("new-game-manual-recommend")
            .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
        {
            recommend_btn.set_disabled(true);
        }
        set_manual_mapping_order(doc, &[]);
        return;
    }

    let order = normalize_manual_keeper_order(manual_mapping_order(doc), &selected);
    set_manual_mapping_order(doc, &order);
    let slot_actors = current_player_actor_slots_from_actor_admin(doc);
    let keeper_actor_map = keeper_actor_map_from_actor_admin_dom(doc);
    let rows = order
        .iter()
        .enumerate()
        .map(|(idx, keeper)| {
            let options = selected
                .iter()
                .map(|candidate| {
                    let actor_hint = keeper_actor_map
                        .get(candidate)
                        .map(|actor_id| format!(" · 점유 {}", actor_id))
                        .unwrap_or_default();
                    let selected_attr = if candidate == keeper { " selected" } else { "" };
                    format!(
                        r#"<option value="{value}"{selected}>{label}</option>"#,
                        value = html_escape(candidate),
                        selected = selected_attr,
                        label = html_escape(&format!("{}{}", candidate, actor_hint)),
                    )
                })
                .collect::<Vec<_>>()
                .join("");
            let slot_actor = slot_actors.get(idx).cloned().unwrap_or_default();
            let slot_actor_label = if slot_actor.is_empty() {
                "actor 미정".to_string()
            } else {
                format!("actor {}", slot_actor)
            };
            format!(
                concat!(
                    "<div class=\"manual-map-row\">",
                    "<div class=\"manual-map-slot-wrap\">",
                    "<span class=\"manual-map-slot\">P{slot:02}</span>",
                    "<span class=\"manual-map-actor\">{actor_label}</span>",
                    "</div>",
                    "<select class=\"manual-map-select\" data-slot-index=\"{idx}\">{options}</select>",
                    "</div>"
                ),
                slot = idx + 1,
                actor_label = html_escape(&slot_actor_label),
                idx = idx,
                options = options
            )
        })
        .collect::<Vec<_>>()
        .join("");
    table.set_inner_html(&rows);

    if let Some(help) = doc.get_element_by_id("new-game-manual-map-help") {
        let summary = order
            .iter()
            .enumerate()
            .map(|(idx, keeper)| format!("P{:02}→{}", idx + 1, keeper))
            .collect::<Vec<_>>()
            .join(" · ");
        let slot_hint = if slot_actors.is_empty() {
            "actor 슬롯 라벨은 액터 목록 새로고침 후 표시됩니다.".to_string()
        } else {
            format!(
                "현재 actor 슬롯 기준: {}",
                slot_actors
                    .iter()
                    .take(order.len())
                    .enumerate()
                    .map(|(idx, actor_id)| format!("P{:02}={}", idx + 1, actor_id))
                    .collect::<Vec<_>>()
                    .join(" · ")
            )
        };
        help.set_text_content(Some(&format!(
            "수동 매핑 적용 순서: {} · {} · 필요하면 '점유기준 추천' 또는 '선택순으로 리셋'을 사용하세요.",
            summary, slot_hint
        )));
    }
    if let Some(reset_btn) = doc
        .get_element_by_id("new-game-manual-reset")
        .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
    {
        reset_btn.set_disabled(busy);
    }
    if let Some(recommend_btn) = doc
        .get_element_by_id("new-game-manual-recommend")
        .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
    {
        recommend_btn.set_disabled(busy);
    }
    bind_manual_mapping_selects(doc);
}

fn selected_dm_keeper(doc: &web_sys::Document) -> String {
    doc.get_element_by_id("new-game-dm-select")
        .and_then(|el| {
            el.dyn_ref::<web_sys::HtmlSelectElement>()
                .map(|select| select.value())
        })
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn has_selectable_keeper_option(doc: &web_sys::Document, select_id: &str) -> bool {
    let Some(select) = doc
        .get_element_by_id(select_id)
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
    else {
        return false;
    };
    let options = select.options();
    for idx in 0..options.length() {
        let Some(option) = options
            .item(idx)
            .and_then(|el| el.dyn_into::<web_sys::HtmlOptionElement>().ok())
        else {
            continue;
        };
        if !option.value().trim().is_empty() {
            return true;
        }
    }
    false
}

fn read_dashboard_ui_state(doc: &web_sys::Document) -> TrpgUiState {
    doc.get_element_by_id("dashboard")
        .and_then(|dashboard| dashboard.get_attribute("data-trpg-ui-state"))
        .map(|raw| TrpgUiState::from_code(&raw))
        .unwrap_or(TrpgUiState::Lobby)
}

fn ui_state_blocks_new_session_start(state: TrpgUiState) -> bool {
    matches!(
        state,
        TrpgUiState::SessionStarting | TrpgUiState::SessionRunning | TrpgUiState::RoundRunning
    )
}

fn sync_new_game_panel_top_offset(doc: &web_sys::Document) {
    let top_px = doc
        .get_element_by_id("top-bar")
        .and_then(|el| el.dyn_ref::<web_sys::HtmlElement>().map(|bar| bar.offset_height()))
        .map(|height| height.max(44))
        .unwrap_or(44);
    if let Some(panel) = doc
        .get_element_by_id("new-game-panel")
        .and_then(|el| el.dyn_into::<web_sys::HtmlElement>().ok())
    {
        let _ = panel
            .style()
            .set_property("--new-game-panel-top", &format!("{}px", top_px));
    }
}

fn set_new_game_preflight_state(doc: &web_sys::Document, state: &str) {
    if let Some(panel) = doc.get_element_by_id("new-game-panel") {
        let normalized = match state {
            "ok" | "fail" | "pending" => state,
            _ => "pending",
        };
        let _ = panel.set_attribute("data-preflight-state", normalized);
        let _ = panel.set_attribute(
            "data-preflight-ok",
            if normalized == "ok" { "1" } else { "0" },
        );
    }
}

fn set_new_game_flow_stage(doc: &web_sys::Document, stage: NewGameFlowStage, detail: Option<&str>) {
    let Some(panel) = doc.get_element_by_id("new-game-panel") else {
        return;
    };
    let _ = panel.set_attribute("data-flow-stage", stage.code());
    let normalized_detail = detail.unwrap_or("").trim();
    if normalized_detail.is_empty() {
        let _ = panel.remove_attribute("data-flow-detail");
    } else {
        let _ = panel.set_attribute("data-flow-detail", normalized_detail);
    }
}

fn new_game_flow_stage(doc: &web_sys::Document) -> NewGameFlowStage {
    doc.get_element_by_id("new-game-panel")
        .and_then(|panel| panel.get_attribute("data-flow-stage"))
        .map(|raw| NewGameFlowStage::from(raw.as_str()))
        .unwrap_or(NewGameFlowStage::Idle)
}

fn new_game_flow_detail(doc: &web_sys::Document) -> String {
    doc.get_element_by_id("new-game-panel")
        .and_then(|panel| panel.get_attribute("data-flow-detail"))
        .unwrap_or_default()
}

fn set_new_game_progress(doc: &web_sys::Document, stage: NewGameFlowStage, message: &str) {
    set_new_game_flow_stage(doc, stage, Some(message));
    set_new_game_status(doc, message);
}

fn new_game_preflight_state(doc: &web_sys::Document) -> String {
    doc.get_element_by_id("new-game-panel")
        .and_then(|panel| panel.get_attribute("data-preflight-state"))
        .unwrap_or_else(|| "pending".to_string())
}

fn set_new_game_wizard_busy(doc: &web_sys::Document, busy: bool) {
    if let Some(panel) = doc.get_element_by_id("new-game-panel") {
        let _ = panel.set_attribute("data-wizard-busy", if busy { "1" } else { "0" });
    }
    for id in [
        "new-game-quick-start",
        "new-game-preflight-btn",
        "new-game-refresh",
        "new-game-autopick-btn",
        "new-game-manual-recommend",
        "new-game-manual-reset",
    ] {
        if let Some(btn) = doc
            .get_element_by_id(id)
            .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
        {
            btn.set_disabled(busy);
        }
    }
}

fn new_game_wizard_busy(doc: &web_sys::Document) -> bool {
    doc.get_element_by_id("new-game-panel")
        .and_then(|panel| panel.get_attribute("data-wizard-busy"))
        .is_some_and(|flag| flag == "1")
}

fn set_step_state(doc: &web_sys::Document, id: &str, state: &str) {
    let Some(el) = doc.get_element_by_id(id) else {
        return;
    };
    let _ = el.class_list().remove_1("is-active");
    let _ = el.class_list().remove_1("is-done");
    let _ = el.class_list().remove_1("is-error");
    match state {
        "active" => {
            let _ = el.class_list().add_1("is-active");
        }
        "done" => {
            let _ = el.class_list().add_1("is-done");
        }
        "error" => {
            let _ = el.class_list().add_1("is-error");
        }
        _ => {}
    }
}

fn set_inline_hint(doc: &web_sys::Document, id: &str, text: &str, state: &str) {
    let Some(el) = doc.get_element_by_id(id) else {
        return;
    };
    let class_name = match state {
        "ok" => "new-game-inline-hint is-ok",
        "warn" => "new-game-inline-hint is-warn",
        "error" => "new-game-inline-hint is-error",
        _ => "new-game-inline-hint",
    };
    let _ = el.set_attribute("class", class_name);
    el.set_text_content(Some(text));
}

fn summarize_names(names: &[String], max_preview: usize) -> String {
    if names.is_empty() {
        return "-".to_string();
    }
    if names.len() <= max_preview {
        return names.join(", ");
    }
    let preview = names[..max_preview].join(", ");
    format!("{} 외 {}명", preview, names.len() - max_preview)
}

fn wizard_state_badge(label: &str, state: &str) -> String {
    let class = match state {
        "ok" => "is-ok",
        "warn" => "is-warn",
        "error" => "is-error",
        _ => "is-pending",
    };
    format!(
        "<span class=\"new-game-badge {class}\">{label}</span>",
        class = class,
        label = html_escape(label)
    )
}

fn render_new_game_assignment_preview(
    doc: &web_sys::Document,
    preflight_state: &str,
    dm_keeper: &str,
    players: &[String],
    has_conflict: bool,
    ready: bool,
) {
    let Some(el) = doc.get_element_by_id("new-game-assignment") else {
        return;
    };

    let world_preset = doc
        .get_element_by_id("new-game-world-select")
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
        .map(|select| select.value())
        .unwrap_or_default()
        .trim()
        .to_string();
    let dm_preset = doc
        .get_element_by_id("new-game-dm-preset-select")
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
        .map(|select| select.value())
        .unwrap_or_default()
        .trim()
        .to_string();

    let preflight_badge = match preflight_state {
        "ok" => wizard_state_badge("사전 점검 통과", "ok"),
        "fail" => wizard_state_badge("사전 점검 실패", "error"),
        _ => wizard_state_badge("사전 점검 대기", "warn"),
    };
    let ready_badge = if ready {
        wizard_state_badge("세션 시작 가능", "ok")
    } else {
        wizard_state_badge("세션 시작 준비 중", "warn")
    };
    let issue_badge = if has_conflict {
        wizard_state_badge("DM/플레이어 충돌", "error")
    } else if dm_keeper.trim().is_empty() {
        wizard_state_badge("DM 미선택", "warn")
    } else if players.is_empty() {
        wizard_state_badge("플레이어 미선택", "warn")
    } else {
        String::new()
    };
    let issue_note = if has_conflict {
        format!(
            "<div class=\"new-game-assignment-note is-error\">충돌 keeper: {} (DM과 플레이어에서 동시에 선택됨)</div>",
            html_escape(dm_keeper)
        )
    } else {
        String::new()
    };

    let keeper_actor_map = keeper_actor_map_from_actor_admin_dom(doc);

    let dm_line = if dm_keeper.trim().is_empty() {
        "<li><strong>DM:</strong> (미선택)</li>".to_string()
    } else {
        let mapped_actor = keeper_actor_map.get(dm_keeper).cloned().unwrap_or_default();
        let map_label = if mapped_actor.is_empty() {
            "<span class=\"assign-map\">→ actor 미할당</span>".to_string()
        } else {
            format!(
                "<span class=\"assign-map\">→ actor {}</span>",
                html_escape(&mapped_actor)
            )
        };
        format!(
            "<li><strong>DM:</strong> {} {}</li>",
            html_escape(dm_keeper),
            map_label
        )
    };

    let player_lines = if players.is_empty() {
        "<li>플레이어 keeper가 아직 선택되지 않았습니다.</li>".to_string()
    } else {
        players
            .iter()
            .enumerate()
            .map(|(idx, keeper)| {
                if has_conflict && keeper == dm_keeper {
                    format!(
                        "<li>P{:02}: {} <span class=\"assign-conflict\">(DM 중복)</span></li>",
                        idx + 1,
                        html_escape(keeper)
                    )
                } else {
                    let mapped_actor = keeper_actor_map.get(keeper).cloned().unwrap_or_default();
                    let map_label = if mapped_actor.is_empty() {
                        "<span class=\"assign-map\">→ actor 미할당</span>".to_string()
                    } else {
                        format!(
                            "<span class=\"assign-map\">→ actor {}</span>",
                            html_escape(&mapped_actor)
                        )
                    };
                    format!(
                        "<li>P{:02}: {} {}</li>",
                        idx + 1,
                        html_escape(keeper),
                        map_label
                    )
                }
            })
            .collect::<Vec<_>>()
            .join("")
    };

    let html = format!(
        concat!(
            "<div class=\"new-game-assignment-preview\">",
            "<div class=\"new-game-assignment-badges\">{preflight_badge}{ready_badge}{issue_badge}</div>",
            "<div class=\"new-game-assignment-meta\">",
            "<span>world: <code>{world}</code></span>",
            "<span>dm preset: <code>{dm_preset}</code></span>",
            "</div>",
            "<ul class=\"new-game-assignment-list\">",
            "{dm_line}",
            "{player_lines}",
            "</ul>",
            "{issue_note}",
            "<div class=\"new-game-assignment-note\">",
            "참고: 세션 시작 후 actor_id ↔ keeper 매핑이 확정됩니다.",
            "</div>",
            "</div>"
        ),
        preflight_badge = preflight_badge,
        ready_badge = ready_badge,
        issue_badge = issue_badge,
        world = html_escape(if world_preset.is_empty() {
            "(none)"
        } else {
            &world_preset
        }),
        dm_preset = html_escape(if dm_preset.is_empty() {
            "(none)"
        } else {
            &dm_preset
        }),
        dm_line = dm_line,
        player_lines = player_lines,
        issue_note = issue_note,
    );
    el.set_inner_html(&html);
}

fn sync_new_game_wizard_ui(doc: &web_sys::Document) {
    let preflight_state = new_game_preflight_state(doc);
    let flow_stage = new_game_flow_stage(doc);
    let flow_detail = new_game_flow_detail(doc);
    let dm_keeper = selected_dm_keeper(doc);
    let selected_players = selected_player_keepers(doc);
    let players = manual_player_keeper_order_for_display(doc, &selected_players);
    let ui_state = read_dashboard_ui_state(doc);
    let dm_selected = !dm_keeper.is_empty();
    let has_conflict = dm_selected && players.iter().any(|player| player == &dm_keeper);
    let players_ok = !players.is_empty() && !has_conflict;
    let assignment_ok = dm_selected && players_ok;
    let runtime_locked = ui_state_blocks_new_session_start(ui_state);
    let ready = preflight_state == "ok" && assignment_ok && !runtime_locked;
    let busy = new_game_wizard_busy(doc);
    let flow_running = busy
        || matches!(
            flow_stage,
            NewGameFlowStage::Bootstrap
                | NewGameFlowStage::Preflight
                | NewGameFlowStage::ValidatingInput
                | NewGameFlowStage::ResolvingPreset
                | NewGameFlowStage::GeneratingPool
                | NewGameFlowStage::SelectingParty
                | NewGameFlowStage::StartingSession
                | NewGameFlowStage::ClaimingActors
                | NewGameFlowStage::BootingKeepers
                | NewGameFlowStage::Finalizing
        );
    let flow_failed = flow_stage == NewGameFlowStage::Failed;

    sync_manual_mapping_table(doc);

    let step1_state = match preflight_state.as_str() {
        "ok" => "done",
        "fail" => "error",
        _ => "active",
    };
    let step2_state = if has_conflict {
        "error"
    } else if assignment_ok {
        if preflight_state == "ok" {
            "done"
        } else {
            "active"
        }
    } else if preflight_state == "ok" {
        "active"
    } else {
        "pending"
    };
    let step3_state = if flow_failed {
        "error"
    } else if flow_running {
        "active"
    } else if runtime_locked || ready || flow_stage == NewGameFlowStage::Done {
        "active"
    } else {
        "pending"
    };

    set_step_state(doc, "new-game-step-1", step1_state);
    set_step_state(doc, "new-game-step-2", step2_state);
    set_step_state(doc, "new-game-step-3", step3_state);

    let start_gate_reason = if flow_running {
        let mut reason = format!(
            "세션 시작 작업 실행 중입니다. 현재 단계: {}",
            flow_stage.label_ko()
        );
        if !flow_detail.trim().is_empty() {
            reason.push_str(" · ");
            reason.push_str(flow_detail.trim());
        }
        reason
    } else if runtime_locked {
        format!(
            "현재 {} 상태입니다. 진행 중 라운드/세션이 멈춘 뒤 시작하세요.",
            ui_state.label_ko()
        )
    } else if preflight_state != "ok" {
        "1) 사전 점검 버튼을 먼저 실행해 통과 상태(OK)로 만드세요.".to_string()
    } else if !dm_selected {
        "2) 진행자(DM) keeper를 1명 선택하세요.".to_string()
    } else if has_conflict {
        "2) DM keeper와 플레이어 keeper 중복을 해제하세요.".to_string()
    } else if players.is_empty() {
        "2) 플레이어 keeper를 최소 1명 선택하고 필요하면 '점유기준 추천'으로 슬롯 매핑을 정렬하세요.".to_string()
    } else {
        format!(
            "3) 세션 시작 가능: DM {} / 플레이어 {}명",
            dm_keeper,
            players.len()
        )
    };

    if let Some(start_btn) = doc
        .get_element_by_id("new-game-start")
        .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
    {
        start_btn.set_disabled(!ready || flow_running);
        start_btn.set_title(&start_gate_reason);
        start_btn.set_text_content(Some(if flow_running {
            "세션 시작 중..."
        } else {
            "세션 시작"
        }));
    }

    for id in [
        "new-game-quick-start",
        "new-game-preflight-btn",
        "new-game-refresh",
        "new-game-autopick-btn",
        "new-game-manual-recommend",
        "new-game-manual-reset",
    ] {
        if let Some(btn) = doc
            .get_element_by_id(id)
            .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
        {
            btn.set_disabled(flow_running || runtime_locked);
        }
    }

    if let Some(btn) = doc
        .get_element_by_id("new-game-quick-start")
        .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
    {
        btn.set_text_content(Some(if flow_running {
            "빠른 시작 중..."
        } else {
            "빠른 시작"
        }));
    }

    let gate_hint_text = if ready && !flow_running {
        format!(
            "세션 시작 가능: DM {} · 플레이어 {}명 ({})",
            dm_keeper,
            players.len(),
            summarize_names(&players, 3)
        )
    } else {
        format!("시작 대기: {}", start_gate_reason)
    };
    let gate_hint_state = if ready && !flow_running {
        "ok"
    } else if has_conflict || preflight_state == "fail" {
        "error"
    } else {
        "warn"
    };
    set_inline_hint(doc, "new-game-ready-hint", &gate_hint_text, gate_hint_state);

    if let Some(hint) = doc.get_element_by_id("new-game-step-hint") {
        let state_badge = format!("[상태: {}]", ui_state.label_ko());
        let text = if ready {
            format!(
                "{} 3단계 준비 완료: DM {} · 플레이어 {}명({}). 세션 시작 버튼을 누르세요.",
                state_badge,
                dm_keeper,
                players.len(),
                summarize_names(&players, 3)
            )
        } else {
            format!("{} 진행 가이드: {}", state_badge, start_gate_reason)
        };
        hint.set_text_content(Some(&text));
    }

    if let Some(flow_state) = doc.get_element_by_id("new-game-flow-state") {
        let detail = if flow_detail.trim().is_empty() {
            flow_stage.label_ko().to_string()
        } else {
            format!("{} · {}", flow_stage.label_ko(), flow_detail.trim())
        };
        flow_state.set_text_content(Some(&format!("진행 단계: {}", detail)));
        let _ = flow_state.set_attribute(
            "class",
            &format!("new-game-flow-state {}", flow_stage.css_class()),
        );
    }

    let dm_hint = if dm_selected {
        format!("선택된 DM: {}", dm_keeper)
    } else if !has_selectable_keeper_option(doc, "new-game-dm-select") {
        "사용 가능한 keeper가 없습니다. Keeper 새로고침 또는 masc_keeper_list를 확인하세요."
            .to_string()
    } else {
        "DM을 1명 선택하세요. (진행자 keeper)".to_string()
    };
    set_inline_hint(
        doc,
        "new-game-dm-hint",
        &dm_hint,
        if dm_selected {
            "ok"
        } else if !has_selectable_keeper_option(doc, "new-game-dm-select") {
            "error"
        } else {
            "warn"
        },
    );

    let player_hint = if has_conflict {
        format!(
            "플레이어 {}명 선택됨 · DM({})과 중복됨 · 중복 keeper 선택을 해제하세요.",
            players.len(),
            dm_keeper
        )
    } else if players.is_empty() {
        "플레이어 0명 선택됨 · Ctrl/Cmd+클릭으로 1명 이상 선택하세요.".to_string()
    } else {
        format!(
            "플레이어 {}명 선택됨 · {}",
            players.len(),
            summarize_names(&players, 4)
        )
    };
    set_inline_hint(
        doc,
        "new-game-player-hint",
        &player_hint,
        if has_conflict {
            "error"
        } else if players.is_empty() {
            "warn"
        } else {
            "ok"
        },
    );

    render_new_game_assignment_preview(
        doc,
        &preflight_state,
        &dm_keeper,
        &players,
        has_conflict,
        ready && !flow_running,
    );
}

fn ensure_new_game_ready(doc: &web_sys::Document) -> Result<(), String> {
    let flow_stage = new_game_flow_stage(doc);
    if matches!(
        flow_stage,
        NewGameFlowStage::Bootstrap
            | NewGameFlowStage::Preflight
            | NewGameFlowStage::ValidatingInput
            | NewGameFlowStage::ResolvingPreset
            | NewGameFlowStage::GeneratingPool
            | NewGameFlowStage::SelectingParty
            | NewGameFlowStage::StartingSession
            | NewGameFlowStage::ClaimingActors
            | NewGameFlowStage::BootingKeepers
            | NewGameFlowStage::Finalizing
    ) {
        return Err(format!(
            "세션 시작 작업이 이미 진행 중입니다. 현재 단계: {}",
            flow_stage.label_ko()
        ));
    }
    if new_game_preflight_state(doc) != "ok" {
        return Err("사전 점검이 완료되지 않았습니다. 1) 사전 점검을 먼저 실행하세요.".to_string());
    }
    if !has_selectable_keeper_option(doc, "new-game-dm-select")
        || !has_selectable_keeper_option(doc, "new-game-player-select")
    {
        return Err(
            "사용 가능한 keeper가 없습니다. Keeper를 먼저 실행한 뒤 `Keeper 새로고침`을 눌러주세요."
                .to_string(),
        );
    }
    let dm_keeper = selected_dm_keeper(doc);
    if dm_keeper.is_empty() {
        return Err("DM keeper를 선택하세요.".to_string());
    }
    let players = selected_player_keepers(doc);
    if players.is_empty() {
        return Err("플레이어 keeper를 최소 1명 선택하세요.".to_string());
    }
    let manual_order = manual_player_keeper_order_for_assignment(doc, &players)?;
    if manual_order.is_empty() {
        return Err(
            "수동 매핑 테이블이 비어 있습니다. 플레이어 keeper를 다시 선택하세요.".to_string(),
        );
    }
    if players.iter().any(|player| player == &dm_keeper) {
        return Err("DM keeper와 플레이어 keeper가 중복되었습니다.".to_string());
    }
    Ok(())
}

fn update_new_game_player_hint(doc: &web_sys::Document) {
    let Some(hint) = doc.get_element_by_id("new-game-player-hint") else {
        return;
    };
    let players = selected_player_keepers(doc);
    let dm_keeper = selected_dm_keeper(doc);
    let conflict = !dm_keeper.is_empty() && players.iter().any(|name| name == &dm_keeper);
    let message = if conflict {
        format!(
            "플레이어 {}명 선택됨 · DM({})과 중복됨 · 중복 keeper 선택을 해제하세요.",
            players.len(),
            dm_keeper
        )
    } else if players.is_empty() {
        "플레이어 0명 선택됨 · Ctrl/Cmd+클릭으로 1명 이상 선택하세요.".to_string()
    } else {
        format!(
            "플레이어 {}명 선택됨 · {}",
            players.len(),
            summarize_names(&players, 4)
        )
    };
    let state = if conflict {
        "error"
    } else if players.is_empty() {
        "warn"
    } else {
        "ok"
    };
    let class_name = match state {
        "ok" => "new-game-inline-hint is-ok",
        "warn" => "new-game-inline-hint is-warn",
        "error" => "new-game-inline-hint is-error",
        _ => "new-game-inline-hint",
    };
    let _ = hint.set_attribute("class", class_name);
    hint.set_text_content(Some(&message));

    if let Some(dm_hint) = doc.get_element_by_id("new-game-dm-hint") {
        if dm_keeper.is_empty() && !has_selectable_keeper_option(doc, "new-game-dm-select") {
            let _ = dm_hint.set_attribute("class", "new-game-inline-hint is-error");
            dm_hint.set_text_content(Some(
                "사용 가능한 keeper가 없습니다. Keeper 새로고침 또는 masc_keeper_list를 확인하세요.",
            ));
        } else if dm_keeper.is_empty() {
            let _ = dm_hint.set_attribute("class", "new-game-inline-hint is-warn");
            dm_hint.set_text_content(Some("DM을 1명 선택하세요. (진행자 keeper)"));
        } else {
            let _ = dm_hint.set_attribute("class", "new-game-inline-hint is-ok");
            dm_hint.set_text_content(Some(&format!("선택된 DM: {}", dm_keeper)));
        }
    }
    sync_new_game_wizard_ui(doc);
}

fn auto_select_player_keepers(doc: &web_sys::Document, target_count: usize) -> usize {
    let Some(select) = doc
        .get_element_by_id("new-game-player-select")
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
    else {
        return 0;
    };
    let dm_keeper = doc
        .get_element_by_id("new-game-dm-select")
        .and_then(|el| {
            el.dyn_ref::<web_sys::HtmlSelectElement>()
                .map(|s| s.value())
        })
        .unwrap_or_default()
        .trim()
        .to_string();

    let options = select.options();
    let mut selected = 0_usize;
    for idx in 0..options.length() {
        let Some(option) = options
            .item(idx)
            .and_then(|el| el.dyn_into::<web_sys::HtmlOptionElement>().ok())
        else {
            continue;
        };
        let value = option.value().trim().to_string();
        if value.is_empty() || (!dm_keeper.is_empty() && value == dm_keeper) {
            option.set_selected(false);
            continue;
        }
        if selected < target_count {
            option.set_selected(true);
            selected += 1;
        } else {
            option.set_selected(false);
        }
    }
    update_new_game_player_hint(doc);
    selected
}

fn bind_new_game_selection_watchers(doc: &web_sys::Document) {
    let Some(player_select) = doc.get_element_by_id("new-game-player-select") else {
        return;
    };
    if player_select.get_attribute("data-hint-bound").as_deref() == Some("1") {
        update_new_game_player_hint(doc);
        return;
    }
    let _ = player_select.set_attribute("data-hint-bound", "1");

    if let Some(dm_select) = doc.get_element_by_id("new-game-dm-select") {
        let dm_cb = Closure::wrap(Box::new(move |_event: web_sys::Event| {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let selected = selected_player_keepers(&doc).len().max(1);
            let _ = auto_select_player_keepers(&doc, selected);
            update_new_game_player_hint(&doc);
        }) as Box<dyn FnMut(_)>);
        let _ = dm_select.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("change", dm_cb.as_ref().unchecked_ref())
        });
        dm_cb.forget();
    }

    let player_cb = Closure::wrap(Box::new(move |_event: web_sys::Event| {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        update_new_game_player_hint(&doc);
    }) as Box<dyn FnMut(_)>);
    let _ = player_select
        .dyn_ref::<web_sys::EventTarget>()
        .map(|target| {
            target.add_event_listener_with_callback("change", player_cb.as_ref().unchecked_ref())
        });
    player_cb.forget();

    update_new_game_player_hint(doc);
}

fn available_player_keepers(doc: &web_sys::Document) -> Vec<String> {
    let Ok(nodes) = doc.query_selector_all("#new-game-player-select option") else {
        return Vec::new();
    };
    let mut keepers = Vec::new();
    for i in 0..nodes.length() {
        let Some(node) = nodes.item(i) else { continue };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };
        let Some(value) = el.get_attribute("value") else {
            continue;
        };
        let value = value.trim();
        if value.is_empty() {
            continue;
        }
        keepers.push(value.to_string());
    }
    unique_non_empty(keepers)
}

fn keeper_actor_map_from_actor_admin_dom(doc: &web_sys::Document) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let Ok(nodes) = doc.query_selector_all("#actor-admin-list .actor-admin-row") else {
        return map;
    };
    for idx in 0..nodes.length() {
        let Some(node) = nodes.item(idx) else {
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
        let keeper = el
            .get_attribute("data-keeper")
            .unwrap_or_default()
            .trim()
            .to_string();
        if actor_id.is_empty() || keeper.is_empty() {
            continue;
        }
        map.insert(keeper, actor_id);
    }
    map
}

fn apply_player_keeper_selection(doc: &web_sys::Document, selected: &[String]) {
    let selected = unique_non_empty(selected.to_vec());
    if let Ok(nodes) = doc.query_selector_all("#new-game-player-select option") {
        for i in 0..nodes.length() {
            let Some(node) = nodes.item(i) else { continue };
            let Some(el) = node.dyn_ref::<web_sys::Element>() else {
                continue;
            };
            let value = el
                .get_attribute("value")
                .unwrap_or_default()
                .trim()
                .to_string();
            let on = !value.is_empty() && selected.iter().any(|picked| picked == &value);
            if on {
                let _ = el.set_attribute("selected", "selected");
            } else {
                let _ = el.remove_attribute("selected");
            }
        }
    }
}

fn extract_keeper_name_from_value(row: &Value) -> Option<String> {
    row.as_str()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_string)
        .or_else(|| {
            row.get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(str::to_string)
        })
        .or_else(|| {
            row.get("keeper")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(str::to_string)
        })
}

// ─── Keeper Selectors ───────────────────────────────────────────

async fn refresh_keeper_selectors(doc: &web_sys::Document) -> Result<Vec<String>, String> {
    let payload = match mcp_tool_call(
        "masc_keeper_list",
        json!({ "limit": 200, "detailed": true }),
    )
    .await
    {
        Ok(v) => v,
        Err(primary_err) => {
            match mcp_tool_call("masc_keeper_list", json!({ "limit": 200 })).await {
                Ok(v) => v,
                Err(fallback_err) => {
                    log::warn!(
                        "refresh_keeper_selectors failed: primary={} fallback={}",
                        primary_err,
                        fallback_err
                    );
                    if let Some(dm_select) = doc.get_element_by_id("new-game-dm-select") {
                        dm_select.set_inner_html(
                        r#"<option value="">(keeper 조회 실패: masc_keeper_list 확인)</option>"#,
                    );
                    }
                    if let Some(player_select) = doc.get_element_by_id("new-game-player-select") {
                        player_select.set_inner_html(
                        r#"<option value="" disabled>(keeper 조회 실패: masc_keeper_list 확인)</option>"#,
                    );
                    }
                    update_new_game_player_hint(doc);
                    return Ok(Vec::new());
                }
            }
        }
    };
    web_sys::console::log_1(
        &format!(
            "[refresh_keeper_selectors] payload keys={:?}",
            payload.as_object().map(|m| m.keys().collect::<Vec<_>>())
        )
        .into(),
    );
    let mut keepers = payload
        .get("keepers")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(extract_keeper_name_from_value)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    keepers = unique_non_empty(keepers);
    if keepers.is_empty() {
        let mut fallback = Vec::new();
        let dm_from_ui = doc
            .get_element_by_id("new-game-dm-select")
            .and_then(|el| {
                el.dyn_ref::<web_sys::HtmlSelectElement>()
                    .map(|s| s.value())
            })
            .unwrap_or_default()
            .trim()
            .to_string();
        if !dm_from_ui.is_empty() {
            fallback.push(dm_from_ui);
        }
        let current_room = read_new_game_room_id(doc);
        let claimed_room = doc
            .get_element_by_id("claimed-room-id")
            .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
            .unwrap_or_default()
            .trim()
            .to_string();
        if claimed_room == current_room {
            if let Some(claimed) = doc.get_element_by_id("claimed-keeper") {
                if let Some(input) = claimed.dyn_ref::<web_sys::HtmlInputElement>() {
                    let value = input.value().trim().to_string();
                    if !value.is_empty() {
                        fallback.push(value);
                    }
                }
                let text = claimed
                    .text_content()
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                if !text.is_empty() {
                    fallback.push(text);
                }
            }
        }
        keepers = unique_non_empty(fallback);
    }
    if keepers.is_empty() {
        if let Some(dm_select) = doc.get_element_by_id("new-game-dm-select") {
            dm_select.set_inner_html(r#"<option value="">(사용 가능한 keeper 없음)</option>"#);
        }
        if let Some(player_select) = doc.get_element_by_id("new-game-player-select") {
            player_select
                .set_inner_html(r#"<option value="" disabled>(사용 가능한 keeper 없음)</option>"#);
        }
        update_new_game_player_hint(doc);
        return Ok(Vec::new());
    }

    let keeper_actor_map = match fetch_room_state_payload(&read_new_game_room_id(doc)).await {
        Ok(state_payload) => parse_keeper_actor_map(&state_payload),
        Err(_) => HashMap::new(),
    };

    let option_label = |name: &str| -> String {
        let suffix = keeper_actor_map
            .get(name)
            .map(|actor_id| format!(" · 점유 {}", actor_id))
            .unwrap_or_default();
        format!("{}{}", name, suffix)
    };

    let previous_dm = doc
        .get_element_by_id("new-game-dm-select")
        .and_then(|el| {
            el.dyn_ref::<web_sys::HtmlSelectElement>()
                .map(|s| s.value())
        })
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty());
    let previous_players = selected_player_keepers(doc);
    let dm_default = previous_dm
        .filter(|prev| keepers.iter().any(|name| name == prev))
        .or_else(|| keepers.iter().find(|name| name.starts_with("dm")).cloned())
        .unwrap_or_else(|| keepers[0].clone());

    if let Some(dm_select) = doc.get_element_by_id("new-game-dm-select") {
        let html = keepers
            .iter()
            .map(|name| {
                let safe = html_escape(name);
                let label = html_escape(&option_label(name));
                format!(r#"<option value="{}">{}</option>"#, safe, label)
            })
            .collect::<Vec<_>>()
            .join("");
        dm_select.set_inner_html(&html);
        if let Some(select) = dm_select.dyn_ref::<web_sys::HtmlSelectElement>() {
            select.set_value(&dm_default);
        }
    }

    if let Some(player_select) = doc.get_element_by_id("new-game-player-select") {
        let preserve_existing_selection = !previous_players.is_empty();
        let mut default_selected = 0_usize;
        let mut html = String::new();
        for name in keepers.iter().filter(|name| **name != dm_default) {
            let safe = html_escape(name);
            let label = html_escape(&option_label(name));
            let selected_attr = if preserve_existing_selection
                && previous_players.iter().any(|picked| picked == name)
            {
                " selected"
            } else if !preserve_existing_selection && default_selected < 4 {
                default_selected += 1;
                " selected"
            } else {
                ""
            };
            html.push_str(&format!(
                r#"<option value="{value}"{selected}>{label}</option>"#,
                value = safe,
                label = label,
                selected = selected_attr
            ));
        }
        player_select.set_inner_html(&html);
    }

    update_new_game_player_hint(doc);
    Ok(keepers)
}

// ─── Actor Admin CRUD ───────────────────────────────────────────

pub(super) fn actor_admin_room_id() -> String {
    crate::config::current_room_id()
}

pub(super) fn actor_admin_set_status(doc: &web_sys::Document, message: &str, css_class: &str) {
    if let Some(el) = doc.get_element_by_id("actor-admin-status") {
        el.set_inner_html(&html_escape(message));
        let class_name = if css_class.trim().is_empty() {
            "new-game-status".to_string()
        } else {
            format!("new-game-status {}", css_class)
        };
        let _ = el.set_attribute("class", &class_name);
    }
}

fn actor_admin_set_busy(doc: &web_sys::Document, busy: bool) {
    for id in [
        "actor-admin-refresh",
        "actor-admin-spawn",
        "actor-admin-update",
        "actor-admin-release",
        "actor-admin-delete",
    ] {
        if let Some(btn) = doc
            .get_element_by_id(id)
            .and_then(|el| el.dyn_into::<web_sys::HtmlButtonElement>().ok())
        {
            btn.set_disabled(busy);
        }
    }
}

fn actor_admin_input_value(doc: &web_sys::Document, id: &str) -> String {
    doc.get_element_by_id(id)
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
        .map(|input| input.value().trim().to_string())
        .unwrap_or_default()
}

fn actor_admin_select_value(doc: &web_sys::Document, id: &str) -> String {
    doc.get_element_by_id(id)
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
        .map(|select| select.value().trim().to_string())
        .unwrap_or_default()
}

fn actor_admin_input_i64(doc: &web_sys::Document, id: &str) -> Option<i64> {
    let raw = actor_admin_input_value(doc, id);
    if raw.is_empty() {
        None
    } else {
        raw.parse::<i64>().ok()
    }
}

async fn fetch_room_state_payload(room_id: &str) -> Result<Value, String> {
    let url = crate::config::build_masc_url(&format!("api/v1/trpg/state?room_id={}", room_id));
    let opts = web_sys::RequestInit::new();
    opts.set_method("GET");
    opts.set_mode(web_sys::RequestMode::Cors);

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)
        .map_err(|e| format!("request 생성 실패: {:?}", e))?;
    request
        .headers()
        .set("Accept", "application/json")
        .map_err(|e| format!("헤더 설정 실패: {:?}", e))?;

    let window = web_sys::window().ok_or_else(|| "window unavailable".to_string())?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request))
        .await
        .map_err(|e| format!("fetch 실패: {:?}", e))?;
    let resp: web_sys::Response = resp_value
        .dyn_into()
        .map_err(|_| "response 변환 실패".to_string())?;
    if !resp.ok() {
        return Err(format!("HTTP {}", resp.status()));
    }

    let body_js = JsFuture::from(
        resp.text()
            .map_err(|e| format!("response.text() 실패: {:?}", e))?,
    )
    .await
    .map_err(|e| format!("본문 읽기 실패: {:?}", e))?;
    let body = body_js.as_string().unwrap_or_default();
    if body.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str::<Value>(&body).map_err(|e| format!("state JSON 파싱 실패: {}", e))
}

fn summarize_preflight_items(items: &[String], limit: usize) -> String {
    if items.is_empty() {
        return "-".to_string();
    }
    let mut rows = items
        .iter()
        .take(limit)
        .map(|item| item.trim().to_string())
        .filter(|item| !item.is_empty())
        .collect::<Vec<_>>();
    if items.len() > limit {
        rows.push(format!("외 {}건", items.len() - limit));
    }
    rows.join(" | ")
}

fn parse_actor_admin_rows(state_root: &Value) -> Vec<ActorAdminRow> {
    let state = state_root.get("state").unwrap_or(state_root);
    let actor_control = parse_actor_control_map(state_root);
    let control_keeper =
        |actor_id: &str| -> String { actor_control.get(actor_id).cloned().unwrap_or_default() };

    let mut rows = Vec::new();
    if let Some(characters) = state.get("characters").and_then(Value::as_array) {
        for ch in characters {
            let actor_id = ch
                .get("id")
                .or_else(|| ch.get("actor_id"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string();
            if actor_id.is_empty() {
                continue;
            }
            let name = ch
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or(&actor_id)
                .trim()
                .to_string();
            let role = ch
                .get("role")
                .or_else(|| ch.get("class"))
                .or_else(|| ch.get("archetype"))
                .and_then(Value::as_str)
                .unwrap_or("player")
                .trim()
                .to_string();
            let hp = ch.get("hp").and_then(Value::as_i64).unwrap_or(0) as i32;
            let max_hp = ch.get("max_hp").and_then(Value::as_i64).unwrap_or(0) as i32;
            let keeper = ch
                .get("keeper")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string();
            let final_keeper = if keeper.is_empty() {
                control_keeper(&actor_id)
            } else {
                keeper
            };
            rows.push(ActorAdminRow {
                actor_id: actor_id.clone(),
                name,
                role,
                hp,
                max_hp,
                keeper: final_keeper.clone(),
                claimed: !final_keeper.trim().is_empty(),
            });
        }
    } else if let Some(party) = state.get("party").and_then(Value::as_object) {
        for (actor_id, row) in party {
            let actor_id = actor_id.trim();
            if actor_id.is_empty() {
                continue;
            }
            let name = row
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or(actor_id)
                .trim()
                .to_string();
            let role = row
                .get("role")
                .or_else(|| row.get("class"))
                .or_else(|| row.get("archetype"))
                .and_then(Value::as_str)
                .unwrap_or("player")
                .trim()
                .to_string();
            let hp = row.get("hp").and_then(Value::as_i64).unwrap_or(0) as i32;
            let max_hp = row.get("max_hp").and_then(Value::as_i64).unwrap_or(0) as i32;
            let keeper = control_keeper(actor_id);
            rows.push(ActorAdminRow {
                actor_id: actor_id.to_string(),
                name,
                role,
                hp,
                max_hp,
                keeper: keeper.clone(),
                claimed: !keeper.trim().is_empty(),
            });
        }
    }
    rows.sort_by(|a, b| a.actor_id.cmp(&b.actor_id));
    rows
}

fn render_actor_admin_rows(doc: &web_sys::Document, rows: &[ActorAdminRow]) {
    let Some(list) = doc.get_element_by_id("actor-admin-list") else {
        return;
    };
    if rows.is_empty() {
        list.set_inner_html("<div class=\"room-chip-empty\">액터가 없습니다.</div>");
        return;
    }
    let html = rows
        .iter()
        .map(|row| {
            let claim_badge = if row.claimed {
                format!(
                    "<span class=\"actor-claim-badge is-claimed\">점유 {}</span>",
                    html_escape(&row.keeper)
                )
            } else {
                "<span class=\"actor-claim-badge is-free\">비점유</span>".to_string()
            };
            format!(
                concat!(
                    "<button class=\"actor-admin-row\" ",
                    "data-actor-id=\"{id}\" data-name=\"{name}\" data-role=\"{role}\" ",
                    "data-keeper=\"{keeper}\" data-hp=\"{hp}\" data-max-hp=\"{max_hp}\" ",
                    "data-claimed=\"{claimed}\">",
                    "{id} · {role} · HP {hp}/{max_hp} {claim_badge}",
                    "</button>"
                ),
                id = html_escape(&row.actor_id),
                name = html_escape(&row.name),
                role = html_escape(&row.role),
                keeper = html_escape(&row.keeper),
                hp = row.hp,
                max_hp = row.max_hp,
                claimed = if row.claimed { "1" } else { "0" },
                claim_badge = claim_badge,
            )
        })
        .collect::<Vec<_>>()
        .join("");
    list.set_inner_html(&html);
}

fn bind_actor_admin_row_clicks(doc: &web_sys::Document) {
    let Ok(nodes) = doc.query_selector_all("#actor-admin-list .actor-admin-row") else {
        return;
    };
    for i in 0..nodes.length() {
        let Some(node) = nodes.item(i) else { continue };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };
        if el.get_attribute("data-bound").as_deref() == Some("1") {
            continue;
        }
        let _ = el.set_attribute("data-bound", "1");
        let id = el.get_attribute("data-actor-id").unwrap_or_default();
        let name = el.get_attribute("data-name").unwrap_or_default();
        let role = el.get_attribute("data-role").unwrap_or_default();
        let keeper = el.get_attribute("data-keeper").unwrap_or_default();
        let hp = el.get_attribute("data-hp").unwrap_or_default();
        let max_hp = el.get_attribute("data-max-hp").unwrap_or_default();
        let cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };

            if let Some(input) = doc
                .get_element_by_id("actor-admin-id")
                .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
            {
                input.set_value(&id);
            }
            if let Some(input) = doc
                .get_element_by_id("actor-admin-name")
                .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
            {
                input.set_value(&name);
            }
            if let Some(select) = doc
                .get_element_by_id("actor-admin-role")
                .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
            {
                if !role.trim().is_empty() {
                    select.set_value(&role);
                }
            }
            if let Some(input) = doc
                .get_element_by_id("actor-admin-keeper")
                .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
            {
                input.set_value(&keeper);
            }
            if let Some(input) = doc
                .get_element_by_id("actor-admin-hp")
                .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
            {
                input.set_value(&hp);
            }
            if let Some(input) = doc
                .get_element_by_id("actor-admin-max-hp")
                .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
            {
                input.set_value(&max_hp);
            }
        }) as Box<dyn FnMut()>);
        let _ = el.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
        });
        cb.forget();
    }
}

pub(super) async fn refresh_actor_admin_list(
    doc: &web_sys::Document,
) -> Result<Vec<ActorAdminRow>, String> {
    let room_id = actor_admin_room_id();
    let payload = fetch_room_state_payload(&room_id).await?;
    let rows = parse_actor_admin_rows(&payload);
    render_actor_admin_rows(doc, &rows);
    bind_actor_admin_row_clicks(doc);
    Ok(rows)
}

async fn refresh_new_game_bootstrap(doc: &web_sys::Document) -> Result<NewGameBootstrap, String> {
    let keepers = refresh_keeper_selectors(doc).await?;
    let (world_presets, dm_presets) = refresh_preset_selectors(doc).await?;
    if let Err(err) = refresh_actor_admin_list(doc).await {
        actor_admin_set_status(doc, &format!("액터 목록 로드 실패: {}", err), "status-warn");
    }
    Ok(NewGameBootstrap {
        keepers,
        world_presets,
        dm_presets,
    })
}

async fn run_new_game_preflight(doc: &web_sys::Document) -> Result<(), String> {
    use super::transport_classify::{is_html_body, PreflightRow};

    let mut rows: Vec<PreflightRow> = Vec::new();

    // ── Step 0: Server connectivity (early-exit on failure) ──
    let health_url = crate::config::build_masc_url("health");
    let server_row = match crate::mode::mcp_rpc::http_get_text(&health_url).await {
        Ok((status, _body)) if (200..300).contains(&status) => {
            PreflightRow { ok: true, label: "서버 연결".to_string(), detail: "MASC 서버 응답 정상".to_string(), hint: None }
        }
        Ok((status, body)) => {
            let hint = if is_html_body(&body) {
                "프록시/CDN이 에러 페이지를 반환했습니다. 서버 프로세스를 확인하세요.".to_string()
            } else {
                "서버가 실행 중인지, URL이 올바른지 확인하세요.".to_string()
            };
            PreflightRow { ok: false, label: "서버 연결".to_string(), detail: format!("HTTP {} 응답", status), hint: Some(hint) }
        }
        Err(e) => {
            let base = crate::config::masc_mcp_base_url();
            let hint = if base.is_empty() {
                "MASC 서버가 실행 중인지 확인하세요.".to_string()
            } else {
                format!("MASC 서버가 실행 중인지 확인하세요. ({})", base)
            };
            PreflightRow { ok: false, label: "서버 연결".to_string(), detail: format!("연결 실패: {}", e), hint: Some(hint) }
        }
    };
    let server_ok = server_row.ok;
    rows.push(server_row);

    // If server is unreachable, skip all dependent checks (cockpit syndrome prevention).
    if !server_ok {
        set_new_game_preflight_rows(doc, &rows);
        set_new_game_preflight_state(doc, "fail");
        set_new_game_flow_stage(
            doc,
            NewGameFlowStage::Failed,
            Some("MASC 서버에 연결할 수 없습니다"),
        );
        sync_new_game_wizard_ui(doc);
        return Err("MASC 서버 연결 실패".to_string());
    }

    let preset_row = match fetch_preset_catalog().await {
        Ok(catalog) => {
            let world = collect_world_preset_options(&catalog);
            let dm = collect_dm_preset_options(&catalog);
            let ok = !world.is_empty() && !dm.is_empty();
            let detail = if ok {
                format!("월드 {}개 · DM {}개", world.len(), dm.len())
            } else {
                format!(
                    "프리셋 부족 (월드 {} / DM {}) {}",
                    world.len(),
                    dm.len(),
                    preset_catalog_keys_preview_from_value(&catalog)
                )
            };
            PreflightRow { ok, label: "프리셋".to_string(), detail, hint: None }
        }
        Err(e) => PreflightRow { ok: false, label: "프리셋".to_string(), detail: format!("조회 실패: {}", e), hint: None },
    };
    rows.push(preset_row);

    let (available_keepers, keeper_pool_row) =
        match mcp_tool_call("masc_keeper_list", json!({ "limit": 200 })).await {
            Ok(payload) => {
                let keepers = payload
                    .get("keepers")
                    .and_then(Value::as_array)
                    .map(|rows| {
                        rows.iter()
                            .filter_map(extract_keeper_name_from_value)
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                let keepers = unique_non_empty(keepers);
                let count = keepers.len();
                if count > 0 {
                    (
                        keepers,
                        PreflightRow { ok: true, label: "키퍼 풀".to_string(), detail: format!("{}명 사용 가능", count), hint: None },
                    )
                } else {
                    (
                        Vec::new(),
                        PreflightRow { ok: false, label: "키퍼 풀".to_string(), detail: "사용 가능한 keeper가 없습니다".to_string(), hint: None },
                    )
                }
            }
            Err(e) => (
                Vec::new(),
                PreflightRow { ok: false, label: "키퍼 풀".to_string(), detail: format!("조회 실패: {}", e), hint: None },
            ),
        };
    rows.push(keeper_pool_row);

    let mut selected_keepers = Vec::new();
    let dm_keeper = selected_dm_keeper(doc);
    if !dm_keeper.trim().is_empty() {
        selected_keepers.push(dm_keeper);
    }
    selected_keepers.extend(selected_player_keepers(doc));
    selected_keepers = unique_non_empty(selected_keepers);

    let selected_keeper_row = if selected_keepers.is_empty() {
        (
            false,
            "선택 키퍼".to_string(),
            "DM/플레이어 keeper를 선택하세요.".to_string(),
            None,
        )
    } else {
        let mut blockers = Vec::new();
        let mut warnings = Vec::new();
        let mut notes = Vec::new();
        let mut boot_required = Vec::new();
        let mut ready_count = 0usize;

        for keeper_name in &selected_keepers {
            if !available_keepers.is_empty()
                && !available_keepers.iter().any(|name| name == keeper_name)
            {
                blockers.push(format!("{}: keeper pool 없음", keeper_name));
                continue;
            }

            let status_payload = match mcp_tool_call(
                "masc_keeper_status",
                json!({
                    "name": keeper_name,
                    "fast": true,
                    "include_context": false,
                    "include_metrics_overview": false,
                    "include_memory_bank": false,
                    "include_history_tail": false,
                    "include_compaction_history": false
                }),
            )
            .await
            {
                Ok(payload) => payload,
                Err(err) => {
                    warnings.push(format!("{}: status 조회 실패 ({})", keeper_name, err));
                    boot_required.push(format!("{}: 상태 미확인", keeper_name));
                    continue;
                }
            };

            let agent = status_payload.get("agent").unwrap_or(&Value::Null);
            let agent_exists = agent
                .get("exists")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let agent_status = agent
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .trim()
                .to_ascii_lowercase();
            let is_zombie = agent
                .get("is_zombie")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let keepalive_running = status_payload
                .get("keepalive_running")
                .and_then(Value::as_bool)
                .unwrap_or(false);

            if !agent_exists {
                boot_required.push(format!("{}: agent 없음", keeper_name));
                continue;
            }
            if is_zombie {
                boot_required.push(format!("{}: zombie", keeper_name));
                continue;
            }
            if !matches!(agent_status.as_str(), "active" | "busy" | "listening") {
                boot_required.push(format!("{}: status={}", keeper_name, agent_status));
                continue;
            }

            ready_count += 1;
            if !keepalive_running {
                notes.push(format!("{}: keepalive off", keeper_name));
            }
        }

        if blockers.is_empty() {
            let mut detail_parts = vec![format!("선택 {}명 확인", selected_keepers.len())];
            detail_parts.push(format!("응답 가능 {}", ready_count));
            if !boot_required.is_empty() {
                detail_parts.push(format!(
                    "부팅 필요 {}",
                    summarize_preflight_items(&boot_required, 3)
                ));
            }
            if !warnings.is_empty() {
                detail_parts.push(format!(
                    "상태 경고 {}",
                    summarize_preflight_items(&warnings, 2)
                ));
            }
            if !notes.is_empty() {
                detail_parts.push(format!(
                    "주의 {}",
                    summarize_preflight_items(&notes, 3)
                ));
            }
            let detail = detail_parts.join(" · ");
            (true, "선택 키퍼".to_string(), detail, None)
        } else {
            (
                false,
                "선택 키퍼".to_string(),
                format!(
                    "준비 실패 {} / {} · {}",
                    blockers.len(),
                    selected_keepers.len(),
                    summarize_preflight_items(&blockers, 3)
                ),
                None,
            )
        }
    };
    rows.push(selected_keeper_row);

    let room_id = read_new_game_room_id(doc);
    let room_state = fetch_room_state_payload(&room_id).await;
    let occupancy_row = match &room_state {
        Ok(payload) => {
            let keeper_actor_map = parse_keeper_actor_map(payload);
            let conflicts = selected_keepers
                .iter()
                .filter_map(|keeper| {
                    keeper_actor_map
                        .get(keeper)
                        .map(|actor_id| format!("{}→{}", keeper, actor_id))
                })
                .collect::<Vec<_>>();
            if conflicts.is_empty() {
                (
                    true,
                    "점유 충돌".to_string(),
                    format!("선택 keeper {}명 모두 비점유", selected_keepers.len()),
                    None,
                )
            } else {
                (
                    false,
                    "점유 충돌".to_string(),
                    format!("이미 점유 중: {}", summarize_preflight_items(&conflicts, 3)),
                    None,
                )
            }
        }
        Err(_) => (
            true,
            "점유 충돌".to_string(),
            "신규 room으로 판단되어 충돌 검사를 건너뜁니다.".to_string(),
            None,
        ),
    };
    rows.push(occupancy_row);

    let room_row = match room_state {
        Ok(payload) => {
            let root = payload.get("state").unwrap_or(&payload);
            let status = root
                .get("status")
                .and_then(Value::as_str)
                .or_else(|| payload.get("status").and_then(Value::as_str))
                .unwrap_or("unknown")
                .trim()
                .to_string();
            (
                true,
                "룸 상태".to_string(),
                format!("room {} · {}", room_id, status),
                None,
            )
        }
        Err(_) => (
            true,
            "룸 상태".to_string(),
            format!("room {} · 신규 room (아직 초기화 전)", room_id),
            None,
        ),
    };
    rows.push(room_row);

    set_new_game_preflight_rows(doc, &rows);
    let all_ok = rows.iter().all(|(ok, _, _, _)| *ok);
    set_new_game_preflight_state(doc, if all_ok { "ok" } else { "fail" });
    if all_ok {
        set_new_game_flow_stage(doc, NewGameFlowStage::Idle, Some("사전 점검 통과"));
    } else {
        set_new_game_flow_stage(
            doc,
            NewGameFlowStage::Failed,
            Some("사전 점검 실패 항목 존재"),
        );
    }
    sync_new_game_wizard_ui(doc);
    if all_ok {
        Ok(())
    } else {
        Err("사전 점검 실패 항목이 있습니다.".to_string())
    }
}

async fn actor_admin_spawn(doc: &web_sys::Document) -> Result<String, String> {
    let room_id = actor_admin_room_id();
    let actor_id = actor_admin_input_value(doc, "actor-admin-id");
    if actor_id.is_empty() {
        return Err("Actor ID를 입력하세요.".to_string());
    }
    let role = {
        let role_raw = actor_admin_select_value(doc, "actor-admin-role");
        if role_raw.is_empty() {
            "player".to_string()
        } else {
            role_raw
        }
    };
    let name = actor_admin_input_value(doc, "actor-admin-name");
    let keeper = actor_admin_input_value(doc, "actor-admin-keeper");
    let max_hp = actor_admin_input_i64(doc, "actor-admin-max-hp").unwrap_or(20);
    let hp = actor_admin_input_i64(doc, "actor-admin-hp").unwrap_or(max_hp);

    let mut args = json!({
        "room_id": room_id,
        "actor_id": actor_id,
        "role": role,
        "hp": hp.max(0),
        "max_hp": max_hp.max(1),
        "alive": hp > 0
    });
    if !name.is_empty() {
        args["name"] = Value::String(name);
    }
    mcp_tool_call("trpg.actor.spawn", args).await?;
    if !keeper.is_empty() {
        if let Err(err) = mcp_tool_call(
            "trpg.actor.claim",
            json!({
                "room_id": actor_admin_room_id(),
                "actor_id": actor_id,
                "keeper_name": keeper
            }),
        )
        .await
        {
            return Err(explain_claim_conflict(&err));
        }
    }
    let rows = refresh_actor_admin_list(doc).await?;
    Ok(format!("액터 생성 완료 ({}명): {}", rows.len(), actor_id))
}

async fn actor_admin_update(doc: &web_sys::Document) -> Result<String, String> {
    let room_id = actor_admin_room_id();
    let actor_id = actor_admin_input_value(doc, "actor-admin-id");
    if actor_id.is_empty() {
        return Err("수정할 Actor ID를 입력하세요.".to_string());
    }
    let name = actor_admin_input_value(doc, "actor-admin-name");
    let role = actor_admin_select_value(doc, "actor-admin-role");
    let keeper = actor_admin_input_value(doc, "actor-admin-keeper");
    let hp = actor_admin_input_i64(doc, "actor-admin-hp");
    let max_hp = actor_admin_input_i64(doc, "actor-admin-max-hp");

    let mut args = json!({
        "room_id": room_id,
        "actor_id": actor_id
    });
    let mut has_patch = false;
    if !name.is_empty() {
        args["name"] = Value::String(name);
        has_patch = true;
    }
    if !role.is_empty() {
        args["role"] = Value::String(role);
        has_patch = true;
    }
    if let Some(hp) = hp {
        args["hp"] = Value::Number(hp.max(0).into());
        args["alive"] = Value::Bool(hp > 0);
        has_patch = true;
    }
    if let Some(max_hp) = max_hp {
        args["max_hp"] = Value::Number(max_hp.max(1).into());
        has_patch = true;
    }
    if !has_patch && keeper.is_empty() {
        return Err("수정할 필드 또는 keeper를 입력하세요.".to_string());
    }

    if has_patch {
        mcp_tool_call("trpg.actor.update", args).await?;
    }
    if !keeper.is_empty() {
        if let Err(err) = mcp_tool_call(
            "trpg.actor.claim",
            json!({
                "room_id": actor_admin_room_id(),
                "actor_id": actor_id,
                "keeper_name": keeper
            }),
        )
        .await
        {
            return Err(explain_claim_conflict(&err));
        }
    }
    let rows = refresh_actor_admin_list(doc).await?;
    Ok(format!("액터 수정 완료 ({}명): {}", rows.len(), actor_id))
}

async fn actor_admin_release(doc: &web_sys::Document) -> Result<String, String> {
    let room_id = actor_admin_room_id();
    let actor_id = actor_admin_input_value(doc, "actor-admin-id");
    if actor_id.is_empty() {
        return Err("점유 해제할 Actor ID를 입력하세요.".to_string());
    }

    let keeper = actor_admin_input_value(doc, "actor-admin-keeper");
    let keeper_name = if keeper.is_empty() {
        let payload = fetch_room_state_payload(&room_id).await?;
        parse_actor_control_map(&payload)
            .get(&actor_id)
            .cloned()
            .unwrap_or_default()
    } else {
        keeper
    };
    if keeper_name.is_empty() {
        return Err(format!("actor {} 는 현재 점유자가 없습니다.", actor_id));
    }

    mcp_tool_call(
        "trpg.actor.release",
        json!({
            "room_id": room_id,
            "actor_id": actor_id,
            "keeper_name": keeper_name,
            "reason": "viewer admin release"
        }),
    )
    .await
    .map_err(|e| explain_claim_conflict(&e))?;

    let rows = refresh_actor_admin_list(doc).await?;
    Ok(format!(
        "액터 점유 해제 완료 ({}명): {}",
        rows.len(),
        actor_id
    ))
}

async fn actor_admin_delete(doc: &web_sys::Document) -> Result<String, String> {
    let room_id = actor_admin_room_id();
    let actor_id = actor_admin_input_value(doc, "actor-admin-id");
    if actor_id.is_empty() {
        return Err("삭제할 Actor ID를 입력하세요.".to_string());
    }
    let reason = actor_admin_input_value(doc, "actor-admin-delete-reason");
    let mut args = json!({
        "room_id": room_id,
        "actor_id": actor_id
    });
    if !reason.is_empty() {
        args["reason"] = Value::String(reason);
    }
    mcp_tool_call("trpg.actor.delete", args).await?;
    let rows = refresh_actor_admin_list(doc).await?;
    Ok(format!("액터 삭제 완료 ({}명): {}", rows.len(), actor_id))
}

// ─── New Game Flow ──────────────────────────────────────────────

async fn rollback_claimed_actors(room_id: &str, claims: &[(String, String)]) {
    if claims.is_empty() {
        return;
    }
    for (actor_id, keeper_name) in claims.iter().rev() {
        let release_args = json!({
            "room_id": room_id,
            "actor_id": actor_id,
            "keeper_name": keeper_name
        });
        if let Err(err) = mcp_tool_call("trpg.actor.release", release_args).await {
            log::warn!(
                "new-game rollback: actor release failed room={} actor={} keeper={} err={}",
                room_id,
                actor_id,
                keeper_name,
                err
            );
        }
    }
}

async fn run_new_game_quick_start(doc: &web_sys::Document) -> Result<String, String> {
    set_new_game_progress(
        doc,
        NewGameFlowStage::Bootstrap,
        "빠른 시작: keeper/preset 동기화 중...",
    );
    set_new_game_preflight_state(doc, "pending");
    sync_new_game_wizard_ui(doc);

    let bootstrap = refresh_new_game_bootstrap(doc).await?;
    set_new_game_progress(
        doc,
        NewGameFlowStage::Bootstrap,
        &if bootstrap.keepers.is_empty() {
            format!(
                "빠른 시작: Keeper 없음 · 월드 {}개 · DM 프리셋 {}개",
                bootstrap.world_presets.len(),
                bootstrap.dm_presets.len()
            )
        } else {
            format!(
                "빠른 시작: Keeper {}개 · 월드 {}개 · DM 프리셋 {}개 로드됨",
                bootstrap.keepers.len(),
                bootstrap.world_presets.len(),
                bootstrap.dm_presets.len()
            )
        },
    );

    if bootstrap.keepers.is_empty() {
        return Err(
            "사용 가능한 keeper가 없습니다. Keeper를 먼저 실행한 뒤 `Keeper 새로고침`을 눌러주세요."
                .to_string(),
        );
    }

    set_new_game_flow_stage(doc, NewGameFlowStage::Preflight, Some("사전 점검 실행"));
    set_new_game_preflight_status(doc, "사전 점검 실행 중...");
    run_new_game_preflight(doc).await?;

    if selected_player_keepers(doc).is_empty() {
        let selected = auto_select_player_keepers(doc, 4);
        if selected > 0 {
            set_new_game_status(
                doc,
                &format!(
                    "빠른 시작: 플레이어 keeper {}명을 자동 선택했습니다.",
                    selected
                ),
            );
        }
    }
    update_new_game_player_hint(doc);
    ensure_new_game_ready(doc)?;
    set_new_game_flow_stage(
        doc,
        NewGameFlowStage::ValidatingInput,
        Some("빠른 시작에서 세션 시작으로 전환"),
    );
    start_new_game_flow(doc).await
}

fn resolve_new_game_room_id(raw_input: &str) -> String {
    let trimmed = raw_input.trim();
    if trimmed.is_empty() {
        return generate_room_id();
    }
    let sanitized =
        crate::config::sanitize_room_id(trimmed).unwrap_or_else(|| generate_room_id());
    let lower = sanitized.to_ascii_lowercase();
    if lower == crate::config::DEFAULT_ROOM_ID || lower == "room-unknown" {
        generate_room_id()
    } else {
        sanitized
    }
}

async fn start_new_game_flow(doc: &web_sys::Document) -> Result<String, String> {
    set_new_game_progress(
        doc,
        NewGameFlowStage::ValidatingInput,
        "세션 준비 1/6: 입력값/keeper 선택을 검증 중...",
    );

    let room_input = doc
        .get_element_by_id("new-game-room-id")
        .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
        .unwrap_or_default();
    let room_id = resolve_new_game_room_id(&room_input);
    if let Some(input) = doc
        .get_element_by_id("new-game-room-id")
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_value(&room_id);
    }

    let mut dm_keeper = doc
        .get_element_by_id("new-game-dm-select")
        .and_then(|el| {
            el.dyn_ref::<web_sys::HtmlSelectElement>()
                .map(|s| s.value())
        })
        .unwrap_or_default()
        .trim()
        .to_string();
    if dm_keeper.is_empty() {
        return Err("DM keeper를 선택하세요.".to_string());
    }

    let mut auto_selected_players = false;
    let mut players = selected_player_keepers(doc);
    if players.is_empty() {
        players = available_player_keepers(doc)
            .into_iter()
            .filter(|keeper| keeper != &dm_keeper)
            .collect();
        if players.len() > 4 {
            players.truncate(4);
        }
        players = unique_non_empty(players);
        if !players.is_empty() {
            apply_player_keeper_selection(doc, &players);
            auto_selected_players = true;
        }
    }
    if players.is_empty() {
        if refresh_keeper_selectors(doc).await.is_ok() {
            let refreshed_dm = doc
                .get_element_by_id("new-game-dm-select")
                .and_then(|el| {
                    el.dyn_ref::<web_sys::HtmlSelectElement>()
                        .map(|s| s.value())
                })
                .unwrap_or_default()
                .trim()
                .to_string();
            if !refreshed_dm.is_empty() {
                dm_keeper = refreshed_dm;
            }

            players = selected_player_keepers(doc);
            if players.is_empty() {
                players = available_player_keepers(doc)
                    .into_iter()
                    .filter(|keeper| keeper != &dm_keeper)
                    .collect();
            }
            if players.len() > 4 {
                players.truncate(4);
            }
            players = unique_non_empty(players);
            if !players.is_empty() {
                apply_player_keeper_selection(doc, &players);
                auto_selected_players = true;
            }
        }
    }
    players.retain(|keeper| keeper != &dm_keeper);
    players = unique_non_empty(players);
    if players.len() > 8 {
        players.truncate(8);
        apply_player_keeper_selection(doc, &players);
    }
    if players.is_empty() {
        return Err(
            "AI Player keeper를 선택할 수 없습니다. keeper 목록을 먼저 새로고침하세요.".to_string(),
        );
    }
    let manual_players = manual_player_keeper_order_for_assignment(doc, &players)?;
    if manual_players.is_empty() {
        return Err(
            "수동 매핑 테이블이 비어 있습니다. 플레이어 keeper를 다시 선택하세요.".to_string(),
        );
    }

    let model_text = doc
        .get_element_by_id("new-game-models")
        .and_then(|el| el.dyn_ref::<web_sys::HtmlInputElement>().map(|i| i.value()))
        .unwrap_or_default();
    let models = parse_keeper_models(&model_text);

    let mut world_preset_id = doc
        .get_element_by_id("new-game-world-select")
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
        .map(|select| select.value())
        .unwrap_or_default()
        .trim()
        .to_string();
    let mut dm_preset_id = doc
        .get_element_by_id("new-game-dm-preset-select")
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
        .map(|select| select.value())
        .unwrap_or_default()
        .trim()
        .to_string();
    let mut preset_keys_hint = "[]".to_string();

    if world_preset_id.is_empty() || dm_preset_id.is_empty() {
        set_new_game_flow_stage(
            doc,
            NewGameFlowStage::ResolvingPreset,
            Some("프리셋 선택값을 보강 중"),
        );
        if let Ok((world_options, dm_options)) = refresh_preset_selectors(doc).await {
            if world_preset_id.is_empty() {
                world_preset_id = world_options
                    .first()
                    .map(|row| row.id.clone())
                    .unwrap_or_default();
            }
            if dm_preset_id.is_empty() {
                dm_preset_id = dm_options
                    .first()
                    .map(|row| row.id.clone())
                    .unwrap_or_default();
            }
        }
    }

    if world_preset_id.is_empty() || dm_preset_id.is_empty() {
        set_new_game_flow_stage(
            doc,
            NewGameFlowStage::ResolvingPreset,
            Some("프리셋 목록 API를 조회 중"),
        );
        let preset_catalog = fetch_preset_catalog().await?;
        preset_keys_hint = preset_catalog_keys_preview_from_value(&preset_catalog);
        if world_preset_id.is_empty() {
            let world_options = collect_world_preset_options(&preset_catalog);
            world_preset_id = world_options
                .first()
                .map(|row| row.id.clone())
                .or_else(|| extract_first_preset_id(&preset_catalog, "world_presets"))
                .or_else(|| extract_first_preset_id(&preset_catalog, "world"))
                .or_else(|| extract_first_preset_id_by_key(&preset_catalog, "world"))
                .unwrap_or_default();
        }
        if dm_preset_id.is_empty() {
            let dm_options = collect_dm_preset_options(&preset_catalog);
            dm_preset_id = dm_options
                .first()
                .map(|row| row.id.clone())
                .or_else(|| extract_first_preset_id(&preset_catalog, "dm_presets"))
                .or_else(|| extract_first_preset_id(&preset_catalog, "dm"))
                .or_else(|| extract_first_preset_id_by_key(&preset_catalog, "dm"))
                .unwrap_or_default();
        }
    }
    if world_preset_id.is_empty() || dm_preset_id.is_empty() {
        return Err(format!(
            "trpg preset 목록 파싱 실패: world_preset_id={}, dm_preset_id={}, known_keys={}",
            world_preset_id, dm_preset_id, preset_keys_hint
        ));
    }

    set_new_game_progress(
        doc,
        NewGameFlowStage::GeneratingPool,
        "세션 준비 2/6: 플레이어 풀 생성 중...",
    );
    let party_size = players.len() as i64;
    let pool_size = std::cmp::max(8_i64, party_size);
    let session_id = format!("viewer-{}-{}", room_id, js_sys::Date::now() as i64);

    let pool_result = mcp_tool_call(
        "trpg.pool.generate",
        json!({
            "session_id": session_id,
            "world_preset_id": world_preset_id,
            "dm_preset_id": dm_preset_id,
            "pool_size": pool_size,
            "party_size": party_size,
            "seed": (js_sys::Date::now() as i64) % 100_000
        }),
    )
    .await?;
    let pool = pool_result
        .get("pool")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if pool.is_empty() {
        return Err("pool.generate 결과가 비어 있습니다.".to_string());
    }

    let mut selected_player_ids = pool_result
        .get("suggested_party_ids")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(|id| id.trim().to_string())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    selected_player_ids = unique_non_empty(selected_player_ids);

    if selected_player_ids.len() < party_size as usize {
        for row in &pool {
            let Some(actor_id) = row
                .get("actor_id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|id| !id.is_empty())
            else {
                continue;
            };
            if selected_player_ids.iter().any(|id| id == actor_id) {
                continue;
            }
            selected_player_ids.push(actor_id.to_string());
            if selected_player_ids.len() >= party_size as usize {
                break;
            }
        }
    }
    if selected_player_ids.is_empty() {
        return Err("선택 가능한 actor_id를 찾지 못했습니다.".to_string());
    }

    set_new_game_progress(
        doc,
        NewGameFlowStage::SelectingParty,
        "세션 준비 3/6: 파티 구성/액터 선택 중...",
    );
    let party_result = mcp_tool_call(
        "trpg.party.select",
        json!({
            "session_id": session_id,
            "room_id": room_id,
            "pool": pool,
            "selected_player_ids": selected_player_ids
        }),
    )
    .await?;
    let party = party_result
        .get("party")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if party.is_empty() {
        return Err("party.select 결과가 비어 있습니다.".to_string());
    }

    set_new_game_progress(
        doc,
        NewGameFlowStage::StartingSession,
        "세션 준비 4/6: 세션 시작 이벤트 기록 중...",
    );
    let _start_result = mcp_tool_call(
        "trpg.session.start",
        json!({
            "session_id": session_id,
            "room_id": room_id,
            "dm_preset_id": dm_preset_id,
            "world_preset_id": world_preset_id,
            "party": party,
            "phase": "briefing"
        }),
    )
    .await?;

    let mut actor_ids = party
        .iter()
        .filter_map(|row| row.get("actor_id").and_then(Value::as_str))
        .map(|id| id.trim().to_string())
        .filter(|id| !id.is_empty())
        .collect::<Vec<_>>();
    actor_ids = unique_non_empty(actor_ids);
    if actor_ids.is_empty() {
        return Err("세션 party actor_id를 읽지 못했습니다.".to_string());
    }

    let assignments = assign_keepers_to_actor_ids(&actor_ids, &dm_keeper, &manual_players)?;
    let player_map: std::collections::HashMap<String, String> = assignments.into_iter().collect();

    set_new_game_progress(
        doc,
        NewGameFlowStage::ClaimingActors,
        "세션 준비 5/6: actor ↔ keeper 점유 동기화 중...",
    );
    let mut claimed_pairs = Vec::new();
    for (actor_id, keeper_name) in &player_map {
        if let Err(err) = mcp_tool_call(
            "trpg.actor.claim",
            json!({
                "room_id": room_id,
                "actor_id": actor_id,
                "keeper_name": keeper_name
            }),
        )
        .await
        {
            rollback_claimed_actors(&room_id, &claimed_pairs).await;
            return Err(format!(
                "actor claim 실패 (actor {} / keeper {}): {}. 기존 claim rollback을 시도했습니다.",
                actor_id,
                keeper_name,
                explain_claim_conflict(&err)
            ));
        }
        claimed_pairs.push((actor_id.clone(), keeper_name.clone()));
    }

    let models_value = if models.is_empty() {
        None
    } else {
        Some(Value::Array(
            models
                .iter()
                .map(|m| Value::String(m.clone()))
                .collect::<Vec<_>>(),
        ))
    };

    set_new_game_progress(
        doc,
        NewGameFlowStage::BootingKeepers,
        "세션 준비 6/6: DM/플레이어 keeper 부팅 중...",
    );
    let mut dm_keeper_up_args = json!({
        "name": dm_keeper,
        "goal": format!("TRPG room {}의 세계관 주민 DM keeper로 장면을 진행하세요.", room_id),
        "instructions": "모든 응답은 한국어로 작성하세요.",
        "proactive_enabled": false,
        "presence_keepalive": true
    });
    if let Some(models_value) = &models_value {
        dm_keeper_up_args["models"] = models_value.clone();
    }
    if let Err(err) = mcp_tool_call("masc_keeper_up", dm_keeper_up_args).await {
        rollback_claimed_actors(&room_id, &claimed_pairs).await;
        return Err(format!(
            "DM keeper 준비 실패 ({}): {}. 기존 actor claim rollback을 시도했습니다. 새 keeper 생성 시 모델 입력이 필요합니다.",
            dm_keeper, err
        ));
    }

    for (actor_id, keeper_name) in &player_map {
        let mut player_keeper_up_args = json!({
            "name": keeper_name,
            "goal": format!("TRPG room {}에서 {} actor를 플레이하세요.", room_id, actor_id),
            "instructions": "모든 응답은 한국어로 작성하세요.",
            "proactive_enabled": false,
            "presence_keepalive": true
        });
        if let Some(models_value) = &models_value {
            player_keeper_up_args["models"] = models_value.clone();
        }
        if let Err(err) = mcp_tool_call("masc_keeper_up", player_keeper_up_args).await {
            rollback_claimed_actors(&room_id, &claimed_pairs).await;
            return Err(format!(
                "Player keeper 준비 실패 (actor {} / keeper {}): {}. 기존 actor claim rollback을 시도했습니다. 새 keeper 생성 시 모델 입력이 필요합니다.",
                actor_id, keeper_name, err
            ));
        }
    }

    set_current_room_id(doc, &room_id);
    clear_trpg_dom(doc);
    set_new_game_flow_stage(
        doc,
        NewGameFlowStage::Finalizing,
        Some("라운드 실행 필드/할당 요약 동기화"),
    );
    set_round_run_fields(doc, &dm_keeper, &actor_ids, &player_map);
    set_new_game_assignment(
        doc,
        &dm_keeper,
        &dm_preset_id,
        &world_preset_id,
        &player_map,
        &actor_ids,
    );

    Ok(format!(
        "새 게임 시작 완료: room {} / DM {} / players {}{}",
        room_id,
        dm_keeper,
        player_map.len(),
        if auto_selected_players {
            " (플레이어 자동 선택 적용)"
        } else {
            ""
        }
    ))
}

fn set_new_game_assignment(
    doc: &web_sys::Document,
    dm_keeper: &str,
    dm_preset_id: &str,
    world_preset_id: &str,
    player_map: &std::collections::HashMap<String, String>,
    actor_ids: &[String],
) {
    let Some(el) = doc.get_element_by_id("new-game-assignment") else {
        return;
    };

    let mut html = String::from(
        "<div class=\"new-game-assignment-preview\"><div class=\"new-game-assignment-badges\">",
    );
    html.push_str(&wizard_state_badge("세션 시작 완료", "ok"));
    html.push_str(&wizard_state_badge("할당 확정", "ok"));
    html.push_str("</div>");
    html.push_str(&format!(
        "<div class=\"new-game-assignment-meta\"><span>world: <code>{}</code></span><span>dm preset: <code>{}</code></span></div>",
        html_escape(world_preset_id),
        html_escape(dm_preset_id),
    ));
    html.push_str("<ul class=\"new-game-assignment-list\">");
    html.push_str(&format!(
        "<li><strong>DM:</strong> {}</li>",
        html_escape(dm_keeper)
    ));
    for actor_id in actor_ids {
        let keeper = player_map
            .get(actor_id)
            .map(String::as_str)
            .unwrap_or("미정");
        html.push_str(&format!(
            "<li>{} → {}</li>",
            html_escape(actor_id),
            html_escape(keeper)
        ));
    }
    html.push_str("</ul><div class=\"new-game-assignment-note\">라운드 실행 버튼으로 TURN 루프를 시작하세요.</div></div>");
    el.set_inner_html(&html);
}

// ─── Preset System ──────────────────────────────────────────────

fn built_in_preset_catalog() -> Value {
    json!({
        "world_presets": [
            { "id": "grimland-chronicle", "title": "Grimland Chronicle" },
            { "id": "emberfall-siege", "title": "Emberfall Siege" }
        ],
        "dm_presets": [
            { "id": "grim-warden", "title": "Grim Warden" },
            { "id": "mythic-weaver", "title": "Mythic Weaver" }
        ]
    })
}

async fn fetch_preset_catalog() -> Result<Value, String> {
    let args = json!({
        "include_characters": false,
        "include_skills": false
    });

    let primary = mcp_tool_call("trpg.preset.list", args.clone()).await;
    let payload = match primary {
        Ok(value) => value,
        Err(primary_err) => {
            log::warn!(
                "trpg.preset.list failed; trying legacy fallback: {}",
                primary_err
            );
            match mcp_tool_call("masc_trpg_preset_list", args.clone()).await {
                Ok(value) => value,
                Err(legacy_err) => {
                    log::warn!(
                        "masc_trpg_preset_list fallback failed; retrying primary once: {}",
                        legacy_err
                    );
                    match mcp_tool_call("trpg.preset.list", args).await {
                        Ok(value) => value,
                        Err(retry_err) => {
                            let fallback = built_in_preset_catalog();
                            log::warn!(
                                "trpg.preset.list failed after retries; using built-in preset catalog: primary={} fallback={} retry={}",
                                primary_err,
                                legacy_err,
                                retry_err
                            );
                            return Ok(fallback);
                        }
                    }
                }
            }
        }
    };
    Ok(normalize_preset_catalog(&payload))
}

fn parse_json_string_value(value: &Value) -> Option<Value> {
    let raw = value.as_str()?.trim();
    if raw.is_empty() {
        return None;
    }
    parse_embedded_tool_payload(raw)
        .ok()
        .or_else(|| serde_json::from_str::<Value>(raw).ok())
}

fn normalize_preset_catalog(raw: &Value) -> Value {
    let mut value = raw.clone();
    for _ in 0..8 {
        if let Some(parsed) = parse_json_string_value(&value) {
            value = parsed;
            continue;
        }
        if let Some(next_value) = preset_unwrap_payload(&value) {
            value = next_value;
            continue;
        }
        if let Some(parsed) = preset_unwrap_content(&value) {
            value = parsed;
            continue;
        }
        break;
    }

    if let Some(parsed) = parse_json_string_value(&value) {
        value = parsed;
    }

    if value.is_array() {
        let mut obj = serde_json::Map::new();
        obj.insert("items".to_string(), value);
        return Value::Object(obj);
    }
    if let Some(presets) = value.get("presets") {
        let normalized = parse_json_string_value(presets).unwrap_or_else(|| presets.clone());
        if normalized.is_array() {
            let mut obj = serde_json::Map::new();
            obj.insert("items".to_string(), normalized);
            Value::Object(obj)
        } else {
            normalized
        }
    } else {
        value
    }
}

fn preset_unwrap_payload(value: &Value) -> Option<Value> {
    value
        .get("payload")
        .or_else(|| value.get("result"))
        .or_else(|| value.get("data"))
        .or_else(|| value.get("structuredContent"))
        .cloned()
        .or_else(|| value.get("presets").cloned())
}

fn preset_unwrap_content(value: &Value) -> Option<Value> {
    if let Some(presets_text) = value
        .get("content")
        .and_then(Value::as_array)
        .and_then(|rows| {
            rows.iter().find_map(|row| {
                if row.get("type").and_then(Value::as_str) == Some("text") {
                    row.get("text").and_then(Value::as_str)
                } else {
                    None
                }
            })
        })
    {
        parse_embedded_tool_payload(presets_text).ok()
    } else if let Some(raw_text) = value.get("content").and_then(Value::as_str) {
        parse_embedded_tool_payload(raw_text).ok()
    } else {
        None
    }
}

fn extract_first_preset_id(catalog: &Value, list_key: &str) -> Option<String> {
    catalog
        .get(list_key)
        .and_then(extract_first_preset_id_from_node)
        .or_else(|| {
            catalog
                .get("items")
                .and_then(extract_first_preset_id_from_node)
        })
        .or_else(|| {
            catalog
                .get("presets")
                .and_then(extract_first_preset_id_from_node)
        })
        .map(|id| id.trim().to_string())
        .filter(|id| !id.is_empty())
}

fn extract_first_preset_id_from_node(raw: &Value) -> Option<String> {
    if let Some(id) = raw.get("id").and_then(Value::as_str) {
        return Some(id.to_string());
    }
    if let Some(id) = raw.get("preset_id").and_then(Value::as_str) {
        return Some(id.to_string());
    }
    if let Some(id) = raw.get("uid").and_then(Value::as_str) {
        return Some(id.to_string());
    }
    if let Some(id) = raw.get("name").and_then(Value::as_str) {
        return Some(id.to_string());
    }
    if let Some(items) = raw.get("items").or_else(|| raw.get("presets")) {
        return extract_first_preset_id_from_node(items);
    }
    if let Some(list) = raw.as_array() {
        for item in list {
            if let Some(id) = extract_first_preset_id_from_node(item) {
                return Some(id);
            }
        }
    }
    if let Some(obj) = raw.as_object() {
        for (_, value) in obj {
            if let Some(id) = extract_first_preset_id_from_node(value) {
                return Some(id);
            }
        }
    }
    raw.as_str().map(|raw| raw.to_string())
}

fn extract_first_preset_id_by_key(catalog: &Value, alt_key: &str) -> Option<String> {
    catalog
        .get(alt_key)
        .and_then(Value::as_str)
        .filter(|name| !name.trim().is_empty())
        .map(|name| name.trim().to_string())
}

fn preset_option_from_value(node: &Value) -> Option<PresetOption> {
    let id = node
        .get("id")
        .and_then(Value::as_str)
        .or_else(|| node.get("preset_id").and_then(Value::as_str))
        .or_else(|| node.get("uid").and_then(Value::as_str))
        .or_else(|| node.get("name").and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())?
        .to_string();

    let title = node
        .get("title")
        .and_then(Value::as_str)
        .or_else(|| node.get("label").and_then(Value::as_str))
        .or_else(|| node.get("name").and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(&id)
        .to_string();

    Some(PresetOption { id, title })
}

fn collect_preset_options_from_node(node: &Value, out: &mut Vec<PresetOption>, depth: usize) {
    if depth > 6 {
        return;
    }
    match node {
        Value::String(raw) => {
            let value = raw.trim();
            if value.is_empty() {
                return;
            }
            if out.iter().any(|item| item.id == value) {
                return;
            }
            out.push(PresetOption {
                id: value.to_string(),
                title: value.to_string(),
            });
        }
        Value::Array(rows) => {
            for row in rows {
                collect_preset_options_from_node(row, out, depth + 1);
            }
        }
        Value::Object(fields) => {
            if let Some(option) = preset_option_from_value(node) {
                if !out.iter().any(|item| item.id == option.id) {
                    out.push(option);
                }
            }
            for value in fields.values() {
                if value.is_array() || value.is_object() {
                    collect_preset_options_from_node(value, out, depth + 1);
                }
            }
        }
        _ => {}
    }
}

fn collect_preset_options_from_catalog(catalog: &Value, keys: &[&str]) -> Vec<PresetOption> {
    let mut out = Vec::new();
    for key in keys {
        if let Some(node) = catalog.get(*key) {
            collect_preset_options_from_node(node, &mut out, 0);
        }
    }
    if out.is_empty() {
        for fallback_key in ["items", "presets"] {
            if let Some(node) = catalog.get(fallback_key) {
                collect_preset_options_from_node(node, &mut out, 0);
            }
        }
    }
    out
}

fn collect_preset_options_by_key_fragment(catalog: &Value, fragment: &str) -> Vec<PresetOption> {
    let mut out = Vec::new();
    let needle = fragment.trim().to_ascii_lowercase();
    if needle.is_empty() {
        return out;
    }
    let Some(obj) = catalog.as_object() else {
        return out;
    };
    for (key, value) in obj {
        if key.to_ascii_lowercase().contains(&needle) {
            collect_preset_options_from_node(value, &mut out, 0);
        }
    }
    out
}

fn collect_world_preset_options(catalog: &Value) -> Vec<PresetOption> {
    let mut out = collect_preset_options_from_catalog(
        catalog,
        &[
            "world_presets",
            "world",
            "world_preset",
            "worlds",
            "worldPresets",
            "worldPreset",
            "world_options",
            "world_preset_options",
        ],
    );
    if out.is_empty() {
        out = collect_preset_options_by_key_fragment(catalog, "world");
    }
    out
}

fn collect_dm_preset_options(catalog: &Value) -> Vec<PresetOption> {
    let mut out = collect_preset_options_from_catalog(
        catalog,
        &[
            "dm_presets",
            "dm",
            "dm_preset",
            "dms",
            "dmPresets",
            "dmPreset",
            "dm_options",
            "dm_preset_options",
        ],
    );
    if out.is_empty() {
        out = collect_preset_options_by_key_fragment(catalog, "dm");
    }
    out
}

fn preset_catalog_keys_preview_from_value(catalog: &Value) -> String {
    let Some(obj) = catalog.as_object() else {
        return "(non-object)".to_string();
    };
    let mut keys = obj.keys().map(|k| k.trim().to_string()).collect::<Vec<_>>();
    keys.retain(|k| !k.is_empty());
    keys.sort();
    keys.dedup();
    if keys.is_empty() {
        return "[]".to_string();
    }
    let preview = keys.iter().take(8).cloned().collect::<Vec<_>>().join(", ");
    if keys.len() > 8 {
        format!("[{} ... +{}]", preview, keys.len() - 8)
    } else {
        format!("[{}]", preview)
    }
}

fn select_options_set(
    doc: &web_sys::Document,
    select_id: &str,
    options: &[PresetOption],
) -> Option<String> {
    let select = doc
        .get_element_by_id(select_id)
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())?;

    let previous = select.value();
    if options.is_empty() {
        select.set_inner_html(r#"<option value="">(none)</option>"#);
        select.set_value("");
        return None;
    }

    let html = options
        .iter()
        .map(|option| {
            format!(
                r#"<option value="{id}">{title} ({id})</option>"#,
                id = html_escape(&option.id),
                title = html_escape(&option.title),
            )
        })
        .collect::<Vec<_>>()
        .join("");
    select.set_inner_html(&html);

    let selected =
        if !previous.trim().is_empty() && options.iter().any(|option| option.id == previous) {
            previous
        } else {
            options[0].id.clone()
        };
    select.set_value(&selected);
    Some(selected)
}

async fn refresh_preset_selectors(
    doc: &web_sys::Document,
) -> Result<(Vec<PresetOption>, Vec<PresetOption>), String> {
    let catalog = match fetch_preset_catalog().await {
        Ok(catalog) => catalog,
        Err(err) => {
            if let Some(world_select) = doc.get_element_by_id("new-game-world-select") {
                world_select.set_inner_html(r#"<option value="">(월드 프리셋 조회 실패)</option>"#);
            }
            if let Some(dm_select) = doc.get_element_by_id("new-game-dm-preset-select") {
                dm_select.set_inner_html(r#"<option value="">(DM 프리셋 조회 실패)</option>"#);
            }
            return Err(err);
        }
    };
    let mut world_presets = collect_world_preset_options(&catalog);
    let mut dm_presets = collect_dm_preset_options(&catalog);
    if world_presets.is_empty() || dm_presets.is_empty() {
        let fallback = built_in_preset_catalog();
        if world_presets.is_empty() {
            world_presets = collect_world_preset_options(&fallback);
        }
        if dm_presets.is_empty() {
            dm_presets = collect_dm_preset_options(&fallback);
        }
    }

    let _ = select_options_set(doc, "new-game-world-select", &world_presets);
    let _ = select_options_set(doc, "new-game-dm-preset-select", &dm_presets);

    Ok((world_presets, dm_presets))
}

// ─── UI Event Binding ───────────────────────────────────────────

pub(super) fn bind_new_game_controls(doc: &web_sys::Document) {
    let Some(open_btn) = doc.get_element_by_id("new-game-toggle") else {
        return;
    };
    if open_btn.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = open_btn.set_attribute("data-bound", "1");

    let open_cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        sync_new_game_panel_top_offset(&doc);
        set_element_display(&doc, "new-game-panel", "flex");
        if let Some(room_input) = doc
            .get_element_by_id("new-game-room-id")
            .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
        {
            if room_input.value().trim().is_empty() {
                room_input.set_value(&resolve_new_game_room_id(&crate::config::current_room_id()));
            }
        }
        set_new_game_wizard_busy(&doc, false);
        set_new_game_preflight_state(&doc, "pending");
        set_new_game_flow_stage(
            &doc,
            NewGameFlowStage::Bootstrap,
            Some("초기 데이터를 불러오는 중"),
        );
        sync_new_game_wizard_ui(&doc);
        set_new_game_status(&doc, "Keeper 목록을 불러오는 중...");
        set_new_game_preflight_status(&doc, "사전 점검 준비 중...");
        actor_admin_set_status(&doc, "액터 목록을 불러오는 중...", "status-info");
        let doc_for_fetch = doc.clone();
        wasm_bindgen_futures::spawn_local(async move {
            match refresh_new_game_bootstrap(&doc_for_fetch).await {
                Ok(bootstrap) => {
                    set_new_game_status(
                        &doc_for_fetch,
                        &if bootstrap.keepers.is_empty() {
                            format!(
                                "Keeper 없음 · 월드 {}개 · DM 프리셋 {}개 (새 게임 전 keeper 실행 필요)",
                                bootstrap.world_presets.len(),
                                bootstrap.dm_presets.len()
                            )
                        } else {
                            format!(
                                "Keeper {}개 · 월드 {}개 · DM 프리셋 {}개 로드됨",
                                bootstrap.keepers.len(),
                                bootstrap.world_presets.len(),
                                bootstrap.dm_presets.len()
                            )
                        },
                    );
                    set_new_game_flow_stage(
                        &doc_for_fetch,
                        NewGameFlowStage::Preflight,
                        Some("사전 점검 자동 실행"),
                    );
                    actor_admin_set_status(&doc_for_fetch, "액터 목록 로드 완료", "status-ok");
                    set_new_game_preflight_status(&doc_for_fetch, "사전 점검 실행 중...");
                    let _ = run_new_game_preflight(&doc_for_fetch).await;
                }
                Err(e) => {
                    web_sys::console::error_1(
                        &format!("[bind_new_game_controls] bootstrap FAILED: {}", e).into(),
                    );
                    set_new_game_status(&doc_for_fetch, &format!("초기 로드 실패: {}", e));
                    actor_admin_set_status(
                        &doc_for_fetch,
                        &format!("로드 실패: {}", e),
                        "status-error",
                    );
                    set_new_game_preflight_state(&doc_for_fetch, "fail");
                    set_new_game_flow_stage(&doc_for_fetch, NewGameFlowStage::Failed, Some(&e));
                    set_new_game_preflight_status(
                        &doc_for_fetch,
                        &format!("사전 점검 불가: {}", e),
                    );
                    sync_new_game_wizard_ui(&doc_for_fetch);
                }
            }
        });
    }) as Box<dyn FnMut()>);
    let _ = open_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
        target.add_event_listener_with_callback("click", open_cb.as_ref().unchecked_ref())
    });
    open_cb.forget();

    if let Some(close_btn) = doc.get_element_by_id("new-game-close") {
        let close_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            set_new_game_wizard_busy(&doc, false);
            set_new_game_flow_stage(&doc, NewGameFlowStage::Idle, Some("패널 닫힘"));
            set_element_display(&doc, "new-game-panel", "none");
        }) as Box<dyn FnMut()>);
        let _ = close_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", close_cb.as_ref().unchecked_ref())
        });
        close_cb.forget();
    }

    if let Some(regen_btn) = doc.get_element_by_id("new-game-room-regenerate") {
        let regen_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            if let Some(room_input) = doc
                .get_element_by_id("new-game-room-id")
                .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
            {
                room_input.set_value(&generate_room_id());
            }
        }) as Box<dyn FnMut()>);
        let _ = regen_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", regen_cb.as_ref().unchecked_ref())
        });
        regen_cb.forget();
    }

    if let Some(autopick_btn) = doc.get_element_by_id("new-game-autopick-btn") {
        let autopick_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            if new_game_wizard_busy(&doc) {
                return;
            }
            let selected = auto_select_player_keepers(&doc, 4);
            set_new_game_status(
                &doc,
                &format!("플레이어 keeper {}명을 자동 선택했습니다.", selected),
            );
            update_new_game_player_hint(&doc);
        }) as Box<dyn FnMut()>);
        let _ = autopick_btn
            .dyn_ref::<web_sys::EventTarget>()
            .map(|target| {
                target
                    .add_event_listener_with_callback("click", autopick_cb.as_ref().unchecked_ref())
            });
        autopick_cb.forget();
    }

    if let Some(recommend_btn) = doc.get_element_by_id("new-game-manual-recommend") {
        let recommend_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            if new_game_wizard_busy(&doc) {
                return;
            }
            let players = selected_player_keepers(&doc);
            if players.is_empty() {
                set_new_game_status(
                    &doc,
                    "플레이어 keeper를 먼저 선택하세요. 선택 후 추천 매핑을 적용할 수 있습니다.",
                );
                sync_new_game_wizard_ui(&doc);
                return;
            }
            let (recommended, matched_count, slot_count) =
                recommended_manual_mapping_order(&doc, &players);
            if recommended.is_empty() {
                set_new_game_status(
                    &doc,
                    "추천 매핑을 만들지 못했습니다. 액터 목록을 새로고침한 뒤 다시 시도하세요.",
                );
                sync_new_game_wizard_ui(&doc);
                return;
            }
            set_manual_mapping_order(&doc, &recommended);
            sync_manual_mapping_table(&doc);
            sync_new_game_wizard_ui(&doc);
            let status = if slot_count == 0 {
                format!(
                    "추천 매핑 적용: actor 슬롯 정보가 없어 선택 순서 기반으로 정렬했습니다. ({}명)",
                    recommended.len()
                )
            } else if matched_count > 0 {
                format!(
                    "추천 매핑 적용: {}명 중 {}명이 현재 actor 슬롯과 일치했습니다.",
                    recommended.len(),
                    matched_count
                )
            } else {
                format!(
                    "추천 매핑 적용: actor 슬롯 {}개를 확인했지만 일치 keeper가 없어 선택 순서를 유지했습니다.",
                    slot_count
                )
            };
            set_new_game_status(&doc, &status);
        }) as Box<dyn FnMut()>);
        let _ = recommend_btn
            .dyn_ref::<web_sys::EventTarget>()
            .map(|target| {
                target.add_event_listener_with_callback(
                    "click",
                    recommend_cb.as_ref().unchecked_ref(),
                )
            });
        recommend_cb.forget();
    }

    if let Some(reset_btn) = doc.get_element_by_id("new-game-manual-reset") {
        let reset_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            if new_game_wizard_busy(&doc) {
                return;
            }
            let players = selected_player_keepers(&doc);
            if players.is_empty() {
                set_new_game_status(
                    &doc,
                    "플레이어 keeper를 먼저 선택하세요. 선택 후 수동 매핑을 리셋할 수 있습니다.",
                );
                sync_new_game_wizard_ui(&doc);
                return;
            }
            set_manual_mapping_order(&doc, &players);
            sync_manual_mapping_table(&doc);
            sync_new_game_wizard_ui(&doc);
            set_new_game_status(
                &doc,
                &format!(
                    "수동 매핑을 선택 순서로 리셋했습니다. ({}명)",
                    players.len()
                ),
            );
        }) as Box<dyn FnMut()>);
        let _ = reset_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", reset_cb.as_ref().unchecked_ref())
        });
        reset_cb.forget();
    }

    if let Some(refresh_btn) = doc.get_element_by_id("new-game-refresh") {
        let refresh_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            if new_game_wizard_busy(&doc) {
                return;
            }
            set_new_game_preflight_state(&doc, "pending");
            set_new_game_flow_stage(
                &doc,
                NewGameFlowStage::Bootstrap,
                Some("수동 새로고침 실행"),
            );
            sync_new_game_wizard_ui(&doc);
            set_new_game_status(&doc, "세션/프리셋/keeper 정보를 새로고침 중...");
            set_new_game_preflight_status(&doc, "사전 점검 실행 중...");
            actor_admin_set_status(&doc, "액터 목록 새로고침 중...", "status-info");
            let doc_for_fetch = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                match refresh_new_game_bootstrap(&doc_for_fetch).await {
                    Ok(bootstrap) => {
                        set_new_game_status(
                            &doc_for_fetch,
                            &if bootstrap.keepers.is_empty() {
                                format!(
                                    "Keeper 없음 · 월드 {}개 · DM 프리셋 {}개 (새 게임 전 keeper 실행 필요)",
                                    bootstrap.world_presets.len(),
                                    bootstrap.dm_presets.len()
                                )
                            } else {
                                format!(
                                    "Keeper {}개 · 월드 {}개 · DM 프리셋 {}개 새로고침 완료",
                                    bootstrap.keepers.len(),
                                    bootstrap.world_presets.len(),
                                    bootstrap.dm_presets.len()
                                )
                            },
                        );
                        set_new_game_flow_stage(
                            &doc_for_fetch,
                            NewGameFlowStage::Preflight,
                            Some("새로고침 후 사전 점검"),
                        );
                        actor_admin_set_status(
                            &doc_for_fetch,
                            "액터 목록 새로고침 완료",
                            "status-ok",
                        );
                        let _ = run_new_game_preflight(&doc_for_fetch).await;
                    }
                    Err(e) => {
                        set_new_game_status(&doc_for_fetch, &format!("새로고침 실패: {}", e));
                        actor_admin_set_status(
                            &doc_for_fetch,
                            &format!("새로고침 실패: {}", e),
                            "status-error",
                        );
                        set_new_game_preflight_state(&doc_for_fetch, "fail");
                        set_new_game_flow_stage(&doc_for_fetch, NewGameFlowStage::Failed, Some(&e));
                        set_new_game_preflight_status(
                            &doc_for_fetch,
                            &format!("사전 점검 실패: {}", e),
                        );
                        sync_new_game_wizard_ui(&doc_for_fetch);
                    }
                }
            });
        }) as Box<dyn FnMut()>);
        let _ = refresh_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", refresh_cb.as_ref().unchecked_ref())
        });
        refresh_cb.forget();
    }

    if let Some(preflight_btn) = doc.get_element_by_id("new-game-preflight-btn") {
        let preflight_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            if new_game_wizard_busy(&doc) {
                return;
            }
            set_new_game_preflight_state(&doc, "pending");
            set_new_game_flow_stage(&doc, NewGameFlowStage::Preflight, Some("수동 점검 실행"));
            sync_new_game_wizard_ui(&doc);
            set_new_game_preflight_status(&doc, "사전 점검 실행 중...");
            let doc_for_task = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                if let Err(err) = run_new_game_preflight(&doc_for_task).await {
                    log::warn!("new-game preflight failed: {}", err);
                    set_new_game_flow_stage(&doc_for_task, NewGameFlowStage::Failed, Some(&err));
                }
            });
        }) as Box<dyn FnMut()>);
        let _ = preflight_btn
            .dyn_ref::<web_sys::EventTarget>()
            .map(|target| {
                target.add_event_listener_with_callback(
                    "click",
                    preflight_cb.as_ref().unchecked_ref(),
                )
            });
        preflight_cb.forget();
    }

    if let Some(quick_start_btn) = doc.get_element_by_id("new-game-quick-start") {
        let quick_start_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            if new_game_wizard_busy(&doc) {
                return;
            }
            set_new_game_wizard_busy(&doc, true);
            set_new_game_flow_stage(
                &doc,
                NewGameFlowStage::Bootstrap,
                Some("빠른 시작 파이프라인 실행"),
            );
            sync_new_game_wizard_ui(&doc);
            let doc_for_start = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                let result = run_new_game_quick_start(&doc_for_start).await;
                match result {
                    Ok(message) => {
                        set_new_game_flow_stage(
                            &doc_for_start,
                            NewGameFlowStage::Done,
                            Some("빠른 시작 완료"),
                        );
                        set_new_game_status(&doc_for_start, &message);
                        set_element_display(&doc_for_start, "new-game-panel", "none");
                    }
                    Err(e) => {
                        set_new_game_flow_stage(&doc_for_start, NewGameFlowStage::Failed, Some(&e));
                        set_new_game_status(&doc_for_start, &format!("빠른 시작 실패: {}", e));
                    }
                }
                set_new_game_wizard_busy(&doc_for_start, false);
                sync_new_game_wizard_ui(&doc_for_start);
            });
        }) as Box<dyn FnMut()>);
        let _ = quick_start_btn
            .dyn_ref::<web_sys::EventTarget>()
            .map(|target| {
                target.add_event_listener_with_callback(
                    "click",
                    quick_start_cb.as_ref().unchecked_ref(),
                )
            });
        quick_start_cb.forget();
    }

    if let Some(start_btn) = doc.get_element_by_id("new-game-start") {
        let start_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            if new_game_wizard_busy(&doc) {
                return;
            }
            if let Err(reason) = ensure_new_game_ready(&doc) {
                set_new_game_status(&doc, &format!("시작 불가: {}", reason));
                sync_new_game_wizard_ui(&doc);
                return;
            }
            set_new_game_status(&doc, "새 게임 시작 중...");
            set_new_game_wizard_busy(&doc, true);
            set_new_game_flow_stage(
                &doc,
                NewGameFlowStage::ValidatingInput,
                Some("세션 시작 입력 검증"),
            );
            sync_new_game_wizard_ui(&doc);
            let doc_for_start = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                let result = start_new_game_flow(&doc_for_start).await;
                match result {
                    Ok(message) => {
                        set_new_game_flow_stage(
                            &doc_for_start,
                            NewGameFlowStage::Done,
                            Some("세션 시작 완료"),
                        );
                        set_new_game_status(&doc_for_start, &message);
                        set_element_display(&doc_for_start, "new-game-panel", "none");
                    }
                    Err(e) => {
                        set_new_game_flow_stage(&doc_for_start, NewGameFlowStage::Failed, Some(&e));
                        set_new_game_status(&doc_for_start, &format!("시작 실패: {}", e));
                    }
                }
                set_new_game_wizard_busy(&doc_for_start, false);
                sync_new_game_wizard_ui(&doc_for_start);
            });
        }) as Box<dyn FnMut()>);
        let _ = start_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", start_cb.as_ref().unchecked_ref())
        });
        start_cb.forget();
    }

    bind_new_game_selection_watchers(doc);
    set_new_game_flow_stage(doc, NewGameFlowStage::Idle, Some("대기"));
    sync_new_game_wizard_ui(doc);
    bind_actor_admin_controls(doc);
}

fn bind_actor_admin_controls(doc: &web_sys::Document) {
    let Some(refresh_btn) = doc.get_element_by_id("actor-admin-refresh") else {
        return;
    };
    if refresh_btn.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = refresh_btn.set_attribute("data-bound", "1");

    let refresh_cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        actor_admin_set_busy(&doc, true);
        actor_admin_set_status(&doc, "액터 목록을 불러오는 중...", "status-info");
        let doc_for_task = doc.clone();
        wasm_bindgen_futures::spawn_local(async move {
            let result = refresh_actor_admin_list(&doc_for_task).await;
            match result {
                Ok(rows) => actor_admin_set_status(
                    &doc_for_task,
                    &format!(
                        "room {} 액터 {}명",
                        html_escape(&actor_admin_room_id()),
                        rows.len()
                    ),
                    "status-ok",
                ),
                Err(e) => actor_admin_set_status(
                    &doc_for_task,
                    &format!("액터 목록 조회 실패: {}", e),
                    "status-error",
                ),
            }
            actor_admin_set_busy(&doc_for_task, false);
        });
    }) as Box<dyn FnMut()>);
    let _ = refresh_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
        target.add_event_listener_with_callback("click", refresh_cb.as_ref().unchecked_ref())
    });
    refresh_cb.forget();

    if let Some(spawn_btn) = doc.get_element_by_id("actor-admin-spawn") {
        let spawn_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            actor_admin_set_busy(&doc, true);
            actor_admin_set_status(&doc, "액터 생성 중...", "status-info");
            let doc_for_task = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                let result = actor_admin_spawn(&doc_for_task).await;
                match result {
                    Ok(msg) => actor_admin_set_status(&doc_for_task, &msg, "status-ok"),
                    Err(e) => actor_admin_set_status(
                        &doc_for_task,
                        &format!("액터 생성 실패: {}", e),
                        "status-error",
                    ),
                }
                actor_admin_set_busy(&doc_for_task, false);
            });
        }) as Box<dyn FnMut()>);
        let _ = spawn_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", spawn_cb.as_ref().unchecked_ref())
        });
        spawn_cb.forget();
    }

    if let Some(update_btn) = doc.get_element_by_id("actor-admin-update") {
        let update_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            actor_admin_set_busy(&doc, true);
            actor_admin_set_status(&doc, "액터 수정 중...", "status-info");
            let doc_for_task = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                let result = actor_admin_update(&doc_for_task).await;
                match result {
                    Ok(msg) => actor_admin_set_status(&doc_for_task, &msg, "status-ok"),
                    Err(e) => actor_admin_set_status(
                        &doc_for_task,
                        &format!("액터 수정 실패: {}", e),
                        "status-error",
                    ),
                }
                actor_admin_set_busy(&doc_for_task, false);
            });
        }) as Box<dyn FnMut()>);
        let _ = update_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", update_cb.as_ref().unchecked_ref())
        });
        update_cb.forget();
    }

    if let Some(release_btn) = doc.get_element_by_id("actor-admin-release") {
        let release_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            actor_admin_set_busy(&doc, true);
            actor_admin_set_status(&doc, "액터 점유 해제 중...", "status-info");
            let doc_for_task = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                let result = actor_admin_release(&doc_for_task).await;
                match result {
                    Ok(msg) => actor_admin_set_status(&doc_for_task, &msg, "status-ok"),
                    Err(e) => actor_admin_set_status(
                        &doc_for_task,
                        &format!("액터 점유 해제 실패: {}", e),
                        "status-error",
                    ),
                }
                actor_admin_set_busy(&doc_for_task, false);
            });
        }) as Box<dyn FnMut()>);
        let _ = release_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", release_cb.as_ref().unchecked_ref())
        });
        release_cb.forget();
    }

    if let Some(delete_btn) = doc.get_element_by_id("actor-admin-delete") {
        let delete_cb = Closure::wrap(Box::new(move || {
            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let actor_id = actor_admin_input_value(&doc, "actor-admin-id");
            if actor_id.is_empty() {
                actor_admin_set_status(&doc, "삭제할 Actor ID를 입력하세요.", "status-error");
                return;
            }
            let confirmed = web_sys::window()
                .and_then(|w| {
                    w.confirm_with_message(&format!("actor {} 를 삭제할까요?", actor_id))
                        .ok()
                })
                .unwrap_or(false);
            if !confirmed {
                return;
            }
            actor_admin_set_busy(&doc, true);
            actor_admin_set_status(&doc, "액터 삭제 중...", "status-info");
            let doc_for_task = doc.clone();
            wasm_bindgen_futures::spawn_local(async move {
                let result = actor_admin_delete(&doc_for_task).await;
                match result {
                    Ok(msg) => actor_admin_set_status(&doc_for_task, &msg, "status-ok"),
                    Err(e) => actor_admin_set_status(
                        &doc_for_task,
                        &format!("액터 삭제 실패: {}", e),
                        "status-error",
                    ),
                }
                actor_admin_set_busy(&doc_for_task, false);
            });
        }) as Box<dyn FnMut()>);
        let _ = delete_btn.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", delete_cb.as_ref().unchecked_ref())
        });
        delete_cb.forget();
    }
}

// ─── Widget Status ──────────────────────────────────────────────

pub(super) fn refresh_trpg_widget_status() {
    fn parse_counter_attr(doc: &web_sys::Document, key: &str) -> u64 {
        doc.get_element_by_id("dashboard")
            .and_then(|el| el.get_attribute(key))
            .and_then(|raw| raw.parse::<u64>().ok())
            .unwrap_or(0)
    }

    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let narrative_count = doc
        .get_element_by_id("narrative-log")
        .map(|el| el.child_element_count())
        .unwrap_or(0);
    let party_count = doc
        .get_element_by_id("character-panel")
        .map(|el| el.child_element_count())
        .unwrap_or(0);
    let history_count = doc
        .get_element_by_id("session-history")
        .map(|el| el.child_element_count())
        .unwrap_or(0);
    if let Some(status) = doc.get_element_by_id("widget-status") {
        status.set_text_content(Some(&format!(
            "Widgets N:{} P:{} H:{}",
            narrative_count, party_count, history_count
        )));
    }
    let dedup_stream = parse_counter_attr(&doc, "data-dedup-stream");
    let dedup_narrative = parse_counter_attr(&doc, "data-dedup-narrative");
    let dedup_history = parse_counter_attr(&doc, "data-dedup-history");
    if let Some(status) = doc.get_element_by_id("dedup-status") {
        status.set_text_content(Some(&format!(
            "Dedup S:{} N:{} H:{}",
            dedup_stream, dedup_narrative, dedup_history
        )));
    }
    let popover_visible = doc
        .get_element_by_id("dedup-status")
        .and_then(|el| el.get_attribute("aria-expanded"))
        .map(|v| v == "true")
        .unwrap_or(false);
    if popover_visible {
        render_dedup_popover(&doc);
    }
}

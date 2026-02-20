#[cfg(target_arch = "wasm32")]
use bevy::prelude::DetectChanges;
use bevy::prelude::Res;

use crate::game::events::NarrativePayload;
use crate::game::lifecycle::TrpgLifecycleState;
use crate::game::state::{RoomState, TurnProgressState};

#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DmVoiceMode {
    Off,
    Browser,
    ElevenLabs,
}

#[cfg(target_arch = "wasm32")]
const STORAGE_DM_VOICE_MODE: &str = "trpg_dm_voice_mode";
#[cfg(target_arch = "wasm32")]
const STORAGE_DM_VOICE_PROXY_URL: &str = "trpg_dm_voice_proxy_url";
#[cfg(target_arch = "wasm32")]
const STORAGE_DM_VOICE_MODEL: &str = "trpg_dm_voice_model";
#[cfg(target_arch = "wasm32")]
const STORAGE_DM_VOICE_ID: &str = "trpg_dm_voice_id";

#[cfg(target_arch = "wasm32")]
const DM_VOICE_PANEL_ID: &str = "dm-voice-config";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_MODE_SELECT_ID: &str = "dm-voice-mode-select";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_PROXY_SELECT_ID: &str = "dm-voice-proxy-select";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_PROXY_CUSTOM_WRAP_ID: &str = "dm-voice-proxy-custom-wrap";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_PROXY_INPUT_ID: &str = "dm-voice-proxy-url";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_MODEL_SELECT_ID: &str = "dm-voice-model-select";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_MODEL_CUSTOM_WRAP_ID: &str = "dm-voice-model-custom-wrap";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_MODEL_CUSTOM_INPUT_ID: &str = "dm-voice-model-custom";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_ID_SELECT_ID: &str = "dm-voice-id-select";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_ID_CUSTOM_WRAP_ID: &str = "dm-voice-id-custom-wrap";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_ID_CUSTOM_INPUT_ID: &str = "dm-voice-id-custom";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_PREVIEW_BUTTON_ID: &str = "dm-voice-preview-btn";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_SAVE_BUTTON_ID: &str = "dm-voice-save-btn";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_STATUS_ID: &str = "dm-voice-status";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_CUSTOM_VALUE: &str = "custom";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_RANDOM_PRESET_VALUE: &str = "random_preset";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_RANDOM_PRESET_LABEL: &str = "랜덤 (추천 Voice 중 선택)";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_MODEL_PRESETS: &[&str] = &[
    "eleven_turbo_v2_5",
    "eleven_flash_v2_5",
    "eleven_multilingual_v2",
];
#[cfg(target_arch = "wasm32")]
const DM_VOICE_PROXY_ORIGIN_PRESETS: &[&str] = &["/api/v1/trpg/tts", "/api/v1/tts", "/tts"];
#[cfg(target_arch = "wasm32")]
const DM_VOICE_ID_PRESETS: &[(&str, &str)] = &[
    ("21m00Tcm4TlvDq8ikWAM", "Rachel"),
    ("AZnzlk1XvdvUeBnXmlld", "Domi"),
    ("EXAVITQu4vr4xnSDxMaL", "Bella"),
    ("ErXwobaYiN019PkySvjV", "Antoni"),
    ("MF3mGyEYCl7XYWbV9V6O", "Elli"),
    ("TxGEqnHWrfWFTfGW9XjX", "Josh"),
    ("VR6AewLTigWG4xSOukaG", "Arnold"),
    ("pNInz6obpgDQGcFmaJgB", "Adam"),
    ("yoZ06aMxZJJ28mfd3POQ", "Sam"),
];
#[cfg(target_arch = "wasm32")]
const DM_VOICE_PREVIEW_TEXT: &str = "지금은 DM 음성 미리듣기 테스트 중입니다.";

#[cfg(target_arch = "wasm32")]
thread_local! {
    static ACTIVE_DM_VOICE_AUDIO: std::cell::RefCell<Vec<web_sys::HtmlAudioElement>> =
        std::cell::RefCell::new(Vec::new());
}

fn normalize_phase(raw: &str) -> String {
    raw.trim().to_ascii_lowercase().replace('-', "_")
}

fn is_dm_phase(phase: &str) -> bool {
    matches!(
        normalize_phase(phase).as_str(),
        "dm_narration" | "briefing" | "dm"
    )
}

fn is_dm_speaker(speaker: Option<&str>) -> bool {
    let normalized = speaker
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase()
        .replace(' ', "_");
    matches!(normalized.as_str(), "dm" | "game_master" | "gm")
}

fn is_room_running(room_state: &RoomState, progress: &TurnProgressState) -> bool {
    TrpgLifecycleState::from_room_progress(&room_state.status, &progress.room_status)
        .accepts_player_input()
}

fn should_play_dm_voice(
    payload: &NarrativePayload,
    clean_text: &str,
    room_state: &RoomState,
    progress: &TurnProgressState,
) -> bool {
    if clean_text.trim().is_empty() {
        return false;
    }
    if !is_room_running(room_state, progress) {
        return false;
    }
    is_dm_phase(&payload.phase) || is_dm_speaker(payload.speaker.as_deref())
}

pub fn maybe_play_dm_voice(
    payload: &NarrativePayload,
    clean_text: &str,
    room_state: &RoomState,
    progress: &TurnProgressState,
) {
    if !should_play_dm_voice(payload, clean_text, room_state, progress) {
        return;
    }

    #[cfg(target_arch = "wasm32")]
    {
        dispatch_voice(payload, clean_text, room_state);
    }
}

pub fn bind_dm_voice_controls() {
    #[cfg(target_arch = "wasm32")]
    {
        bind_dm_voice_controls_impl();
    }
}

pub fn unbind_dm_voice_controls() {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            set_dm_voice_status(
                &doc,
                "status-info",
                "DM 음성은 세션 진행 중일 때만 재생됩니다.",
            );
        }
    }
}

pub fn sync_dm_voice_controls(room_state: Res<RoomState>, progress: Res<TurnProgressState>) {
    #[cfg(not(target_arch = "wasm32"))]
    let _ = (&room_state, &progress);

    #[cfg(target_arch = "wasm32")]
    {
        if !room_state.is_changed() && !progress.is_changed() {
            return;
        }

        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        if doc.get_element_by_id(DM_VOICE_STATUS_ID).is_none() {
            return;
        }

        let mode = resolve_dm_voice_mode();
        let running = is_room_running(&room_state, &progress);
        match (running, mode) {
            (false, _) => {
                set_dm_voice_status(
                    &doc,
                    "status-info",
                    "대기 상태: 세션이 진행 중일 때만 DM 음성이 재생됩니다.",
                );
            }
            (true, DmVoiceMode::Off) => {
                set_dm_voice_status(
                    &doc,
                    "status-warn",
                    "진행 중이지만 DM 음성 모드가 OFF 입니다.",
                );
            }
            (true, DmVoiceMode::Browser) => {
                set_dm_voice_status(
                    &doc,
                    "status-ok",
                    "진행 중: Browser TTS로 DM 내레이션을 재생합니다.",
                );
            }
            (true, DmVoiceMode::ElevenLabs) => {
                let model = resolve_dm_voice_model().unwrap_or_else(|| "-".to_string());
                let voice_id = resolve_dm_voice_id().unwrap_or_else(|| "-".to_string());
                set_dm_voice_status(
                    &doc,
                    "status-ok",
                    &format!(
                        "진행 중: ElevenLabs proxy 사용 (model: {}, voice_id: {})",
                        model, voice_id
                    ),
                );
            }
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn dispatch_voice(payload: &NarrativePayload, clean_text: &str, room_state: &RoomState) {
    let text = clean_text.trim().to_string();
    if text.is_empty() {
        return;
    }
    let room_id = if room_state.id.trim().is_empty() {
        crate::config::current_room_id()
    } else {
        room_state.id.trim().to_string()
    };
    let phase = payload.phase.trim().to_string();
    let turn = payload.turn;
    let voice_model = resolve_dm_voice_model();
    let voice_id = resolve_dm_voice_id();

    match resolve_dm_voice_mode() {
        DmVoiceMode::Off => {}
        DmVoiceMode::Browser => speak_with_browser(&text),
        DmVoiceMode::ElevenLabs => {
            if let Some(proxy_url) = resolve_dm_voice_proxy_url() {
                speak_with_proxy(proxy_url, text, room_id, phase, turn, voice_model, voice_id);
            } else {
                speak_with_browser(&text);
            }
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn parse_dm_voice_mode(raw: &str) -> DmVoiceMode {
    match raw.trim().to_ascii_lowercase().as_str() {
        "off" | "none" | "mute" | "muted" | "0" => DmVoiceMode::Off,
        "elevenlabs" | "eleven" | "proxy" | "remote" => DmVoiceMode::ElevenLabs,
        _ => DmVoiceMode::Browser,
    }
}

#[cfg(target_arch = "wasm32")]
fn dm_voice_mode_value(mode: DmVoiceMode) -> &'static str {
    match mode {
        DmVoiceMode::Off => "off",
        DmVoiceMode::Browser => "browser",
        DmVoiceMode::ElevenLabs => "elevenlabs",
    }
}

#[cfg(target_arch = "wasm32")]
fn resolve_dm_voice_mode() -> DmVoiceMode {
    resolve_string_setting(
        &["__TRPG_DM_VOICE_MODE", "__DM_VOICE_MODE"],
        &["dm_voice", "dm_voice_mode"],
        STORAGE_DM_VOICE_MODE,
        "meta[name='trpg-dm-voice-mode']",
    )
    .map(|raw| parse_dm_voice_mode(&raw))
    .unwrap_or(DmVoiceMode::Browser)
}

#[cfg(target_arch = "wasm32")]
fn resolve_dm_voice_proxy_url() -> Option<String> {
    resolve_string_setting(
        &["__TRPG_DM_VOICE_PROXY_URL", "__ELEVENLABS_PROXY_URL"],
        &["dm_voice_proxy_url", "elevenlabs_proxy_url"],
        STORAGE_DM_VOICE_PROXY_URL,
        "meta[name='trpg-dm-voice-proxy-url']",
    )
}

#[cfg(target_arch = "wasm32")]
fn resolve_dm_voice_model() -> Option<String> {
    resolve_string_setting(
        &["__TRPG_DM_VOICE_MODEL", "__ELEVENLABS_MODEL"],
        &["dm_voice_model", "elevenlabs_model"],
        STORAGE_DM_VOICE_MODEL,
        "meta[name='trpg-dm-voice-model']",
    )
}

#[cfg(target_arch = "wasm32")]
fn resolve_dm_voice_id() -> Option<String> {
    resolve_string_setting(
        &["__TRPG_DM_VOICE_ID", "__ELEVENLABS_VOICE_ID"],
        &["dm_voice_id", "dm_voice_voice_id", "elevenlabs_voice_id"],
        STORAGE_DM_VOICE_ID,
        "meta[name='trpg-dm-voice-id']",
    )
}

#[cfg(target_arch = "wasm32")]
fn window_origin() -> Option<String> {
    let win = web_sys::window()?;
    let origin = win.location().origin().ok()?;
    normalize_optional(&origin)
}

#[cfg(target_arch = "wasm32")]
fn proxy_origin_value(path: &str) -> String {
    format!("origin:{}", path)
}

#[cfg(target_arch = "wasm32")]
fn resolve_proxy_url_from_select(raw: &str) -> Option<String> {
    let selected = normalize_optional(raw)?;
    if selected == DM_VOICE_CUSTOM_VALUE {
        return None;
    }
    if let Some(path) = selected.strip_prefix("origin:") {
        let origin = window_origin()?;
        return Some(format!("{}{}", origin, path));
    }
    Some(selected)
}

#[cfg(target_arch = "wasm32")]
fn detect_proxy_select_value(current_url: &str) -> Option<String> {
    let current = normalize_optional(current_url)?;
    if let Some(origin) = window_origin() {
        for path in DM_VOICE_PROXY_ORIGIN_PRESETS {
            let preset = format!("{}{}", origin, path);
            if current == preset {
                return Some(proxy_origin_value(path));
            }
        }
    }
    for path in DM_VOICE_PROXY_ORIGIN_PRESETS {
        if current == *path {
            return Some(proxy_origin_value(path));
        }
    }
    None
}

#[cfg(target_arch = "wasm32")]
fn normalize_optional(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

#[cfg(target_arch = "wasm32")]
fn resolve_string_setting(
    global_keys: &[&str],
    query_keys: &[&str],
    storage_key: &str,
    meta_selector: &str,
) -> Option<String> {
    let win = web_sys::window()?;

    for key in global_keys {
        if let Some(raw) = global_string(&win, key) {
            if let Some(value) = normalize_optional(&raw) {
                return Some(value);
            }
        }
    }

    if let Ok(search) = win.location().search() {
        for key in query_keys {
            if let Some(raw) = parse_query_param(&search, key) {
                if let Some(value) = normalize_optional(&raw) {
                    if let Ok(Some(storage)) = win.local_storage() {
                        let _ = storage.set_item(storage_key, &value);
                    }
                    return Some(value);
                }
            }
        }
    }

    if let Ok(Some(storage)) = win.local_storage() {
        if let Ok(Some(raw)) = storage.get_item(storage_key) {
            if let Some(value) = normalize_optional(&raw) {
                return Some(value);
            }
        }
    }

    if let Some(doc) = win.document() {
        if let Ok(Some(meta)) = doc.query_selector(meta_selector) {
            if let Some(raw) = meta.get_attribute("content") {
                if let Some(value) = normalize_optional(&raw) {
                    return Some(value);
                }
            }
        }
    }

    None
}

#[cfg(target_arch = "wasm32")]
fn get_input_value(doc: &web_sys::Document, id: &str) -> Option<String> {
    use wasm_bindgen::JsCast;
    doc.get_element_by_id(id)
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
        .map(|input| input.value())
}

#[cfg(target_arch = "wasm32")]
fn set_input_value(doc: &web_sys::Document, id: &str, value: &str) {
    use wasm_bindgen::JsCast;
    if let Some(input) = doc
        .get_element_by_id(id)
        .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
    {
        input.set_value(value);
    }
}

#[cfg(target_arch = "wasm32")]
fn get_select_value(doc: &web_sys::Document, id: &str) -> Option<String> {
    use wasm_bindgen::JsCast;
    doc.get_element_by_id(id)
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
        .map(|select| select.value())
}

#[cfg(target_arch = "wasm32")]
fn set_select_value(doc: &web_sys::Document, id: &str, value: &str) {
    use wasm_bindgen::JsCast;
    if let Some(select) = doc
        .get_element_by_id(id)
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
    {
        select.set_value(value);
    }
}

#[cfg(target_arch = "wasm32")]
fn set_hidden(doc: &web_sys::Document, id: &str, hidden: bool) {
    let Some(el) = doc.get_element_by_id(id) else {
        return;
    };
    if hidden {
        let _ = el.set_attribute("hidden", "");
    } else {
        let _ = el.remove_attribute("hidden");
    }
}

#[cfg(target_arch = "wasm32")]
fn hydrate_preset_select(
    doc: &web_sys::Document,
    select_id: &str,
    custom_wrap_id: &str,
    custom_input_id: &str,
    current_value: Option<String>,
    is_known_preset: fn(&str) -> bool,
) {
    match current_value.and_then(|v| normalize_optional(&v)) {
        None => {
            set_select_value(doc, select_id, "");
            set_hidden(doc, custom_wrap_id, true);
            set_input_value(doc, custom_input_id, "");
        }
        Some(value) if is_known_preset(&value) => {
            set_select_value(doc, select_id, &value);
            set_hidden(doc, custom_wrap_id, true);
            set_input_value(doc, custom_input_id, "");
        }
        Some(value) => {
            set_select_value(doc, select_id, DM_VOICE_CUSTOM_VALUE);
            set_hidden(doc, custom_wrap_id, false);
            set_input_value(doc, custom_input_id, &value);
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn hydrate_proxy_select(doc: &web_sys::Document, current_url: Option<String>) {
    match current_url.and_then(|v| normalize_optional(&v)) {
        None => {
            set_select_value(doc, DM_VOICE_PROXY_SELECT_ID, DM_VOICE_CUSTOM_VALUE);
            set_hidden(doc, DM_VOICE_PROXY_CUSTOM_WRAP_ID, false);
            set_input_value(doc, DM_VOICE_PROXY_INPUT_ID, "");
        }
        Some(value) => {
            if let Some(preset) = detect_proxy_select_value(&value) {
                set_select_value(doc, DM_VOICE_PROXY_SELECT_ID, &preset);
                set_hidden(doc, DM_VOICE_PROXY_CUSTOM_WRAP_ID, true);
                set_input_value(doc, DM_VOICE_PROXY_INPUT_ID, "");
            } else {
                set_select_value(doc, DM_VOICE_PROXY_SELECT_ID, DM_VOICE_CUSTOM_VALUE);
                set_hidden(doc, DM_VOICE_PROXY_CUSTOM_WRAP_ID, false);
                set_input_value(doc, DM_VOICE_PROXY_INPUT_ID, &value);
            }
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn select_proxy_storage_value(doc: &web_sys::Document) -> Option<String> {
    let selected = get_select_value(doc, DM_VOICE_PROXY_SELECT_ID).unwrap_or_default();
    if selected == DM_VOICE_CUSTOM_VALUE {
        set_hidden(doc, DM_VOICE_PROXY_CUSTOM_WRAP_ID, false);
        return get_input_value(doc, DM_VOICE_PROXY_INPUT_ID);
    }
    set_hidden(doc, DM_VOICE_PROXY_CUSTOM_WRAP_ID, true);
    resolve_proxy_url_from_select(&selected)
}

#[cfg(target_arch = "wasm32")]
fn select_storage_value(
    doc: &web_sys::Document,
    select_id: &str,
    custom_wrap_id: &str,
    custom_input_id: &str,
) -> Option<String> {
    let selected = get_select_value(doc, select_id).unwrap_or_default();
    if selected == DM_VOICE_CUSTOM_VALUE {
        set_hidden(doc, custom_wrap_id, false);
        return get_input_value(doc, custom_input_id);
    }
    set_hidden(doc, custom_wrap_id, true);
    if selected == DM_VOICE_RANDOM_PRESET_VALUE && select_id == DM_VOICE_ID_SELECT_ID {
        return pick_random_voice_id();
    }
    Some(selected)
}

#[cfg(target_arch = "wasm32")]
fn is_model_preset(value: &str) -> bool {
    DM_VOICE_MODEL_PRESETS.iter().any(|preset| *preset == value)
}

#[cfg(target_arch = "wasm32")]
fn is_voice_id_preset(value: &str) -> bool {
    DM_VOICE_ID_PRESETS
        .iter()
        .any(|(preset, _name)| *preset == value)
}

#[cfg(target_arch = "wasm32")]
fn pick_random_voice_id() -> Option<String> {
    if DM_VOICE_ID_PRESETS.is_empty() {
        return None;
    }
    let index = (js_sys::Math::random() * DM_VOICE_ID_PRESETS.len() as f64).floor() as usize;
    let bounded = index.min(DM_VOICE_ID_PRESETS.len().saturating_sub(1));
    Some(DM_VOICE_ID_PRESETS[bounded].0.to_string())
}

#[cfg(target_arch = "wasm32")]
fn persist_storage_value(key: &str, value: Option<String>) {
    let Some(win) = web_sys::window() else {
        return;
    };
    let Ok(Some(storage)) = win.local_storage() else {
        return;
    };
    match value.and_then(|v| normalize_optional(&v)) {
        Some(v) => {
            let _ = storage.set_item(key, &v);
        }
        None => {
            let _ = storage.remove_item(key);
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn set_dm_voice_status(doc: &web_sys::Document, level_class: &str, message: &str) {
    if let Some(el) = doc.get_element_by_id(DM_VOICE_STATUS_ID) {
        el.set_class_name(&format!("turn-control-gate {}", level_class));
        el.set_text_content(Some(message));
    }
}

#[cfg(target_arch = "wasm32")]
fn hydrate_dm_voice_controls(doc: &web_sys::Document) {
    set_select_value(
        doc,
        DM_VOICE_MODE_SELECT_ID,
        dm_voice_mode_value(resolve_dm_voice_mode()),
    );
    hydrate_proxy_select(doc, resolve_dm_voice_proxy_url());
    hydrate_preset_select(
        doc,
        DM_VOICE_MODEL_SELECT_ID,
        DM_VOICE_MODEL_CUSTOM_WRAP_ID,
        DM_VOICE_MODEL_CUSTOM_INPUT_ID,
        resolve_dm_voice_model(),
        is_model_preset,
    );
    hydrate_preset_select(
        doc,
        DM_VOICE_ID_SELECT_ID,
        DM_VOICE_ID_CUSTOM_WRAP_ID,
        DM_VOICE_ID_CUSTOM_INPUT_ID,
        resolve_dm_voice_id(),
        is_voice_id_preset,
    );
}

#[cfg(target_arch = "wasm32")]
fn sync_custom_field_visibility(
    doc: &web_sys::Document,
    select_id: &str,
    custom_wrap_id: &str,
    custom_input_id: &str,
) {
    let is_custom = get_select_value(doc, select_id).as_deref() == Some(DM_VOICE_CUSTOM_VALUE);
    set_hidden(doc, custom_wrap_id, !is_custom);
    if !is_custom {
        set_input_value(doc, custom_input_id, "");
    }
}

#[cfg(target_arch = "wasm32")]
fn bind_custom_field_toggle(
    doc: &web_sys::Document,
    select_id: &str,
    custom_wrap_id: &str,
    custom_input_id: &str,
) {
    use wasm_bindgen::prelude::Closure;
    use wasm_bindgen::JsCast;

    let Some(select) = doc.get_element_by_id(select_id) else {
        return;
    };
    let attr = format!("data-toggle-bound-{}", select_id);
    if select.get_attribute(&attr).as_deref() == Some("1") {
        return;
    }
    let _ = select.set_attribute(&attr, "1");

    let select_id = select_id.to_string();
    let custom_wrap_id = custom_wrap_id.to_string();
    let custom_input_id = custom_input_id.to_string();

    let cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        sync_custom_field_visibility(&doc, &select_id, &custom_wrap_id, &custom_input_id);
    }) as Box<dyn FnMut()>);

    let _ = select.dyn_ref::<web_sys::EventTarget>().map(|target| {
        target.add_event_listener_with_callback("change", cb.as_ref().unchecked_ref())
    });
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn bind_dm_voice_save_button(doc: &web_sys::Document) {
    use wasm_bindgen::prelude::Closure;
    use wasm_bindgen::JsCast;

    let Some(button) = doc.get_element_by_id(DM_VOICE_SAVE_BUTTON_ID) else {
        return;
    };
    if button.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = button.set_attribute("data-bound", "1");

    let cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let mode = get_select_value(&doc, DM_VOICE_MODE_SELECT_ID)
            .map(|raw| parse_dm_voice_mode(&raw))
            .unwrap_or(DmVoiceMode::Browser);
        let proxy_url = select_proxy_storage_value(&doc);
        let voice_model = select_storage_value(
            &doc,
            DM_VOICE_MODEL_SELECT_ID,
            DM_VOICE_MODEL_CUSTOM_WRAP_ID,
            DM_VOICE_MODEL_CUSTOM_INPUT_ID,
        );
        let voice_id = select_storage_value(
            &doc,
            DM_VOICE_ID_SELECT_ID,
            DM_VOICE_ID_CUSTOM_WRAP_ID,
            DM_VOICE_ID_CUSTOM_INPUT_ID,
        );

        persist_storage_value(
            STORAGE_DM_VOICE_MODE,
            Some(dm_voice_mode_value(mode).to_string()),
        );
        persist_storage_value(STORAGE_DM_VOICE_PROXY_URL, proxy_url);
        persist_storage_value(STORAGE_DM_VOICE_MODEL, voice_model);
        persist_storage_value(STORAGE_DM_VOICE_ID, voice_id.clone());

        if get_select_value(&doc, DM_VOICE_ID_SELECT_ID).as_deref()
            == Some(DM_VOICE_RANDOM_PRESET_VALUE)
        {
            if let Some(selected_id) = voice_id.and_then(|v| normalize_optional(&v)) {
                set_dm_voice_status(
                    &doc,
                    "status-ok",
                    &format!(
                        "DM 음성 설정 저장 완료. {}: {}",
                        DM_VOICE_RANDOM_PRESET_LABEL, selected_id
                    ),
                );
            } else {
                set_dm_voice_status(&doc, "status-ok", "DM 음성 설정을 저장했습니다.");
            }
        } else {
            set_dm_voice_status(&doc, "status-ok", "DM 음성 설정을 저장했습니다.");
        }
    }) as Box<dyn FnMut()>);

    let _ = button.dyn_ref::<web_sys::EventTarget>().map(|target| {
        target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
    });
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn bind_dm_voice_preview_button(doc: &web_sys::Document) {
    use wasm_bindgen::prelude::Closure;
    use wasm_bindgen::JsCast;

    let Some(button) = doc.get_element_by_id(DM_VOICE_PREVIEW_BUTTON_ID) else {
        return;
    };
    if button.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = button.set_attribute("data-bound", "1");

    let cb = Closure::wrap(Box::new(move || {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let mode = get_select_value(&doc, DM_VOICE_MODE_SELECT_ID)
            .map(|raw| parse_dm_voice_mode(&raw))
            .unwrap_or(DmVoiceMode::Browser);
        let proxy_url = select_proxy_storage_value(&doc);
        let voice_model = select_storage_value(
            &doc,
            DM_VOICE_MODEL_SELECT_ID,
            DM_VOICE_MODEL_CUSTOM_WRAP_ID,
            DM_VOICE_MODEL_CUSTOM_INPUT_ID,
        );
        let voice_id = select_storage_value(
            &doc,
            DM_VOICE_ID_SELECT_ID,
            DM_VOICE_ID_CUSTOM_WRAP_ID,
            DM_VOICE_ID_CUSTOM_INPUT_ID,
        );

        match mode {
            DmVoiceMode::Off => {
                set_dm_voice_status(
                    &doc,
                    "status-warn",
                    "미리듣기는 OFF 모드에서 동작하지 않습니다. Browser 또는 ElevenLabs를 선택하세요.",
                );
            }
            DmVoiceMode::Browser => {
                speak_with_browser(DM_VOICE_PREVIEW_TEXT);
                set_dm_voice_status(&doc, "status-ok", "Browser TTS 미리듣기를 재생했습니다.");
            }
            DmVoiceMode::ElevenLabs => {
                let Some(proxy_url) = proxy_url else {
                    set_dm_voice_status(
                        &doc,
                        "status-warn",
                        "ElevenLabs 미리듣기에는 Proxy URL이 필요합니다.",
                    );
                    return;
                };
                speak_with_proxy(
                    proxy_url,
                    DM_VOICE_PREVIEW_TEXT.to_string(),
                    crate::config::current_room_id(),
                    "dm_narration".to_string(),
                    0,
                    voice_model.clone(),
                    voice_id.clone(),
                );

                let model_label = voice_model.unwrap_or_else(|| "auto".to_string());
                let voice_label = voice_id.unwrap_or_else(|| "auto".to_string());
                set_dm_voice_status(
                    &doc,
                    "status-info",
                    &format!(
                        "ElevenLabs 미리듣기 요청 전송 (model: {}, voice_id: {})",
                        model_label, voice_label
                    ),
                );
            }
        }
    }) as Box<dyn FnMut()>);

    let _ = button.dyn_ref::<web_sys::EventTarget>().map(|target| {
        target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
    });
    cb.forget();
}

#[cfg(target_arch = "wasm32")]
fn bind_dm_voice_controls_impl() {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(panel) = doc.get_element_by_id(DM_VOICE_PANEL_ID) else {
        return;
    };
    if panel.get_attribute("data-bound").as_deref() == Some("1") {
        return;
    }
    let _ = panel.set_attribute("data-bound", "1");

    hydrate_dm_voice_controls(&doc);
    bind_custom_field_toggle(
        &doc,
        DM_VOICE_PROXY_SELECT_ID,
        DM_VOICE_PROXY_CUSTOM_WRAP_ID,
        DM_VOICE_PROXY_INPUT_ID,
    );
    bind_custom_field_toggle(
        &doc,
        DM_VOICE_MODEL_SELECT_ID,
        DM_VOICE_MODEL_CUSTOM_WRAP_ID,
        DM_VOICE_MODEL_CUSTOM_INPUT_ID,
    );
    bind_custom_field_toggle(
        &doc,
        DM_VOICE_ID_SELECT_ID,
        DM_VOICE_ID_CUSTOM_WRAP_ID,
        DM_VOICE_ID_CUSTOM_INPUT_ID,
    );
    sync_custom_field_visibility(
        &doc,
        DM_VOICE_PROXY_SELECT_ID,
        DM_VOICE_PROXY_CUSTOM_WRAP_ID,
        DM_VOICE_PROXY_INPUT_ID,
    );
    sync_custom_field_visibility(
        &doc,
        DM_VOICE_MODEL_SELECT_ID,
        DM_VOICE_MODEL_CUSTOM_WRAP_ID,
        DM_VOICE_MODEL_CUSTOM_INPUT_ID,
    );
    sync_custom_field_visibility(
        &doc,
        DM_VOICE_ID_SELECT_ID,
        DM_VOICE_ID_CUSTOM_WRAP_ID,
        DM_VOICE_ID_CUSTOM_INPUT_ID,
    );
    bind_dm_voice_save_button(&doc);
    bind_dm_voice_preview_button(&doc);
    set_dm_voice_status(
        &doc,
        "status-info",
        "DM 음성은 세션 진행 중일 때만 재생됩니다.",
    );
}

#[cfg(target_arch = "wasm32")]
fn parse_query_param(search: &str, key: &str) -> Option<String> {
    let search = search.trim_start_matches('?');
    for pair in search.split('&') {
        let mut parts = pair.splitn(2, '=');
        if let Some(k) = parts.next() {
            if k == key {
                return parts.next().map(|v| v.to_string());
            }
        }
    }
    None
}

#[cfg(target_arch = "wasm32")]
fn global_string(win: &web_sys::Window, key: &str) -> Option<String> {
    let value = js_sys::Reflect::get(win.as_ref(), &wasm_bindgen::JsValue::from_str(key)).ok()?;
    value.as_string()
}

#[cfg(target_arch = "wasm32")]
fn speak_with_browser(text: &str) {
    let Some(win) = web_sys::window() else {
        return;
    };
    let Ok(synth) = win.speech_synthesis() else {
        return;
    };
    let Ok(utterance) = web_sys::SpeechSynthesisUtterance::new_with_text(text) else {
        return;
    };
    utterance.set_lang("ko-KR");
    utterance.set_rate(1.0);
    utterance.set_pitch(1.0);
    synth.cancel();
    synth.speak(&utterance);
}

#[cfg(target_arch = "wasm32")]
fn speak_with_proxy(
    proxy_url: String,
    text: String,
    room_id: String,
    phase: String,
    turn: u32,
    voice_model: Option<String>,
    voice_id: Option<String>,
) {
    wasm_bindgen_futures::spawn_local(async move {
        if let Err(err) = speak_with_proxy_inner(
            proxy_url,
            text.clone(),
            room_id,
            phase,
            turn,
            voice_model,
            voice_id,
        )
        .await
        {
            log::warn!("dm voice proxy failed, fallback to browser speech: {}", err);
            speak_with_browser(&text);
        }
    });
}

#[cfg(target_arch = "wasm32")]
async fn speak_with_proxy_inner(
    proxy_url: String,
    text: String,
    room_id: String,
    phase: String,
    turn: u32,
    voice_model: Option<String>,
    voice_id: Option<String>,
) -> Result<(), String> {
    use wasm_bindgen::JsCast;
    use wasm_bindgen_futures::JsFuture;

    let Some(win) = web_sys::window() else {
        return Err("window unavailable".to_string());
    };

    let mut body_json = serde_json::json!({
        "text": text,
        "speaker": "dm",
        "phase": phase,
        "room_id": room_id,
        "turn": turn,
    });
    if let Some(model) = voice_model.and_then(|v| normalize_optional(&v)) {
        body_json["voice_model"] = serde_json::Value::String(model);
    }
    if let Some(id) = voice_id.and_then(|v| normalize_optional(&v)) {
        body_json["voice_id"] = serde_json::Value::String(id);
    }
    let body = body_json.to_string();

    let init = web_sys::RequestInit::new();
    init.set_method("POST");
    init.set_mode(web_sys::RequestMode::Cors);
    init.set_body(&wasm_bindgen::JsValue::from_str(&body));

    let request = web_sys::Request::new_with_str_and_init(&proxy_url, &init)
        .map_err(|_| "failed to create request".to_string())?;
    request
        .headers()
        .set("content-type", "application/json")
        .map_err(|_| "failed to set content-type header".to_string())?;

    let resp_value = JsFuture::from(win.fetch_with_request(&request))
        .await
        .map_err(|_| "fetch failed".to_string())?;
    let response: web_sys::Response = resp_value
        .dyn_into()
        .map_err(|_| "response cast failed".to_string())?;

    if !response.ok() {
        return Err(format!("proxy HTTP {}", response.status()));
    }

    let content_type = response
        .headers()
        .get("content-type")
        .ok()
        .flatten()
        .unwrap_or_default()
        .to_ascii_lowercase();

    if content_type.contains("application/json") {
        let json = JsFuture::from(
            response
                .json()
                .map_err(|_| "failed to decode json response".to_string())?,
        )
        .await
        .map_err(|_| "json parse failed".to_string())?;
        if let Some(src) = extract_audio_source_from_json(&json) {
            play_audio_source(&src, None)?;
            return Ok(());
        }
        return Err("json response has no playable audio source".to_string());
    }

    if content_type.starts_with("audio/") {
        let blob = JsFuture::from(
            response
                .blob()
                .map_err(|_| "failed to read audio blob".to_string())?,
        )
        .await
        .map_err(|_| "blob parse failed".to_string())?;
        let blob: web_sys::Blob = blob
            .dyn_into()
            .map_err(|_| "blob cast failed".to_string())?;
        let object_url = web_sys::Url::create_object_url_with_blob(&blob)
            .map_err(|_| "failed to create blob object url".to_string())?;
        play_audio_source(&object_url, Some(object_url.clone()))?;
        return Ok(());
    }

    let text_resp = JsFuture::from(
        response
            .text()
            .map_err(|_| "failed to read text response".to_string())?,
    )
    .await
    .map_err(|_| "text parse failed".to_string())?;
    if let Some(raw) = text_resp.as_string() {
        if let Some(src) = normalize_audio_source_candidate(&raw) {
            play_audio_source(&src, None)?;
            return Ok(());
        }
    }

    Err("unsupported proxy response format".to_string())
}

#[cfg(target_arch = "wasm32")]
fn extract_audio_source_from_json(value: &wasm_bindgen::JsValue) -> Option<String> {
    let keys = [
        "audio_url",
        "audioUrl",
        "url",
        "signed_url",
        "signedUrl",
        "base64_audio",
        "audio_base64",
        "audioBase64",
    ];
    for key in keys {
        if let Some(src) = extract_string_field(value, key) {
            if key.contains("base64") {
                return Some(format!("data:audio/mpeg;base64,{}", src));
            }
            if let Some(normalized) = normalize_audio_source_candidate(&src) {
                return Some(normalized);
            }
        }
    }
    for nested in ["data", "payload", "result"] {
        if let Some(obj) = extract_js_field(value, nested) {
            if let Some(src) = extract_audio_source_from_json(&obj) {
                return Some(src);
            }
        }
    }
    None
}

#[cfg(target_arch = "wasm32")]
fn extract_string_field(value: &wasm_bindgen::JsValue, key: &str) -> Option<String> {
    let field = extract_js_field(value, key)?;
    let raw = field.as_string()?;
    Some(raw.trim().to_string())
}

#[cfg(target_arch = "wasm32")]
fn extract_js_field(value: &wasm_bindgen::JsValue, key: &str) -> Option<wasm_bindgen::JsValue> {
    js_sys::Reflect::get(value, &wasm_bindgen::JsValue::from_str(key)).ok()
}

#[cfg(target_arch = "wasm32")]
fn normalize_audio_source_candidate(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.starts_with("https://")
        || trimmed.starts_with("http://")
        || trimmed.starts_with("data:audio/")
        || trimmed.starts_with("blob:")
    {
        return Some(trimmed.to_string());
    }
    None
}

#[cfg(target_arch = "wasm32")]
fn track_active_audio(audio: &web_sys::HtmlAudioElement) {
    ACTIVE_DM_VOICE_AUDIO.with(|pool| {
        pool.borrow_mut().push(audio.clone());
    });
}

#[cfg(target_arch = "wasm32")]
fn untrack_active_audio(audio: &web_sys::HtmlAudioElement) {
    ACTIVE_DM_VOICE_AUDIO.with(|pool| {
        pool.borrow_mut()
            .retain(|item| !js_sys::Object::is(item.as_ref(), audio.as_ref()));
    });
}

#[cfg(target_arch = "wasm32")]
fn cleanup_audio_now(audio: &web_sys::HtmlAudioElement, cleanup_object_url: Option<&str>) {
    audio.set_onended(None);
    audio.set_onerror(None);
    audio.set_src("");
    if let Some(url) = cleanup_object_url {
        let _ = web_sys::Url::revoke_object_url(url);
    }
    untrack_active_audio(audio);
}

#[cfg(target_arch = "wasm32")]
fn bind_audio_cleanup_handlers(
    audio: &web_sys::HtmlAudioElement,
    cleanup_object_url: Option<String>,
) {
    use wasm_bindgen::JsCast;

    let on_end_audio = audio.clone();
    let on_end_cleanup = cleanup_object_url.clone();
    let on_end = wasm_bindgen::closure::Closure::once_into_js(move || {
        cleanup_audio_now(&on_end_audio, on_end_cleanup.as_deref());
    });
    audio.set_onended(Some(on_end.unchecked_ref::<js_sys::Function>()));

    let on_error_audio = audio.clone();
    let on_error = wasm_bindgen::closure::Closure::once_into_js(move || {
        cleanup_audio_now(&on_error_audio, cleanup_object_url.as_deref());
    });
    audio.set_onerror(Some(on_error.unchecked_ref::<js_sys::Function>()));
}

#[cfg(target_arch = "wasm32")]
fn play_audio_source(source: &str, cleanup_object_url: Option<String>) -> Result<(), String> {
    let audio = web_sys::HtmlAudioElement::new_with_src(source)
        .map_err(|_| "failed to create HtmlAudioElement".to_string())?;
    audio.set_preload("auto");
    track_active_audio(&audio);
    bind_audio_cleanup_handlers(&audio, cleanup_object_url.clone());
    if audio.play().is_err() {
        cleanup_audio_now(&audio, cleanup_object_url.as_deref());
        return Err("audio play failed".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::should_play_dm_voice;
    use crate::game::events::NarrativePayload;
    use crate::game::state::{RoomState, TurnPhase, TurnProgressState};

    fn payload(phase: &str, speaker: Option<&str>, text: &str) -> NarrativePayload {
        NarrativePayload {
            text: text.to_string(),
            phase: phase.to_string(),
            turn: 3,
            room_id: "adventure-room".to_string(),
            speaker: speaker.map(|s| s.to_string()),
        }
    }

    fn running_state() -> (RoomState, TurnProgressState) {
        let room = RoomState {
            id: "adventure-room".to_string(),
            status: "active".to_string(),
            turn: 3,
            phase: TurnPhase::DmNarration,
            current_scenario: "".to_string(),
            current_node: "".to_string(),
        };
        let progress = TurnProgressState::default();
        (room, progress)
    }

    #[test]
    fn dm_voice_requires_running_lifecycle() {
        let (mut room, progress) = running_state();
        room.status = "ended".to_string();
        assert!(!should_play_dm_voice(
            &payload("dm_narration", Some("dm"), "테스트"),
            "테스트",
            &room,
            &progress
        ));
    }

    #[test]
    fn dm_voice_accepts_dm_phase_during_running() {
        let (room, progress) = running_state();
        assert!(should_play_dm_voice(
            &payload("dm_narration", None, "짙은 안개가 깔린다."),
            "짙은 안개가 깔린다.",
            &room,
            &progress
        ));
    }

    #[test]
    fn dm_voice_skips_non_dm_events() {
        let (room, progress) = running_state();
        assert!(!should_play_dm_voice(
            &payload("action_declaration", Some("luna"), "플레이어 행동"),
            "플레이어 행동",
            &room,
            &progress
        ));
    }
}

#[cfg(target_arch = "wasm32")]
use bevy::prelude::DetectChanges;
use bevy::prelude::Res;

use crate::game::events::NarrativePayload;
use crate::game::lifecycle::TrpgLifecycleState;
use crate::game::state::{WorkspaceState, TurnProgressState};

#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DmVoiceMode {
    Off,
    Browser,
    ElevenLabs,
}

#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DmVoiceTone {
    Auto,
    Excited,
    Dramatic,
    Calm,
    Neutral,
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
const STORAGE_DM_VOICE_TONE: &str = "trpg_dm_voice_tone";

#[cfg(target_arch = "wasm32")]
const DM_VOICE_PANEL_ID: &str = "dm-voice-config";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_MODE_SELECT_ID: &str = "dm-voice-mode-select";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_TONE_SELECT_ID: &str = "dm-voice-tone-select";
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
const DM_VOICE_DEFAULT_PROXY_URL: &str = "/api/v1/trpg/tts";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_DEFAULT_MODEL: &str = "eleven_multilingual_v2";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_DEFAULT_VOICE_ID: &str = "21m00Tcm4TlvDq8ikWAM";
#[cfg(target_arch = "wasm32")]
const DM_VOICE_MODEL_PRESETS: &[&str] = &[
    "eleven_turbo_v2_5",
    "eleven_flash_v2_5",
    "eleven_multilingual_v2",
];
#[cfg(target_arch = "wasm32")]
const DM_VOICE_PROXY_ORIGIN_PRESETS: &[&str] = &["/api/v1/trpg/tts", "/api/v1/tts", "/tts"];
#[cfg(target_arch = "wasm32")]
const DM_VOICE_PROXY_REMOTE_PRESETS: &[&str] = &[DM_VOICE_DEFAULT_PROXY_URL];
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
struct ActiveDmVoiceAudio {
    audio: web_sys::HtmlAudioElement,
    cleanup_object_url: Option<String>,
}

#[cfg(target_arch = "wasm32")]
#[derive(Debug, Clone, serde::Deserialize)]
struct RuntimeVoiceConfigResponse {
    tts: Option<RuntimeVoiceTtsConfig>,
}

#[cfg(target_arch = "wasm32")]
#[derive(Debug, Clone, serde::Deserialize)]
struct RuntimeVoiceTtsConfig {
    preview_url: Option<String>,
    default_model: Option<String>,
    default_voice: Option<String>,
    available_models: Option<Vec<String>>,
    available_voices: Option<Vec<String>>,
}

#[cfg(target_arch = "wasm32")]
thread_local! {
    static ACTIVE_DM_VOICE_AUDIO: std::cell::RefCell<Vec<ActiveDmVoiceAudio>> =
        std::cell::RefCell::new(Vec::new());
}

#[cfg(target_arch = "wasm32")]
#[derive(Debug, Clone, Copy)]
struct DmVoiceStyleProfile {
    rate: f32,
    pitch: f32,
    energy: f32,
    stability: f32,
    similarity_boost: f32,
    style: f32,
    tone_tag: &'static str,
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

fn is_workspace_running(workspace_state: &WorkspaceState, progress: &TurnProgressState) -> bool {
    TrpgLifecycleState::from_workspace_progress(&workspace_state.status, &progress.workspace_status)
        .accepts_player_input()
}

fn should_play_dm_voice(
    payload: &NarrativePayload,
    clean_text: &str,
    workspace_state: &WorkspaceState,
    progress: &TurnProgressState,
) -> bool {
    if clean_text.trim().is_empty() {
        return false;
    }
    if !is_workspace_running(workspace_state, progress) {
        return false;
    }
    is_dm_phase(&payload.phase) || is_dm_speaker(payload.speaker.as_deref())
}

pub fn maybe_play_dm_voice(
    payload: &NarrativePayload,
    clean_text: &str,
    workspace_state: &WorkspaceState,
    progress: &TurnProgressState,
) {
    if should_play_dm_voice(payload, clean_text, workspace_state, progress) {
        #[cfg(target_arch = "wasm32")]
        {
            dispatch_voice(payload, clean_text, workspace_state);
        }
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
        stop_all_active_audio();
        if let Some(doc) = web_sys::window().and_then(|w| w.document()) {
            set_dm_voice_status(
                &doc,
                "status-info",
                "DM 음성은 세션 진행 중일 때만 재생됩니다.",
            );
        }
    }
}

pub fn sync_dm_voice_controls(workspace_state: Res<WorkspaceState>, progress: Res<TurnProgressState>) {
    #[cfg(not(target_arch = "wasm32"))]
    let _ = (&workspace_state, &progress);

    #[cfg(target_arch = "wasm32")]
    {
        if !workspace_state.is_changed() && !progress.is_changed() {
            return;
        }

        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        if doc.get_element_by_id(DM_VOICE_STATUS_ID).is_none() {
            return;
        }

        let mode = resolve_dm_voice_mode();
        let tone = resolve_dm_voice_tone();
        let running = is_workspace_running(&workspace_state, &progress);
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
                    &format!(
                        "진행 중: Browser TTS로 DM 내레이션 재생 (tone: {}).",
                        dm_voice_tone_label(tone)
                    ),
                );
            }
            (true, DmVoiceMode::ElevenLabs) => {
                let model = resolve_dm_voice_model().unwrap_or_else(|| "-".to_string());
                let voice_id = resolve_dm_voice_id().unwrap_or_else(|| "-".to_string());
                set_dm_voice_status(
                    &doc,
                    "status-ok",
                    &format!(
                        "진행 중: voice proxy 사용 (model: {}, voice: {}, tone: {})",
                        model,
                        voice_id,
                        dm_voice_tone_label(tone)
                    ),
                );
            }
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn dispatch_voice(payload: &NarrativePayload, clean_text: &str, workspace_state: &WorkspaceState) {
    let text = clean_text.trim().to_string();
    if text.is_empty() {
        return;
    }
    let workspace_id = if workspace_state.id.trim().is_empty() {
        crate::config::current_workspace_id()
    } else {
        workspace_state.id.trim().to_string()
    };
    let phase = payload.phase.trim().to_string();
    let turn = payload.turn;
    let speaker = payload.speaker.clone();
    let tone = resolve_dm_voice_tone();
    let voice_model = resolve_dm_voice_model();
    let voice_id = resolve_dm_voice_id();

    match resolve_dm_voice_mode() {
        DmVoiceMode::Off => {}
        DmVoiceMode::Browser => {
            speak_with_browser(&text, &phase, speaker.as_deref(), tone);
        }
        DmVoiceMode::ElevenLabs => {
            if let Some(proxy_url) = resolve_dm_voice_proxy_url() {
                speak_with_proxy(
                    proxy_url,
                    text,
                    workspace_id,
                    phase,
                    turn,
                    speaker,
                    tone,
                    voice_model,
                    voice_id,
                );
            } else {
                speak_with_browser(&text, &phase, speaker.as_deref(), tone);
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
fn parse_dm_voice_tone(raw: &str) -> DmVoiceTone {
    match raw.trim().to_ascii_lowercase().as_str() {
        "excited" | "hyped" | "energetic" => DmVoiceTone::Excited,
        "dramatic" | "cinematic" => DmVoiceTone::Dramatic,
        "calm" | "soft" => DmVoiceTone::Calm,
        "neutral" | "normal" => DmVoiceTone::Neutral,
        _ => DmVoiceTone::Auto,
    }
}

#[cfg(target_arch = "wasm32")]
fn dm_voice_tone_value(tone: DmVoiceTone) -> &'static str {
    match tone {
        DmVoiceTone::Auto => "auto",
        DmVoiceTone::Excited => "excited",
        DmVoiceTone::Dramatic => "dramatic",
        DmVoiceTone::Calm => "calm",
        DmVoiceTone::Neutral => "neutral",
    }
}

#[cfg(target_arch = "wasm32")]
fn dm_voice_tone_label(tone: DmVoiceTone) -> &'static str {
    match tone {
        DmVoiceTone::Auto => "auto",
        DmVoiceTone::Excited => "excited",
        DmVoiceTone::Dramatic => "dramatic",
        DmVoiceTone::Calm => "calm",
        DmVoiceTone::Neutral => "neutral",
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
    .unwrap_or_else(|| {
        if resolve_dm_voice_proxy_url().is_some() {
            DmVoiceMode::ElevenLabs
        } else {
            DmVoiceMode::Browser
        }
    })
}

#[cfg(target_arch = "wasm32")]
fn resolve_dm_voice_tone() -> DmVoiceTone {
    resolve_string_setting(
        &["__TRPG_DM_VOICE_TONE", "__DM_VOICE_TONE"],
        &["dm_voice_tone"],
        STORAGE_DM_VOICE_TONE,
        "meta[name='trpg-dm-voice-tone']",
    )
    .map(|raw| parse_dm_voice_tone(&raw))
    .unwrap_or(DmVoiceTone::Auto)
}

#[cfg(target_arch = "wasm32")]
fn speaker_variation(speaker: Option<&str>) -> f32 {
    let Some(raw) = speaker else {
        return 0.0;
    };
    let s = raw.trim();
    if s.is_empty() {
        return 0.0;
    }
    let mut hash: u32 = 2166136261;
    for b in s.as_bytes() {
        hash ^= *b as u32;
        hash = hash.wrapping_mul(16777619);
    }
    let bucket = (hash % 21) as i32 - 10;
    bucket as f32 * 0.006
}

#[cfg(target_arch = "wasm32")]
fn resolved_auto_tone(phase: &str, speaker: Option<&str>) -> DmVoiceTone {
    let normalized_phase = normalize_phase(phase);
    if normalized_phase.contains("combat")
        || normalized_phase.contains("action")
        || normalized_phase.contains("dice")
    {
        return DmVoiceTone::Excited;
    }
    if is_dm_speaker(speaker) || normalized_phase.contains("briefing") {
        return DmVoiceTone::Dramatic;
    }
    DmVoiceTone::Neutral
}

#[cfg(target_arch = "wasm32")]
fn style_profile_for(phase: &str, speaker: Option<&str>, tone: DmVoiceTone) -> DmVoiceStyleProfile {
    let effective = match tone {
        DmVoiceTone::Auto => resolved_auto_tone(phase, speaker),
        other => other,
    };
    let mut profile = match effective {
        DmVoiceTone::Excited => DmVoiceStyleProfile {
            rate: 1.12,
            pitch: 1.18,
            energy: 0.96,
            stability: 0.38,
            similarity_boost: 0.72,
            style: 0.86,
            tone_tag: "excited",
        },
        DmVoiceTone::Dramatic => DmVoiceStyleProfile {
            rate: 1.03,
            pitch: 1.10,
            energy: 0.80,
            stability: 0.44,
            similarity_boost: 0.76,
            style: 0.70,
            tone_tag: "dramatic",
        },
        DmVoiceTone::Calm => DmVoiceStyleProfile {
            rate: 0.94,
            pitch: 0.96,
            energy: 0.52,
            stability: 0.62,
            similarity_boost: 0.68,
            style: 0.35,
            tone_tag: "calm",
        },
        DmVoiceTone::Neutral | DmVoiceTone::Auto => DmVoiceStyleProfile {
            rate: 1.0,
            pitch: 1.0,
            energy: 0.65,
            stability: 0.50,
            similarity_boost: 0.75,
            style: 0.50,
            tone_tag: "neutral",
        },
    };
    let delta = speaker_variation(speaker);
    profile.rate = (profile.rate + delta * 0.8).clamp(0.85, 1.28);
    profile.pitch = (profile.pitch + delta).clamp(0.82, 1.35);
    profile
}

#[cfg(target_arch = "wasm32")]
fn resolve_dm_voice_proxy_url() -> Option<String> {
    resolve_string_setting(
        &["__TRPG_DM_VOICE_PROXY_URL", "__ELEVENLABS_PROXY_URL"],
        &["dm_voice_proxy_url", "elevenlabs_proxy_url"],
        STORAGE_DM_VOICE_PROXY_URL,
        "meta[name='trpg-dm-voice-proxy-url']",
    )
    .or_else(|| Some(DM_VOICE_DEFAULT_PROXY_URL.to_string()))
}

#[cfg(target_arch = "wasm32")]
fn resolve_dm_voice_model() -> Option<String> {
    resolve_string_setting(
        &["__TRPG_DM_VOICE_MODEL", "__ELEVENLABS_MODEL"],
        &["dm_voice_model", "elevenlabs_model"],
        STORAGE_DM_VOICE_MODEL,
        "meta[name='trpg-dm-voice-model']",
    )
    .or_else(|| Some(DM_VOICE_DEFAULT_MODEL.to_string()))
}

#[cfg(target_arch = "wasm32")]
fn resolve_dm_voice_id() -> Option<String> {
    resolve_string_setting(
        &["__TRPG_DM_VOICE_ID", "__ELEVENLABS_VOICE_ID"],
        &["dm_voice_id", "dm_voice_voice_id", "elevenlabs_voice_id"],
        STORAGE_DM_VOICE_ID,
        "meta[name='trpg-dm-voice-id']",
    )
    .or_else(|| Some(DM_VOICE_DEFAULT_VOICE_ID.to_string()))
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
fn is_openai_tts_proxy_url(proxy_url: &str) -> bool {
    let normalized = proxy_url.trim().to_ascii_lowercase();
    normalized.contains("/v1/audio/speech")
}

#[cfg(target_arch = "wasm32")]
fn detect_proxy_select_value(current_url: &str) -> Option<String> {
    let current = normalize_optional(current_url)?;
    for preset in DM_VOICE_PROXY_REMOTE_PRESETS {
        if current == *preset {
            return Some(proxy_origin_value(preset));
        }
    }
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
) {
    match current_value.and_then(|v| normalize_optional(&v)) {
        None => {
            set_select_value(doc, select_id, "");
            set_hidden(doc, custom_wrap_id, true);
            set_input_value(doc, custom_input_id, "");
        }
        Some(value) if select_has_option_value(doc, select_id, &value) => {
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
        return pick_random_voice_id(doc);
    }
    Some(selected)
}

#[cfg(target_arch = "wasm32")]
fn select_has_option_value(doc: &web_sys::Document, select_id: &str, value: &str) -> bool {
    use wasm_bindgen::JsCast;

    let Some(select) = doc
        .get_element_by_id(select_id)
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
    else {
        return false;
    };

    let options = select.options();
    for index in 0..options.length() {
        let Some(option) = options
            .item(index)
            .and_then(|node| node.dyn_into::<web_sys::HtmlOptionElement>().ok())
        else {
            continue;
        };
        if option.value() == value {
            return true;
        }
    }
    false
}

#[cfg(target_arch = "wasm32")]
fn pick_random_voice_id(doc: &web_sys::Document) -> Option<String> {
    use wasm_bindgen::JsCast;

    let select = doc
        .get_element_by_id(DM_VOICE_ID_SELECT_ID)
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())?;
    let options = select.options();
    let mut values = Vec::new();
    for index in 0..options.length() {
        let Some(option) = options
            .item(index)
            .and_then(|node| node.dyn_into::<web_sys::HtmlOptionElement>().ok())
        else {
            continue;
        };
        let value = option.value();
        if value.is_empty() || value == DM_VOICE_RANDOM_PRESET_VALUE || value == DM_VOICE_CUSTOM_VALUE
        {
            continue;
        }
        values.push(value);
    }
    if values.is_empty() {
        return None;
    }
    let index = (js_sys::Math::random() * values.len() as f64).floor() as usize;
    let bounded = index.min(values.len().saturating_sub(1));
    values.get(bounded).cloned()
}

#[cfg(target_arch = "wasm32")]
fn rebuild_select_options(
    doc: &web_sys::Document,
    select_id: &str,
    options: &[(String, String)],
    include_random: bool,
) {
    use wasm_bindgen::JsCast;

    let Some(select) = doc
        .get_element_by_id(select_id)
        .and_then(|el| el.dyn_into::<web_sys::HtmlSelectElement>().ok())
    else {
        return;
    };

    select.set_inner_html("");

    let mut append_option = |value: &str, label: &str| {
        let Ok(option) = doc.create_element("option") else {
            return;
        };
        let Ok(option) = option.dyn_into::<web_sys::HtmlOptionElement>() else {
            return;
        };
        option.set_value(value);
        option.set_text(label);
        let _ = select.append_child(&option);
    };

    append_option("", "자동 (프록시 기본값)");
    if include_random {
        append_option(DM_VOICE_RANDOM_PRESET_VALUE, DM_VOICE_RANDOM_PRESET_LABEL);
    }
    for (value, label) in options {
        append_option(value, label);
    }
    append_option(DM_VOICE_CUSTOM_VALUE, "직접 입력");
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
fn storage_value(key: &str) -> Option<String> {
    let win = web_sys::window()?;
    let storage = win.local_storage().ok()??;
    storage.get_item(key).ok()?
}

#[cfg(target_arch = "wasm32")]
fn apply_runtime_voice_config(doc: &web_sys::Document, config: RuntimeVoiceConfigResponse) {
    let Some(tts) = config.tts else {
        return;
    };

    if let Some(models) = tts.available_models.as_ref() {
        let model_options: Vec<(String, String)> = models
            .iter()
            .filter_map(|value| normalize_optional(value).map(|v| (v.clone(), v)))
            .collect();
        if !model_options.is_empty() {
            rebuild_select_options(doc, DM_VOICE_MODEL_SELECT_ID, &model_options, false);
        }
    }

    if let Some(voices) = tts.available_voices.as_ref() {
        let voice_options: Vec<(String, String)> = voices
            .iter()
            .filter_map(|value| normalize_optional(value).map(|v| (v.clone(), v)))
            .collect();
        if !voice_options.is_empty() {
            rebuild_select_options(doc, DM_VOICE_ID_SELECT_ID, &voice_options, true);
        }
    }

    if storage_value(STORAGE_DM_VOICE_PROXY_URL).is_none() {
        persist_storage_value(STORAGE_DM_VOICE_PROXY_URL, tts.preview_url);
    }
    if storage_value(STORAGE_DM_VOICE_MODEL).is_none() {
        persist_storage_value(STORAGE_DM_VOICE_MODEL, tts.default_model);
    }
    if storage_value(STORAGE_DM_VOICE_ID).is_none() {
        persist_storage_value(STORAGE_DM_VOICE_ID, tts.default_voice);
    }

    hydrate_dm_voice_controls(doc);
    sync_custom_field_visibility(
        doc,
        DM_VOICE_MODEL_SELECT_ID,
        DM_VOICE_MODEL_CUSTOM_WRAP_ID,
        DM_VOICE_MODEL_CUSTOM_INPUT_ID,
    );
    sync_custom_field_visibility(
        doc,
        DM_VOICE_ID_SELECT_ID,
        DM_VOICE_ID_CUSTOM_WRAP_ID,
        DM_VOICE_ID_CUSTOM_INPUT_ID,
    );
}

#[cfg(target_arch = "wasm32")]
fn fetch_runtime_voice_config(doc: web_sys::Document) {
    use wasm_bindgen::JsCast;
    use wasm_bindgen_futures::JsFuture;

    wasm_bindgen_futures::spawn_local(async move {
        let Some(win) = web_sys::window() else {
            return;
        };
        let Ok(resp_value) =
            JsFuture::from(win.fetch_with_str("/api/v1/voice/config")).await
        else {
            return;
        };
        let Ok(response) = resp_value.dyn_into::<web_sys::Response>() else {
            return;
        };
        if !response.ok() {
            return;
        }
        let Ok(text_promise) = response.text() else {
            return;
        };
        let Ok(text_value) = JsFuture::from(text_promise).await else {
            return;
        };
        let Some(text) = text_value.as_string() else {
            return;
        };
        let Ok(config) = serde_json::from_str::<RuntimeVoiceConfigResponse>(&text) else {
            return;
        };
        apply_runtime_voice_config(&doc, config);
    });
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
    set_select_value(
        doc,
        DM_VOICE_TONE_SELECT_ID,
        dm_voice_tone_value(resolve_dm_voice_tone()),
    );
    hydrate_proxy_select(doc, resolve_dm_voice_proxy_url());
    hydrate_preset_select(
        doc,
        DM_VOICE_MODEL_SELECT_ID,
        DM_VOICE_MODEL_CUSTOM_WRAP_ID,
        DM_VOICE_MODEL_CUSTOM_INPUT_ID,
        resolve_dm_voice_model(),
    );
    hydrate_preset_select(
        doc,
        DM_VOICE_ID_SELECT_ID,
        DM_VOICE_ID_CUSTOM_WRAP_ID,
        DM_VOICE_ID_CUSTOM_INPUT_ID,
        resolve_dm_voice_id(),
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
        let tone = get_select_value(&doc, DM_VOICE_TONE_SELECT_ID)
            .map(|raw| parse_dm_voice_tone(&raw))
            .unwrap_or(DmVoiceTone::Auto);
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
        persist_storage_value(
            STORAGE_DM_VOICE_TONE,
            Some(dm_voice_tone_value(tone).to_string()),
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
        let tone = get_select_value(&doc, DM_VOICE_TONE_SELECT_ID)
            .map(|raw| parse_dm_voice_tone(&raw))
            .unwrap_or(DmVoiceTone::Auto);
        let proxy_url = select_proxy_storage_value(&doc);
        let effective_mode = match mode {
            DmVoiceMode::Browser if proxy_url.is_some() => DmVoiceMode::ElevenLabs,
            _ => mode,
        };
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

        match effective_mode {
            DmVoiceMode::Off => {
                set_dm_voice_status(
                    &doc,
                    "status-warn",
                    "미리듣기는 OFF 모드에서 동작하지 않습니다. Browser 또는 ElevenLabs를 선택하세요.",
                );
            }
            DmVoiceMode::Browser => {
                set_dm_voice_status(
                    &doc,
                    "status-ok",
                    "Browser TTS 모드로 미리듣기를 재생했습니다.",
                );
                speak_with_browser(DM_VOICE_PREVIEW_TEXT, "dm_narration", Some("dm"), tone);
            }
            DmVoiceMode::ElevenLabs => {
                let model_label = voice_model.as_deref().unwrap_or("auto").to_string();
                let voice_label = voice_id.as_deref().unwrap_or("auto").to_string();
                let Some(proxy_url) = proxy_url else {
                    set_dm_voice_status(
                        &doc,
                        "status-warn",
                        "ElevenLabs 미리듣기에는 Proxy URL이 필요합니다.",
                    );
                    return;
                };
                speak_with_proxy_preview(
                    proxy_url,
                    DM_VOICE_PREVIEW_TEXT.to_string(),
                    crate::config::current_workspace_id(),
                    "dm_narration".to_string(),
                    0,
                    Some("dm".to_string()),
                    tone,
                    voice_model,
                    voice_id,
                );

                set_dm_voice_status(
                    &doc,
                    "status-info",
                    &format!(
                        "Voice 미리듣기 요청 전송 (model: {}, voice: {}, tone: {})",
                        model_label,
                        voice_label,
                        dm_voice_tone_label(tone)
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
    fetch_runtime_voice_config(doc);
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
fn speak_with_browser(text: &str, phase: &str, speaker: Option<&str>, tone: DmVoiceTone) {
    let Some(win) = web_sys::window() else {
        return;
    };
    let Ok(synth) = win.speech_synthesis() else {
        return;
    };
    let Ok(utterance) = web_sys::SpeechSynthesisUtterance::new_with_text(text) else {
        return;
    };
    let profile = style_profile_for(phase, speaker, tone);
    utterance.set_lang("ko-KR");
    utterance.set_rate(profile.rate);
    utterance.set_pitch(profile.pitch);
    synth.cancel();
    synth.speak(&utterance);
}

#[cfg(target_arch = "wasm32")]
fn speak_with_proxy(
    proxy_url: String,
    text: String,
    workspace_id: String,
    phase: String,
    turn: u32,
    speaker: Option<String>,
    tone: DmVoiceTone,
    voice_model: Option<String>,
    voice_id: Option<String>,
) {
    wasm_bindgen_futures::spawn_local(async move {
        if let Err(err) = speak_with_proxy_inner(
            proxy_url,
            text.clone(),
            workspace_id,
            phase.clone(),
            turn,
            speaker.clone(),
            tone,
            voice_model,
            voice_id,
        )
        .await
        {
            log::warn!("dm voice proxy failed, fallback to browser speech: {}", err);
            speak_with_browser(&text, &phase, speaker.as_deref(), tone);
        }
    });
}

#[cfg(target_arch = "wasm32")]
fn speak_with_proxy_preview(
    proxy_url: String,
    text: String,
    workspace_id: String,
    phase: String,
    turn: u32,
    speaker: Option<String>,
    tone: DmVoiceTone,
    voice_model: Option<String>,
    voice_id: Option<String>,
) {
    wasm_bindgen_futures::spawn_local(async move {
        let result = speak_with_proxy_inner(
            proxy_url,
            text,
            workspace_id,
            phase,
            turn,
            speaker,
            tone,
            voice_model,
            voice_id,
        )
        .await;
        if let Some(doc) = web_sys::window().and_then(|win| win.document()) {
            match result {
                Ok(_) => {
                    set_dm_voice_status(&doc, "status-ok", "ElevenLabs 미리듣기 재생을 완료했습니다.");
                }
                Err(err) => {
                    log::warn!("dm voice preview failed: {}", err);
                    set_dm_voice_status(&doc, "status-warn", &format!("미리듣기 실패: {}", err));
                }
            }
        }
    });
}

#[cfg(target_arch = "wasm32")]
async fn speak_with_proxy_inner(
    proxy_url: String,
    text: String,
    workspace_id: String,
    phase: String,
    turn: u32,
    speaker: Option<String>,
    tone: DmVoiceTone,
    voice_model: Option<String>,
    voice_id: Option<String>,
) -> Result<(), String> {
    use wasm_bindgen::JsCast;
    use wasm_bindgen_futures::JsFuture;

    let Some(win) = web_sys::window() else {
        return Err("window unavailable".to_string());
    };

    let speaker_label = speaker
        .as_deref()
        .and_then(normalize_optional)
        .unwrap_or_else(|| "dm".to_string());
    let profile = style_profile_for(&phase, Some(&speaker_label), tone);
    let is_openai_proxy = is_openai_tts_proxy_url(&proxy_url);
    let mut body_json = if is_openai_proxy {
        let model = voice_model
            .as_deref()
            .and_then(normalize_optional)
            .unwrap_or_else(|| "eleven_multilingual_v2".to_string());
        let voice = voice_id
            .as_deref()
            .and_then(normalize_optional)
            .unwrap_or_else(|| "alloy".to_string());
        serde_json::json!({
            "input": text,
            "voice": voice,
            "model": model,
            "response_format": "mp3",
            "tone": profile.tone_tag,
            "energy": profile.energy,
            "pace": profile.rate,
            "pitch": profile.pitch,
            "speaker": speaker_label,
            "voice_settings": {
                "stability": profile.stability,
                "similarity_boost": profile.similarity_boost,
                "style": profile.style,
                "use_speaker_boost": true
            },
        })
    } else {
        serde_json::json!({
            "text": text,
            "speaker": speaker_label,
            "phase": phase,
            "workspace_id": workspace_id,
            "turn": turn,
            "tone": profile.tone_tag,
        })
    };
    if !is_openai_proxy {
        if let Some(model) = voice_model.and_then(|v| normalize_optional(&v)) {
            body_json["voice_model"] = serde_json::Value::String(model);
        }
        if let Some(id) = voice_id.and_then(|v| normalize_optional(&v)) {
            body_json["voice_id"] = serde_json::Value::String(id);
        }
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
        let status = response.status();
        let detail = match JsFuture::from(
            response
                .text()
                .map_err(|_| "failed to read error response".to_string())?,
        )
        .await
        .map_err(|_| "error response parse failed".to_string())?
        {
            value if value.is_string() => value.as_string().unwrap_or_default(),
            _ => String::new(),
        };
        if detail.trim().is_empty() {
            return Err(format!("proxy HTTP {}", status));
        }
        return Err(format!("proxy HTTP {}: {}", status, detail.trim()));
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
fn track_active_audio(audio: &web_sys::HtmlAudioElement, cleanup_object_url: Option<String>) {
    ACTIVE_DM_VOICE_AUDIO.with(|pool| {
        pool.borrow_mut().push(ActiveDmVoiceAudio {
            audio: audio.clone(),
            cleanup_object_url,
        });
    });
}

#[cfg(target_arch = "wasm32")]
fn untrack_active_audio(audio: &web_sys::HtmlAudioElement) -> Option<String> {
    ACTIVE_DM_VOICE_AUDIO.with(|pool| {
        let mut pool = pool.borrow_mut();
        let idx = pool
            .iter()
            .position(|item| js_sys::Object::is(item.audio.as_ref(), audio.as_ref()))?;
        let entry = pool.swap_remove(idx);
        entry.cleanup_object_url
    })
}

#[cfg(target_arch = "wasm32")]
fn cleanup_audio_now(audio: &web_sys::HtmlAudioElement) {
    audio.set_onended(None);
    audio.set_onerror(None);
    audio.set_src("");
    if let Some(url) = untrack_active_audio(audio) {
        let _ = web_sys::Url::revoke_object_url(&url);
    }
}

#[cfg(target_arch = "wasm32")]
fn stop_all_active_audio() {
    let entries = ACTIVE_DM_VOICE_AUDIO.with(|pool| std::mem::take(&mut *pool.borrow_mut()));
    for entry in entries {
        entry.audio.set_onended(None);
        entry.audio.set_onerror(None);
        let _ = entry.audio.pause();
        entry.audio.set_src("");
        if let Some(url) = entry.cleanup_object_url {
            let _ = web_sys::Url::revoke_object_url(&url);
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn bind_audio_cleanup_handlers(audio: &web_sys::HtmlAudioElement) {
    use wasm_bindgen::JsCast;

    let on_end_audio = audio.clone();
    let on_end = wasm_bindgen::closure::Closure::once_into_js(move || {
        cleanup_audio_now(&on_end_audio);
    });
    audio.set_onended(Some(on_end.unchecked_ref::<js_sys::Function>()));

    let on_error_audio = audio.clone();
    let on_error = wasm_bindgen::closure::Closure::once_into_js(move || {
        cleanup_audio_now(&on_error_audio);
    });
    audio.set_onerror(Some(on_error.unchecked_ref::<js_sys::Function>()));
}

#[cfg(target_arch = "wasm32")]
fn play_audio_source(source: &str, cleanup_object_url: Option<String>) -> Result<(), String> {
    let audio = web_sys::HtmlAudioElement::new_with_src(source)
        .map_err(|_| "failed to create HtmlAudioElement".to_string())?;
    audio.set_preload("auto");
    track_active_audio(&audio, cleanup_object_url);
    bind_audio_cleanup_handlers(&audio);
    if audio.play().is_err() {
        cleanup_audio_now(&audio);
        return Err("audio play failed".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::should_play_dm_voice;
    use crate::game::events::NarrativePayload;
    use crate::game::state::{WorkspaceState, TurnPhase, TurnProgressState};

    fn payload(phase: &str, speaker: Option<&str>, text: &str) -> NarrativePayload {
        NarrativePayload {
            text: text.to_string(),
            phase: phase.to_string(),
            turn: 3,
            workspace_id: "adventure-workspace".to_string(),
            speaker: speaker.map(|s| s.to_string()),
        }
    }

    fn running_state() -> (WorkspaceState, TurnProgressState) {
        let workspace = WorkspaceState {
            id: "adventure-workspace".to_string(),
            status: "active".to_string(),
            turn: 3,
            phase: TurnPhase::DmNarration,
            current_scenario: "".to_string(),
            current_node: "".to_string(),
        };
        let progress = TurnProgressState::default();
        (workspace, progress)
    }

    #[test]
    fn dm_voice_requires_running_lifecycle() {
        let (mut workspace, progress) = running_state();
        workspace.status = "ended".to_string();
        assert!(!should_play_dm_voice(
            &payload("dm_narration", Some("dm"), "테스트"),
            "테스트",
            &workspace,
            &progress
        ));
    }

    #[test]
    fn dm_voice_accepts_dm_phase_during_running() {
        let (workspace, progress) = running_state();
        assert!(should_play_dm_voice(
            &payload("dm_narration", None, "짙은 안개가 깔린다."),
            "짙은 안개가 깔린다.",
            &workspace,
            &progress
        ));
    }

    #[test]
    fn dm_voice_skips_non_dm_events() {
        let (workspace, progress) = running_state();
        assert!(!should_play_dm_voice(
            &payload("action_declaration", Some("luna"), "플레이어 행동"),
            "플레이어 행동",
            &workspace,
            &progress
        ));
    }
}

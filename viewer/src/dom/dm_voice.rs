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

    match resolve_dm_voice_mode() {
        DmVoiceMode::Off => {}
        DmVoiceMode::Browser => speak_with_browser(&text),
        DmVoiceMode::ElevenLabs => {
            if let Some(proxy_url) = resolve_dm_voice_proxy_url() {
                speak_with_proxy(proxy_url, text, room_id, phase, turn);
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
fn resolve_dm_voice_mode() -> DmVoiceMode {
    let Some(win) = web_sys::window() else {
        return DmVoiceMode::Browser;
    };

    if let Some(raw) = global_string(&win, "__TRPG_DM_VOICE_MODE")
        .or_else(|| global_string(&win, "__DM_VOICE_MODE"))
    {
        return parse_dm_voice_mode(&raw);
    }

    if let Ok(search) = win.location().search() {
        if let Some(raw) = parse_query_param(&search, "dm_voice")
            .or_else(|| parse_query_param(&search, "dm_voice_mode"))
        {
            if let Ok(Some(storage)) = win.local_storage() {
                let _ = storage.set_item("trpg_dm_voice_mode", raw.trim());
            }
            return parse_dm_voice_mode(&raw);
        }
    }

    if let Ok(Some(storage)) = win.local_storage() {
        if let Ok(Some(raw)) = storage.get_item("trpg_dm_voice_mode") {
            return parse_dm_voice_mode(&raw);
        }
    }

    if let Some(doc) = win.document() {
        if let Ok(Some(meta)) = doc.query_selector("meta[name='trpg-dm-voice-mode']") {
            if let Some(raw) = meta.get_attribute("content") {
                return parse_dm_voice_mode(&raw);
            }
        }
    }

    DmVoiceMode::Browser
}

#[cfg(target_arch = "wasm32")]
fn resolve_dm_voice_proxy_url() -> Option<String> {
    let win = web_sys::window()?;
    let normalize = |raw: &str| {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    };

    if let Some(raw) = global_string(&win, "__TRPG_DM_VOICE_PROXY_URL")
        .or_else(|| global_string(&win, "__ELEVENLABS_PROXY_URL"))
    {
        if let Some(url) = normalize(&raw) {
            return Some(url);
        }
    }

    if let Ok(search) = win.location().search() {
        if let Some(raw) = parse_query_param(&search, "dm_voice_proxy_url")
            .or_else(|| parse_query_param(&search, "elevenlabs_proxy_url"))
        {
            if let Ok(Some(storage)) = win.local_storage() {
                let _ = storage.set_item("trpg_dm_voice_proxy_url", raw.trim());
            }
            if let Some(url) = normalize(&raw) {
                return Some(url);
            }
        }
    }

    if let Ok(Some(storage)) = win.local_storage() {
        if let Ok(Some(raw)) = storage.get_item("trpg_dm_voice_proxy_url") {
            if let Some(url) = normalize(&raw) {
                return Some(url);
            }
        }
    }

    if let Some(doc) = win.document() {
        if let Ok(Some(meta)) = doc.query_selector("meta[name='trpg-dm-voice-proxy-url']") {
            if let Some(raw) = meta.get_attribute("content") {
                if let Some(url) = normalize(&raw) {
                    return Some(url);
                }
            }
        }
    }

    None
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
fn speak_with_proxy(proxy_url: String, text: String, room_id: String, phase: String, turn: u32) {
    wasm_bindgen_futures::spawn_local(async move {
        if let Err(err) =
            speak_with_proxy_inner(proxy_url, text.clone(), room_id, phase, turn).await
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
) -> Result<(), String> {
    use wasm_bindgen::JsCast;
    use wasm_bindgen_futures::JsFuture;

    let Some(win) = web_sys::window() else {
        return Err("window unavailable".to_string());
    };

    let body = serde_json::json!({
        "text": text,
        "speaker": "dm",
        "phase": phase,
        "room_id": room_id,
        "turn": turn,
    })
    .to_string();

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
            play_audio_source(&src)?;
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
        play_audio_source(&object_url)?;
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
            play_audio_source(&src)?;
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
fn play_audio_source(source: &str) -> Result<(), String> {
    let audio = web_sys::HtmlAudioElement::new_with_src(source)
        .map_err(|_| "failed to create HtmlAudioElement".to_string())?;
    audio.set_preload("auto");
    let _ = audio.play().map_err(|_| "audio play failed".to_string())?;
    std::mem::forget(audio);
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

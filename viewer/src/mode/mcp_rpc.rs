//! MCP JSON-RPC transport layer for WASM viewer.
//!
//! Handles `tools/call` requests over HTTP POST and parses the various
//! response envelopes (raw JSON-RPC, SSE frames, embedded payloads).

use serde_json::{json, Value};
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use wasm_bindgen_futures::JsFuture;

use super::transport_classify::classify_transport_error;

pub(super) async fn mcp_tool_call(tool_name: &str, args: Value) -> Result<Value, String> {
    let url = crate::config::build_masc_url("mcp");
    let body = json!({
        "jsonrpc": "2.0",
        "id": (js_sys::Date::now() as i64),
        "method": "tools/call",
        "params": {
            "name": tool_name,
            "arguments": args,
        }
    })
    .to_string();

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(&body));

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)
        .map_err(|e| format!("request 생성 실패: {:?}", e))?;
    crate::config::apply_auth_headers(&request.headers())
        .map_err(|e| format!("auth header 설정 실패: {:?}", e))?;
    request
        .headers()
        .set("Content-Type", "application/json")
        .map_err(|e| format!("헤더 설정 실패: {:?}", e))?;
    request
        .headers()
        .set("Accept", "application/json, text/event-stream")
        .map_err(|e| format!("헤더 설정 실패: {:?}", e))?;

    let window = web_sys::window().ok_or_else(|| "window unavailable".to_string())?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request))
        .await
        .map_err(|e| format!("fetch 실패: {:?}", e))?;
    let resp: web_sys::Response = resp_value
        .dyn_into()
        .map_err(|_| "response 변환 실패".to_string())?;
    let status = resp.status();

    let body_js = JsFuture::from(
        resp.text()
            .map_err(|e| format!("response.text() 실패: {:?}", e))?,
    )
    .await
    .map_err(|e| format!("본문 읽기 실패: {:?}", e))?;
    let body_text = body_js.as_string().unwrap_or_default();

    let body_preview = preview_text(&body_text, 240);

    // Early exit on transport-level errors (HTML proxy pages, empty 5xx, etc.)
    if let Some(transport_err) = classify_transport_error(status, &body_text) {
        return Err(transport_err);
    }

    let rpc: Value = if body_text.trim().is_empty() {
        json!({})
    } else {
        parse_mcp_rpc_response(&body_text)
            .or_else(|primary| {
                parse_embedded_tool_payload(&body_text)
                    .map_err(|secondary| format!("{} | {}", primary, secondary))
            })
            .map_err(|e| {
                format!(
                    "{} 응답 파싱 실패 (HTTP {}): {} / {}",
                    tool_name, status, e, body_preview
                )
            })?
    };

    if !resp.ok() {
        let msg = rpc
            .get("error")
            .and_then(|e| e.get("message"))
            .and_then(Value::as_str)
            .unwrap_or("HTTP 오류");
        return Err(format!("{} (status {})", msg, status));
    }
    if let Some(err) = rpc.get("error") {
        let msg = err
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("RPC 오류");
        return Err(msg.to_string());
    }

    if rpc.get("result").is_none()
        && rpc.get("error").is_none()
        && (rpc.get("payload").is_some() || rpc.get("status").is_some())
    {
        return Ok(rpc.get("payload").cloned().unwrap_or(rpc));
    }

    let result = rpc.get("result").cloned().unwrap_or_else(|| json!({}));
    if result
        .get("isError")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        let text = result
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
            .unwrap_or("tool call failed");
        return Err(text.to_string());
    }

    if let Some(structured) = result.get("structuredContent") {
        return Ok(structured
            .get("payload")
            .cloned()
            .unwrap_or_else(|| structured.clone()));
    }

    if let Some(payload) = result.get("payload") {
        return Ok(payload.clone());
    }

    let text = result
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
        .unwrap_or("")
        .trim()
        .to_string();

    if text.is_empty() {
        return Ok(json!({}));
    }

    let parsed: Value = match parse_embedded_tool_payload(&text) {
        Ok(v) => v,
        Err(primary) => {
            let secondary = parse_mcp_rpc_response(&text)
                .unwrap_or_else(|e| Value::String(format!("파싱 실패: {}", e)));
            return Err(format!(
                "{} 응답 JSON 파싱 실패 (HTTP {}): {} / {} / raw={}",
                tool_name, status, primary, secondary, text
            ));
        }
    };
    let final_val = parsed.get("payload").cloned().unwrap_or(parsed);
    Ok(final_val)
}

fn parse_mcp_rpc_response(raw: &str) -> Result<Value, String> {
    if let Some(v) = parse_embedded_json(raw) {
        return Ok(v);
    }

    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(json!({}));
    }
    if let Some(v) = parse_embedded_json(trimmed) {
        return Ok(v);
    }

    let chunks = trimmed.split("\n\n").collect::<Vec<_>>();
    for chunk in chunks.into_iter().rev() {
        let piece = chunk.trim();
        if piece.is_empty() {
            continue;
        }
        if let Some(v) = parse_embedded_json(piece) {
            return Ok(v);
        }

        let data_text = piece
            .lines()
            .filter_map(|line| line.strip_prefix("data:"))
            .map(str::trim_start)
            .collect::<Vec<_>>()
            .join("\n");
        let data_text = data_text.trim();
        if data_text.is_empty() || data_text == "[DONE]" {
            continue;
        }
        if let Some(v) = parse_embedded_json(data_text) {
            return Ok(v);
        }
    }

    Err("SSE frame parsing failed".to_string())
}

pub(super) fn parse_embedded_tool_payload(raw: &str) -> Result<Value, String> {
    parse_embedded_json(raw).ok_or_else(|| "JSON payload를 찾지 못했습니다".to_string())
}

fn parse_embedded_json(raw: &str) -> Option<Value> {
    let mut best: Option<(u8, Value)> = None;
    for candidate in collect_json_candidates(raw) {
        let Ok(parsed) = serde_json::from_str::<Value>(&candidate) else {
            continue;
        };
        let normalized = unwrap_nested_json_string(parsed);
        let score = score_json_candidate(&normalized);
        match &best {
            Some((current, _)) if score <= *current => {}
            _ => best = Some((score, normalized)),
        }
        if score >= 100 {
            break;
        }
    }
    best.map(|(_, value)| value)
}

fn collect_json_candidates(raw: &str) -> Vec<String> {
    let mut candidates = Vec::new();
    let src = raw.trim_start_matches('\u{feff}').trim();
    if src.is_empty() {
        return candidates;
    }

    // 1) Strict full-text parse
    push_candidate(&mut candidates, src);

    // 2) SSE payload-only lines
    for line in src.lines() {
        if let Some(payload) = line.strip_prefix("data:") {
            let payload = payload.trim_start();
            if !payload.is_empty() && payload != "[DONE]" {
                push_candidate(&mut candidates, payload);
            }
        }
    }

    // 3) Plain per-line JSON candidates (when logs and JSON are mixed).
    for line in src.lines() {
        let piece = line.trim();
        if piece.is_empty() || piece == "[DONE]" {
            continue;
        }
        if matches!(piece.chars().next(), Some('{') | Some('[') | Some('"')) {
            push_candidate(&mut candidates, piece);
        }
    }

    // 4) Event-frame chunks
    for piece in src.split("\n\n").map(str::trim) {
        if !piece.is_empty() && piece != "[DONE]" {
            push_candidate(&mut candidates, piece);
        }
    }

    // 5) Top-level embedded JSON spans (can be multiple objects in one body).
    for (start, end) in extract_top_level_json_spans(src) {
        push_candidate(&mut candidates, &src[start..end]);
    }

    candidates
}

fn push_candidate(out: &mut Vec<String>, raw: &str) {
    let piece = raw.trim();
    if piece.is_empty() {
        return;
    }
    if out.iter().any(|existing| existing == piece) {
        return;
    }
    out.push(piece.to_string());
}

/// Lightweight HTTP GET returning `(status_code, body_text)`.
/// Used for health checks where no JSON parsing is needed.
pub(super) async fn http_get_text(url: &str) -> Result<(u16, String), String> {
    let opts = web_sys::RequestInit::new();
    opts.set_method("GET");
    opts.set_mode(web_sys::RequestMode::Cors);

    let request = web_sys::Request::new_with_str_and_init(url, &opts)
        .map_err(|e| format!("request 생성 실패: {:?}", e))?;
    crate::config::apply_auth_headers(&request.headers())
        .map_err(|e| format!("auth header 설정 실패: {:?}", e))?;

    let window = web_sys::window().ok_or_else(|| "window unavailable".to_string())?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request))
        .await
        .map_err(|e| format!("fetch 실패: {:?}", e))?;
    let resp: web_sys::Response = resp_value
        .dyn_into()
        .map_err(|_| "response 변환 실패".to_string())?;
    let status = resp.status();

    let body_js = JsFuture::from(
        resp.text()
            .map_err(|e| format!("response.text() 실패: {:?}", e))?,
    )
    .await
    .map_err(|e| format!("본문 읽기 실패: {:?}", e))?;
    let body_text = body_js.as_string().unwrap_or_default();

    Ok((status, body_text))
}

fn preview_text(raw: &str, max_chars: usize) -> String {
    let trimmed = raw.trim();
    if trimmed.chars().count() <= max_chars {
        return trimmed.to_string();
    }
    let mut out = trimmed
        .chars()
        .take(max_chars.saturating_sub(1))
        .collect::<String>();
    out.push('…');
    out
}

fn unwrap_nested_json_string(mut value: Value) -> Value {
    for _ in 0..4 {
        let Some(raw) = value.as_str().map(str::trim) else {
            break;
        };
        if raw.is_empty() {
            break;
        }
        let Ok(next) = serde_json::from_str::<Value>(raw) else {
            break;
        };
        value = next;
    }
    value
}

fn score_json_candidate(value: &Value) -> u8 {
    let Some(obj) = value.as_object() else {
        return match value {
            Value::Array(_) => 40,
            Value::String(_) => 5,
            _ => 10,
        };
    };

    if obj.contains_key("jsonrpc") && (obj.contains_key("result") || obj.contains_key("error")) {
        return 100;
    }
    if obj.contains_key("result") || obj.contains_key("error") {
        return 95;
    }
    if obj.contains_key("payload") || obj.contains_key("structuredContent") {
        return 90;
    }
    if obj.contains_key("status")
        && (obj.contains_key("code") || obj.contains_key("message") || obj.contains_key("payload"))
    {
        return 85;
    }
    if obj.contains_key("world_presets")
        || obj.contains_key("dm_presets")
        || obj.contains_key("presets")
        || obj.contains_key("keepers")
    {
        return 70;
    }
    if obj.contains_key("state") || obj.contains_key("events") || obj.contains_key("content") {
        return 60;
    }
    30
}

fn extract_top_level_json_spans(raw: &str) -> Vec<(usize, usize)> {
    let mut stack: Vec<u8> = Vec::new();
    let mut in_string = false;
    let mut escape = false;
    let mut start: Option<usize> = None;
    let mut spans = Vec::new();

    for (idx, byte) in raw.bytes().enumerate() {
        if in_string {
            if escape {
                escape = false;
                continue;
            }
            match byte {
                b'\\' => escape = true,
                b'"' => in_string = false,
                _ => {}
            }
            continue;
        }

        match byte {
            b'"' => in_string = true,
            b'{' => {
                if stack.is_empty() {
                    start = Some(idx);
                }
                stack.push(b'}');
            }
            b'[' => {
                if stack.is_empty() {
                    start = Some(idx);
                }
                stack.push(b']');
            }
            b'}' | b']' => {
                if let Some(expected) = stack.pop() {
                    if expected != byte {
                        stack.clear();
                        start = None;
                        continue;
                    }
                    if stack.is_empty() {
                        if let Some(begin) = start {
                            spans.push((begin, idx + 1));
                            start = None;
                        }
                    }
                } else {
                    continue;
                }
            }
            _ => {}
        }
    }

    spans
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_embedded_tool_payload_unwraps_stringified_json() {
        let raw = r#""{\"payload\":{\"world_presets\":[{\"id\":\"grimland\"}],\"dm_presets\":[{\"id\":\"grimland-dm\"}]}}""#;
        let parsed = parse_embedded_tool_payload(raw).expect("stringified json should parse");
        let payload = parsed.get("payload").expect("payload object");
        assert_eq!(
            payload
                .get("world_presets")
                .and_then(Value::as_array)
                .map(|arr| arr.len()),
            Some(1)
        );
        assert_eq!(
            payload
                .get("dm_presets")
                .and_then(Value::as_array)
                .map(|arr| arr.len()),
            Some(1)
        );
    }

    #[test]
    fn parse_mcp_rpc_response_prefers_rpc_envelope_over_noise() {
        let raw = r#"{"debug":"seeded"}
data: {"status":"ok","payload":{"note":"not-rpc"}}

data: {"jsonrpc":"2.0","id":1,"result":{"payload":{"ok":true}}}"#;
        let parsed = parse_mcp_rpc_response(raw).expect("rpc envelope should parse");
        assert_eq!(
            parsed.get("jsonrpc").and_then(Value::as_str),
            Some("2.0"),
            "must select JSON-RPC envelope over non-rpc objects"
        );
        assert_eq!(
            parsed
                .get("result")
                .and_then(|row| row.get("payload"))
                .and_then(|row| row.get("ok"))
                .and_then(Value::as_bool),
            Some(true)
        );
    }

    #[test]
    fn parse_mcp_rpc_response_unwraps_data_stringified_json() {
        let raw = r#"data: "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"payload\":{\"dm_presets\":[{\"id\":\"grimland-dm\"}]}}}""#;
        let parsed = parse_mcp_rpc_response(raw).expect("stringified data frame should parse");
        assert_eq!(
            parsed
                .get("result")
                .and_then(|row| row.get("payload"))
                .and_then(|row| row.get("dm_presets"))
                .and_then(Value::as_array)
                .map(|arr| arr.len()),
            Some(1)
        );
    }

    #[test]
    fn parse_mcp_rpc_response_handles_log_noise_then_plain_json_line() {
        let raw = r#"[MCP] tools/call: trpg.preset.list
INFO warmup done
{"jsonrpc":"2.0","id":11,"result":{"payload":{"world_presets":[{"id":"grimland"}],"dm_presets":[{"id":"grimland-dm"}]}}}"#;
        let parsed = parse_mcp_rpc_response(raw).expect("should parse plain json line");
        assert_eq!(
            parsed
                .get("result")
                .and_then(|row| row.get("payload"))
                .and_then(|row| row.get("world_presets"))
                .and_then(Value::as_array)
                .map(|arr| arr.len()),
            Some(1)
        );
    }

    #[test]
    fn parse_embedded_tool_payload_handles_bom_prefixed_json() {
        let raw = "\u{feff}{\"payload\":{\"world_presets\":[{\"id\":\"grimland\"}],\"dm_presets\":[{\"id\":\"grimland-dm\"}]}}";
        let parsed = parse_embedded_tool_payload(raw).expect("bom json should parse");
        assert_eq!(
            parsed
                .get("payload")
                .and_then(|row| row.get("dm_presets"))
                .and_then(Value::as_array)
                .map(|arr| arr.len()),
            Some(1)
        );
    }

    // classify_transport_error tests moved to transport_classify.rs (native-testable)
}

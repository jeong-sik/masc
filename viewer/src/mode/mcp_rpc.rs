//! MCP JSON-RPC transport layer for WASM viewer.
//!
//! Handles `tools/call` requests over HTTP POST and parses the various
//! response envelopes (raw JSON-RPC, SSE frames, embedded payloads).

use serde_json::{json, Value};
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use wasm_bindgen_futures::JsFuture;

pub(super) async fn mcp_tool_call(tool_name: &str, args: Value) -> Result<Value, String> {
    let url = format!("{}/mcp", crate::config::MASC_MCP_URL);
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

    let rpc: Value = if body_text.trim().is_empty() {
        json!({})
    } else {
        parse_mcp_rpc_response(&body_text)
            .or_else(|_| parse_embedded_tool_payload(&body_text))
            .map_err(|e| {
                format!(
                    "RPC 응답 JSON 파싱 실패: {} / {}",
                    e,
                    body_text.chars().take(240).collect::<String>()
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
                "{} 응답 JSON 파싱 실패: {} / {} / raw={}",
                tool_name, primary, secondary, text
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
    for candidate in collect_json_candidates(raw) {
        if let Ok(v) = serde_json::from_str::<Value>(&candidate) {
            return Some(v);
        }
    }
    None
}

fn collect_json_candidates(raw: &str) -> Vec<String> {
    let mut candidates = Vec::new();
    let src = raw.trim();
    if src.is_empty() {
        return candidates;
    }

    // 1) Strict full-text parse
    candidates.push(src.to_string());

    // 2) SSE payload-only lines
    candidates.extend(
        src.lines()
            .filter_map(|line| line.strip_prefix("data:"))
            .map(str::trim_start)
            .filter(|line| !line.is_empty() && *line != "[DONE]")
            .map(ToString::to_string),
    );

    // 3) Event-frame chunks
    candidates.extend(
        src.split("\n\n")
            .map(str::trim)
            .filter(|piece| !piece.is_empty() && *piece != "[DONE]")
            .map(ToString::to_string),
    );

    // 4) Top-level embedded JSON span
    if let Some((start, end)) = extract_top_level_json_span(src) {
        candidates.push(src[start..end].to_string());
    }

    candidates
}

fn extract_top_level_json_span(raw: &str) -> Option<(usize, usize)> {
    let mut stack: Vec<u8> = Vec::new();
    let mut in_string = false;
    let mut escape = false;
    let mut start: Option<usize> = None;

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
                        return None;
                    }
                    if stack.is_empty() {
                        if let Some(begin) = start {
                            return Some((begin, idx + 1));
                        }
                    }
                } else {
                    return None;
                }
            }
            _ => {}
        }
    }

    None
}

//! Shared JSON-RPC HTTP client for MCP server communication.
//!
//! Extracts the common fetch → parse → error-classify pattern used by
//! `action_panel`, `actor_bind`, and `turn_controls`.

/// Classified result of a JSON-RPC call.
#[derive(Debug, Clone)]
pub enum RpcResult {
    /// Parsed `"result"` field from the JSON-RPC response body.
    Ok(String),
    /// JSON-RPC level error — the server returned `{"error": {"code": .., "message": ..}}`.
    RpcError(i64, String),
    /// HTTP-level failure (non-2xx status).
    HttpError(u16, String),
    /// Network / parse failure before we could read the response.
    NetworkError(String),
}

impl RpcResult {
    /// Human-readable one-liner for status display.
    pub fn display_error(&self) -> String {
        match self {
            RpcResult::Ok(_) => String::new(),
            RpcResult::RpcError(code, msg) => format!("RPC error {}: {}", code, msg),
            RpcResult::HttpError(status, body) => {
                let snippet = if body.len() > 120 {
                    format!("{}...", &body[..120])
                } else {
                    body.clone()
                };
                format!("HTTP {}: {}", status, snippet)
            }
            RpcResult::NetworkError(msg) => format!("Network error: {}", msg),
        }
    }
}

/// Parse a raw JSON-RPC response body into an `RpcResult`.
///
/// Exposed as a standalone function so it can be unit-tested without wasm/DOM.
pub fn parse_jsonrpc_body(body: &str) -> RpcResult {
    // Try to parse as JSON
    let parsed: serde_json::Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(e) => return RpcResult::NetworkError(format!("JSON parse error: {}", e)),
    };

    // Check for JSON-RPC error field
    if let Some(err_obj) = parsed.get("error") {
        let code = err_obj.get("code").and_then(|c| c.as_i64()).unwrap_or(-1);
        let message = err_obj
            .get("message")
            .and_then(|m| m.as_str())
            .unwrap_or("Unknown RPC error")
            .to_string();
        return RpcResult::RpcError(code, message);
    }

    // Extract result field
    if let Some(result) = parsed.get("result") {
        return RpcResult::Ok(result.to_string());
    }

    // No error, no result — unexpected format
    RpcResult::NetworkError(
        "Unexpected JSON-RPC response: missing both 'result' and 'error'".into(),
    )
}

/// Perform a JSON-RPC POST to the given endpoint.
///
/// Builds the `{"jsonrpc":"2.0", "method": .., "params": .., "id": ..}` envelope,
/// sends via `fetch`, and classifies the response into `RpcResult`.
#[cfg(target_arch = "wasm32")]
pub async fn rpc_call(endpoint: &str, method: &str, params: serde_json::Value) -> RpcResult {
    use wasm_bindgen::prelude::*;
    use wasm_bindgen_futures::JsFuture;

    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": js_sys::Math::random().to_string()
    })
    .to_string();

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(&body));

    let request = match web_sys::Request::new_with_str_and_init(endpoint, &opts) {
        Ok(r) => r,
        Err(e) => {
            return RpcResult::NetworkError(format!("Failed to build request: {:?}", e));
        }
    };

    if let Err(e) = request.headers().set("Content-Type", "application/json") {
        return RpcResult::NetworkError(format!("Failed to set Content-Type: {:?}", e));
    }
    if let Err(e) = request.headers().set("Accept", "application/json") {
        return RpcResult::NetworkError(format!("Failed to set Accept: {:?}", e));
    }

    let window = match web_sys::window() {
        Some(w) => w,
        None => return RpcResult::NetworkError("No window object".into()),
    };

    let resp_value = match JsFuture::from(window.fetch_with_request(&request)).await {
        Ok(v) => v,
        Err(e) => {
            let detail = e
                .as_string()
                .or_else(|| e.dyn_ref::<js_sys::Error>().map(|err| err.message().into()))
                .unwrap_or_else(|| format!("{:?}", e));
            return RpcResult::NetworkError(detail);
        }
    };

    let resp: web_sys::Response = match resp_value.dyn_into() {
        Ok(r) => r,
        Err(_) => return RpcResult::NetworkError("Response is not a Response object".into()),
    };

    let status = resp.status();

    let body_text = match resp.text() {
        Ok(promise) => match JsFuture::from(promise).await {
            Ok(val) => val.as_string().unwrap_or_default(),
            Err(_) => String::new(),
        },
        Err(_) => String::new(),
    };

    if status < 200 || status >= 300 {
        return RpcResult::HttpError(status, body_text);
    }

    parse_jsonrpc_body(&body_text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_success_result() {
        let body = r#"{"jsonrpc":"2.0","result":{"total":15,"roll":12,"modifier":3},"id":"1"}"#;
        match parse_jsonrpc_body(body) {
            RpcResult::Ok(result) => {
                assert!(result.contains("total"));
                assert!(result.contains("15"));
            }
            other => panic!("Expected Ok, got {:?}", other),
        }
    }

    #[test]
    fn parse_rpc_error() {
        let body =
            r#"{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request"},"id":"1"}"#;
        match parse_jsonrpc_body(body) {
            RpcResult::RpcError(code, msg) => {
                assert_eq!(code, -32600);
                assert_eq!(msg, "Invalid Request");
            }
            other => panic!("Expected RpcError, got {:?}", other),
        }
    }

    #[test]
    fn parse_malformed_json() {
        let body = "not json at all";
        match parse_jsonrpc_body(body) {
            RpcResult::NetworkError(msg) => assert!(msg.contains("JSON parse")),
            other => panic!("Expected NetworkError, got {:?}", other),
        }
    }

    #[test]
    fn parse_missing_both_fields() {
        let body = r#"{"jsonrpc":"2.0","id":"1"}"#;
        match parse_jsonrpc_body(body) {
            RpcResult::NetworkError(msg) => assert!(msg.contains("missing both")),
            other => panic!("Expected NetworkError, got {:?}", other),
        }
    }

    #[test]
    fn parse_string_result() {
        let body = r#"{"jsonrpc":"2.0","result":"Command accepted","id":"1"}"#;
        match parse_jsonrpc_body(body) {
            RpcResult::Ok(result) => assert!(result.contains("Command accepted")),
            other => panic!("Expected Ok, got {:?}", other),
        }
    }

    #[test]
    fn display_error_formats() {
        assert_eq!(RpcResult::Ok("x".into()).display_error(), "");
        assert!(RpcResult::RpcError(-32600, "bad".into())
            .display_error()
            .contains("-32600"));
        assert!(RpcResult::HttpError(503, "unavailable".into())
            .display_error()
            .contains("503"));
        assert!(RpcResult::NetworkError("timeout".into())
            .display_error()
            .contains("timeout"));
    }

    #[test]
    fn display_error_truncates_long_body() {
        let long_body = "x".repeat(200);
        let err = RpcResult::HttpError(500, long_body);
        let display = err.display_error();
        assert!(display.len() < 200);
        assert!(display.ends_with("..."));
    }

    #[test]
    fn rpc_error_with_missing_code() {
        let body = r#"{"jsonrpc":"2.0","error":{"message":"oops"},"id":"1"}"#;
        match parse_jsonrpc_body(body) {
            RpcResult::RpcError(code, msg) => {
                assert_eq!(code, -1);
                assert_eq!(msg, "oops");
            }
            other => panic!("Expected RpcError, got {:?}", other),
        }
    }
}

//! Transport-level error classification for MCP HTTP responses.
//!
//! Pure-Rust logic with no WASM dependencies, enabling native `cargo test`.

/// Detects non-JSON transport errors (proxy HTML pages, empty 5xx) **before**
/// JSON-RPC parsing so the caller can short-circuit with a human-readable
/// Korean error message.
pub(super) fn classify_transport_error(status: u16, body: &str) -> Option<String> {
    // 1. HTML error page from proxy / CDN (Cloudflare, nginx, etc.)
    if (400..=599).contains(&status) {
        let lower = body.to_ascii_lowercase();
        if lower.contains("<!doctype") || lower.contains("<html") {
            let hint = match status {
                502 => " (게이트웨이 오류)",
                503 => " (일시적 사용 불가)",
                504 => " (응답 시간 초과)",
                _ => "",
            };
            return Some(format!(
                "MASC 서버에 연결할 수 없습니다 (HTTP {}){}. 서버가 실행 중인지 확인하세요.",
                status, hint
            ));
        }
    }

    // 2. Empty body with server error status
    if (500..=599).contains(&status) && body.trim().is_empty() {
        return Some(format!("MASC 서버 응답 없음 (HTTP {})", status));
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_html_502() {
        let body = "<!DOCTYPE html><html><body><h1>502 Bad Gateway</h1></body></html>";
        let result = classify_transport_error(502, body);
        assert!(result.is_some());
        let msg = result.unwrap();
        assert!(msg.contains("HTTP 502"), "should mention status: {}", msg);
        assert!(msg.contains("게이트웨이"), "should have 502 hint: {}", msg);
    }

    #[test]
    fn detects_html_503() {
        let body = "<html><head><title>503</title></head><body>Service Unavailable</body></html>";
        let result = classify_transport_error(503, body);
        assert!(result.is_some());
        assert!(result.unwrap().contains("일시적 사용 불가"));
    }

    #[test]
    fn detects_empty_500() {
        let result = classify_transport_error(500, "  ");
        assert!(result.is_some());
        assert!(result.unwrap().contains("응답 없음"));
    }

    #[test]
    fn passes_valid_json() {
        let body = r#"{"jsonrpc":"2.0","id":1,"result":{"payload":{}}}"#;
        assert!(classify_transport_error(200, body).is_none());
    }

    #[test]
    fn passes_400_json_error() {
        // 400 with JSON body (valid RPC error) should NOT be classified as transport error
        let body = r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid Request"}}"#;
        assert!(classify_transport_error(400, body).is_none());
    }
}

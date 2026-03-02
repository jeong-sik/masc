//! Transport-level error classification for MCP HTTP responses.
//!
//! Pure-Rust logic with no WASM dependencies, enabling native `cargo test`.

/// A single row in the preflight checklist.
#[derive(Debug, Clone)]
pub(super) struct PreflightRow {
    pub ok: bool,
    pub label: String,
    pub detail: String,
    pub hint: Option<String>,
}

/// Returns `true` when the body looks like an HTML error page (proxy, CDN, etc.).
pub(super) fn is_html_body(body: &str) -> bool {
    let lower = body.to_ascii_lowercase();
    lower.contains("<!doctype") || lower.contains("<html")
}

/// Detects non-JSON transport errors (proxy HTML pages, empty 5xx) **before**
/// JSON-RPC parsing so the caller can short-circuit with a human-readable
/// Korean error message.
pub(super) fn classify_transport_error(status: u16, body: &str) -> Option<String> {
    // 1. HTML error page from proxy / CDN (Cloudflare, nginx, etc.)
    if (400..=599).contains(&status) && is_html_body(body) {
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

    #[test]
    fn is_html_body_detects_doctype() {
        assert!(is_html_body("<!DOCTYPE html><html><body>502</body></html>"));
    }

    #[test]
    fn is_html_body_detects_html_tag() {
        assert!(is_html_body("<HTML><BODY>Error</BODY></HTML>"));
    }

    #[test]
    fn is_html_body_rejects_json() {
        assert!(!is_html_body(r#"{"error":"bad"}"#));
    }

    #[test]
    fn preflight_row_debug_and_clone() {
        let row = PreflightRow {
            ok: true,
            label: "test".to_string(),
            detail: "detail".to_string(),
            hint: None,
        };
        let cloned = row.clone();
        assert!(cloned.ok);
        assert_eq!(format!("{:?}", row), format!("{:?}", cloned));
    }

    #[test]
    fn preflight_row_with_hint() {
        let row = PreflightRow {
            ok: false,
            label: "서버 연결".to_string(),
            detail: "HTTP 502 응답".to_string(),
            hint: Some("프록시 확인".to_string()),
        };
        assert!(!row.ok);
        assert_eq!(row.hint.as_deref(), Some("프록시 확인"));
        let cloned = row.clone();
        assert_eq!(cloned.hint, row.hint);
    }
}

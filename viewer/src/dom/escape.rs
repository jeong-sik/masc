/// Strip BOM, replacement char, and C0 control codes (except \t, \n, \r)
/// so that untrusted text is safe for DOM insertion.
pub fn sanitize_text(raw: &str) -> String {
    raw.chars()
        .filter(|c| {
            !matches!(c, '\u{feff}' | '\u{fffd}')
                && !('\x00'..='\x08').contains(c)
                && *c != '\x0b'
                && *c != '\x0c'
                && !('\x0e'..='\x1f').contains(c)
        })
        .collect()
}

/// HTML-escape a string for safe insertion into innerHTML.
/// Covers the 5 characters that can break HTML context.
pub fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

/// Scroll a container element to show the latest content.
pub fn scroll_to_bottom(el: &web_sys::Element) {
    el.set_scroll_top(el.scroll_height());
}

/// Remove oldest children from an element to keep it under max_entries.
pub fn trim_log(el: &web_sys::Element, max_entries: u32) {
    while el.child_element_count() > max_entries {
        if let Some(first) = el.first_element_child() {
            let _ = el.remove_child(&first);
        } else {
            break;
        }
    }
}

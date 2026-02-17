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

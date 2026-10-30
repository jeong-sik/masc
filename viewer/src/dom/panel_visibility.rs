#[cfg(target_arch = "wasm32")]
use web_sys::Document;

/// Show/hide a top-level TRPG panel by toggling CSS visibility signals.
///
/// The function writes a minimal inline style and updates aria-hidden
/// so visibility checks remain consistent across DOM modules.
#[cfg(target_arch = "wasm32")]
pub(crate) fn set_panel_visibility(document: &Document, element_id: &str, visible: bool) {
    let Some(el) = document.get_element_by_id(element_id) else {
        return;
    };

    if visible {
        let _ = el.set_attribute("style", "display: block; pointer-events: auto;");
        let _ = el.set_attribute("aria-hidden", "false");
    } else {
        let _ = el.set_attribute("style", "display: none; pointer-events: none;");
        let _ = el.set_attribute("aria-hidden", "true");
    }
}

/// Best-effort visibility check used by TRPG runtime systems.
#[cfg(target_arch = "wasm32")]
pub(crate) fn is_panel_visible(document: &Document, id: &str) -> bool {
    let Some(el) = document.get_element_by_id(id) else {
        return false;
    };
    if el.has_attribute("hidden") {
        return false;
    }
    if el
        .get_attribute("aria-hidden")
        .map(|v| v.trim().eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        return false;
    }
    if let Some(style) = el.get_attribute("style") {
        let style = style.to_ascii_lowercase().replace(' ', "");
        if style.contains("display:none") || style.contains("visibility:hidden") {
            return false;
        }
    }
    true
}

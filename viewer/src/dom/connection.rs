use bevy::prelude::*;

use crate::game::state::ConnectionStatus;

/// Tracks last-rendered connection status to avoid redundant DOM updates.
#[derive(Resource, Default)]
pub struct ConnectionStatusCache {
    pub last_status: String,
}

/// Updates the connection status indicator in the DOM.
pub fn update_connection_dom(
    status: Res<ConnectionStatus>,
    mut cache: ResMut<ConnectionStatusCache>,
) {
    let (css_class, text) = match &*status {
        ConnectionStatus::Connected => ("connected", "엔진 연결됨".to_string()),
        ConnectionStatus::Connecting => ("connecting", "연결 중...".to_string()),
        ConnectionStatus::Disconnected => ("disconnected", "연결 대기 중".to_string()),
        ConnectionStatus::Reconnecting(attempt, max) => {
            ("connecting", format!("재연결 중 ({}/{})", attempt, max))
        }
        ConnectionStatus::Failed => ("disconnected", "연결 실패".to_string()),
    };

    let status_key = format!("{}:{}", css_class, text);
    if cache.last_status == status_key {
        return;
    }
    cache.last_status = status_key;

    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(el) = document.get_element_by_id("connection-status") else {
        return;
    };

    el.set_class_name(css_class);

    if let Some(text_el) = el.query_selector(".status-text").ok().flatten() {
        text_el.set_text_content(Some(&text));
    }
}

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
    let status_str = match *status {
        ConnectionStatus::Connected => "connected",
        ConnectionStatus::Connecting => "connecting",
        ConnectionStatus::Disconnected => "disconnected",
    };

    if cache.last_status == status_str {
        return;
    }
    cache.last_status = status_str.to_string();

    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(el) = document.get_element_by_id("connection-status") else {
        return;
    };

    el.set_class_name(status_str);

    let text = match *status {
        ConnectionStatus::Connected => "엔진 연결됨",
        ConnectionStatus::Connecting => "연결 중...",
        ConnectionStatus::Disconnected => "연결 대기 중",
    };

    if let Some(text_el) = el.query_selector(".status-text").ok().flatten() {
        text_el.set_text_content(Some(text));
    }
}

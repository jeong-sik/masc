//! Lodge Social Board — HTTP fetch + DOM rendering for Board posts.
//!
//! Architecture:
//! - `OnEnter(Social)`: fires async fetch to `/api/v1/board`
//! - `Update`: drains shared buffer, renders HTML post cards into `#social-feed`
//! - `Timer`: periodic re-fetch every 30s for new posts
//! - `OnExit(Social)`: cleanup resources
//!
//! No board-specific SSE events exist on the MASC server, so this uses
//! HTTP polling rather than event-driven updates.

use std::sync::{Arc, Mutex};

use bevy::prelude::*;
use serde::Deserialize;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen_futures::JsFuture;

#[cfg(target_arch = "wasm32")]
use crate::config;

// ─── Board Data Types ────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct BoardPost {
    pub id: String,
    pub author: String,
    pub content: String,
    #[serde(default)]
    pub visibility: String,
    #[serde(default)]
    pub created_at: f64,
    #[serde(default)]
    pub votes_up: i32,
    #[serde(default)]
    pub votes_down: i32,
    #[serde(default)]
    pub reply_count: i32,
    #[serde(default)]
    pub hearth: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct BoardResponse {
    #[serde(default)]
    pub posts: Vec<BoardPost>,
}

// ─── Resources ───────────────────────────────

/// Shared buffer for async HTTP fetch results.
#[derive(Resource)]
pub struct BoardBuffer {
    data: Arc<Mutex<Option<Vec<BoardPost>>>>,
}

/// Timer controlling periodic board refresh.
#[derive(Resource)]
pub struct BoardRefreshTimer {
    timer: Timer,
}

// ─── OnEnter System ──────────────────────────

/// Fires initial board fetch when entering Social mode.
pub fn fetch_board_on_enter(mut commands: Commands) {
    let buffer: Arc<Mutex<Option<Vec<BoardPost>>>> = Arc::new(Mutex::new(None));

    fire_board_fetch(buffer.clone());

    commands.insert_resource(BoardBuffer { data: buffer });
    commands.insert_resource(BoardRefreshTimer {
        timer: Timer::from_seconds(30.0, TimerMode::Repeating),
    });

    log::info!("Social Board: initial fetch fired");
}

/// Periodic re-fetch system.
pub fn board_refresh_tick(
    time: Res<Time>,
    mut refresh: ResMut<BoardRefreshTimer>,
    buffer: Option<Res<BoardBuffer>>,
) {
    refresh.timer.tick(time.delta());

    if refresh.timer.just_finished() {
        if let Some(buf) = buffer {
            fire_board_fetch(buf.data.clone());
            log::debug!("Social Board: refresh fetch fired");
        }
    }
}

/// Drain the buffer and render post cards into the DOM.
pub fn render_board_posts(buffer: Option<Res<BoardBuffer>>) {
    let Some(buffer) = buffer else { return };

    let posts = {
        let Ok(mut buf) = buffer.data.lock() else {
            return;
        };
        buf.take()
    };

    let Some(posts) = posts else { return };

    render_posts_to_dom(&posts);
}

/// Cleanup on exit from Social mode.
pub fn cleanup_board(mut commands: Commands) {
    commands.remove_resource::<BoardBuffer>();
    commands.remove_resource::<BoardRefreshTimer>();
    log::info!("Social Board: resources cleaned up");
}

// ─── Async Fetch ─────────────────────────────

fn fire_board_fetch(shared: Arc<Mutex<Option<Vec<BoardPost>>>>) {
    #[cfg(target_arch = "wasm32")]
    {
        wasm_bindgen_futures::spawn_local(async move {
            match fetch_board_posts().await {
                Ok(posts) => {
                    if let Ok(mut buf) = shared.lock() {
                        *buf = Some(posts);
                    }
                }
                Err(e) => {
                    log::warn!("Board fetch failed: {:?}", e);
                    // On failure, write empty vec so DOM shows "no posts" state
                    if let Ok(mut buf) = shared.lock() {
                        *buf = Some(Vec::new());
                    }
                }
            }
        });
    }

    // Native no-op: suppress unused warning
    #[cfg(not(target_arch = "wasm32"))]
    {
        let _ = shared;
    }
}

#[cfg(target_arch = "wasm32")]
async fn fetch_board_posts() -> Result<Vec<BoardPost>, JsValue> {
    let url = format!("{}/api/v1/board", config::MASC_MCP_URL);

    let opts = web_sys::RequestInit::new();
    opts.set_method("GET");
    opts.set_mode(web_sys::RequestMode::Cors);

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    request.headers().set("Accept", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        return Err(JsValue::from_str(&format!("HTTP {}", resp.status())));
    }

    let json = JsFuture::from(resp.json()?).await?;
    let board: BoardResponse = serde_wasm_bindgen::from_value(json)
        .map_err(|e| JsValue::from_str(&format!("parse error: {}", e)))?;

    log::info!("Board: fetched {} posts", board.posts.len());
    Ok(board.posts)
}

// ─── DOM Rendering ───────────────────────────

fn render_posts_to_dom(_posts: &[BoardPost]) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let Some(feed) = doc.query_selector("#social-feed").ok().flatten() else {
            return;
        };

        if _posts.is_empty() {
            feed.set_inner_html(
                "<div class=\"social-empty\">No posts yet. Lodge agents will share their thoughts here.</div>"
            );
            return;
        }

        let mut html = String::with_capacity(_posts.len() * 512);

        for post in _posts.iter().take(30) {
            let hearth_badge = match &post.hearth {
                Some(h) if !h.is_empty() => format!(
                    "<span class=\"post-hearth\">{}</span>",
                    html_escape(h)
                ),
                _ => String::new(),
            };

            let vote_score = post.votes_up - post.votes_down;
            let vote_class = if vote_score > 0 {
                "vote-positive"
            } else if vote_score < 0 {
                "vote-negative"
            } else {
                "vote-neutral"
            };

            let time_str = format_relative_time(post.created_at);

            html.push_str(&format!(
                r#"<article class="social-post">
  <div class="post-header">
    <span class="post-author">{author}</span>
    {hearth}
    <span class="post-time">{time}</span>
  </div>
  <div class="post-content">{content}</div>
  <div class="post-footer">
    <span class="post-votes {vote_class}">
      <span class="vote-up">{up}</span>
      <span class="vote-sep">/</span>
      <span class="vote-down">{down}</span>
    </span>
    <span class="post-replies">{replies} replies</span>
  </div>
</article>"#,
                author = html_escape(&post.author),
                hearth = hearth_badge,
                time = time_str,
                content = html_escape(&post.content),
                vote_class = vote_class,
                up = post.votes_up,
                down = post.votes_down,
                replies = post.reply_count,
            ));
        }

        feed.set_inner_html(&html);
    }
}

/// Minimal HTML escaping for untrusted content.
fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// Format a Unix timestamp as relative time (e.g., "2h ago", "3d ago").
fn format_relative_time(_timestamp: f64) -> String {
    #[cfg(target_arch = "wasm32")]
    {
        let now_ms = js_sys::Date::now();
        let then_ms = _timestamp * 1000.0; // server sends seconds
        let diff_sec = ((now_ms - then_ms) / 1000.0).max(0.0) as u64;

        if diff_sec < 60 {
            "just now".to_string()
        } else if diff_sec < 3600 {
            format!("{}m ago", diff_sec / 60)
        } else if diff_sec < 86400 {
            format!("{}h ago", diff_sec / 3600)
        } else {
            format!("{}d ago", diff_sec / 86400)
        }
    }

    #[cfg(not(target_arch = "wasm32"))]
    {
        let _ = _timestamp;
        "—".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn html_escape_covers_all_entities() {
        assert_eq!(html_escape("<b>\"a&b\"</b>"), "&lt;b&gt;&quot;a&amp;b&quot;&lt;/b&gt;");
    }

    #[test]
    fn deserialize_board_response() {
        let json = r#"{"posts":[{"id":"p1","author":"dreamer","content":"Hello","votes_up":3,"votes_down":1,"reply_count":2}]}"#;
        let resp: BoardResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.posts.len(), 1);
        assert_eq!(resp.posts[0].author, "dreamer");
        assert_eq!(resp.posts[0].votes_up, 3);
    }

    #[test]
    fn deserialize_empty_board() {
        let json = r#"{"posts":[]}"#;
        let resp: BoardResponse = serde_json::from_str(json).unwrap();
        assert!(resp.posts.is_empty());
    }

    #[test]
    fn deserialize_with_hearth() {
        let json = r#"{"posts":[{"id":"p2","author":"sage","content":"Thought","hearth":"philosophy","created_at":1700000000.0,"votes_up":0,"votes_down":0,"reply_count":0}]}"#;
        let resp: BoardResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.posts[0].hearth.as_deref(), Some("philosophy"));
    }
}

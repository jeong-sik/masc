//! Social Board — HTTP fetch + DOM rendering + vote/comment interaction.
//!
//! Architecture:
//! - `OnEnter(Social)`: fires async fetch to `/api/v1/board`
//! - `Update`: drains shared buffer, renders HTML post cards into `#social-feed`
//! - `Timer`: periodic re-fetch every 30s for new posts
//! - `OnExit(Social)`: cleanup resources
//!
//! Interaction (via MCP tool dispatch):
//! - Vote: `POST /api/v1/tools/masc_board_vote` with `{post_id, voter, direction}`
//! - Comment: `POST /api/v1/tools/masc_board_comment` with `{post_id, content, author}`
//! - Comment fetch: `GET /api/v1/board/{post_id}` returns `{post, comments}`
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

#[cfg(any(target_arch = "wasm32", test))]
use crate::dom::escape::html_escape;

// ─── Board Data Types ────────────────────────

#[derive(Debug, Clone, Deserialize)]
#[allow(dead_code)]
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
#[allow(dead_code)]
pub struct BoardResponse {
    #[serde(default)]
    pub posts: Vec<BoardPost>,
}

#[derive(Debug, Clone, Deserialize)]
#[allow(dead_code)]
pub struct BoardComment {
    pub id: String,
    pub author: String,
    pub content: String,
    #[serde(default)]
    pub created_at: f64,
    #[serde(default)]
    pub votes_up: i32,
    #[serde(default)]
    pub votes_down: i32,
    #[serde(default)]
    pub parent_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[allow(dead_code)]
pub struct PostDetailResponse {
    pub post: BoardPost,
    #[serde(default)]
    pub comments: Vec<BoardComment>,
}

// ─── Resources ───────────────────────────────

/// Shared buffer for async HTTP fetch results.
#[derive(Resource)]
pub struct BoardBuffer {
    pub data: Arc<Mutex<Option<BoardFetchResult>>>,
}

/// Timer controlling periodic board refresh.
#[derive(Resource)]
pub struct BoardRefreshTimer {
    timer: Timer,
}

#[derive(Debug, Clone)]
pub enum BoardFetchResult {
    Posts(Vec<BoardPost>),
    Error(String),
}

// ─── OnEnter System ──────────────────────────

/// Fires initial board fetch when entering Social mode.
pub fn fetch_board_on_enter(mut commands: Commands) {
    let buffer: Arc<Mutex<Option<BoardFetchResult>>> = Arc::new(Mutex::new(None));

    #[cfg(not(target_arch = "wasm32"))]
    {
        if let Ok(mut slot) = buffer.lock() {
            *slot = Some(BoardFetchResult::Posts(Vec::new()));
        }
    }

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

    let result = {
        let Ok(mut buf) = buffer.data.lock() else {
            return;
        };
        buf.take()
    };

    match result {
        Some(BoardFetchResult::Posts(posts)) => render_posts_to_dom(&posts, &buffer.data),
        Some(BoardFetchResult::Error(detail)) => render_board_error_to_dom(&detail),
        None => {}
    }
}

/// Cleanup on exit from Social mode.
pub fn cleanup_board(mut commands: Commands) {
    commands.remove_resource::<BoardBuffer>();
    commands.remove_resource::<BoardRefreshTimer>();
    log::info!("Social Board: resources cleaned up");
}

// ─── Async Fetch ─────────────────────────────

fn fire_board_fetch(shared: Arc<Mutex<Option<BoardFetchResult>>>) {
    #[cfg(target_arch = "wasm32")]
    {
        wasm_bindgen_futures::spawn_local(async move {
            match fetch_board_posts().await {
                Ok(posts) => {
                    if let Ok(mut buf) = shared.lock() {
                        *buf = Some(BoardFetchResult::Posts(posts));
                    }
                }
                Err(e) => {
                    log::warn!("Board fetch failed: {:?}", e);
                    let detail = format_fetch_error(&e);
                    if let Ok(mut buf) = shared.lock() {
                        *buf = Some(BoardFetchResult::Error(detail));
                    }
                }
            }
        });
    }

    // Native no-op: suppress unused warning
    #[cfg(not(target_arch = "wasm32"))]
    {
        if let Ok(mut buf) = shared.lock() {
            *buf = Some(BoardFetchResult::Error(
                "Board fetch is only available in wasm viewer mode.".to_string(),
            ));
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn format_fetch_error(err: &JsValue) -> String {
    err.as_string()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Unknown fetch error".to_string())
}

#[cfg(target_arch = "wasm32")]
async fn fetch_board_posts() -> Result<Vec<BoardPost>, JsValue> {
    let url = config::build_masc_url("api/v1/board");

    let opts = web_sys::RequestInit::new();
    opts.set_method("GET");
    opts.set_mode(web_sys::RequestMode::Cors);

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    config::apply_auth_headers(&request.headers())?;
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

// ─── Vote Submission ─────────────────────────

#[cfg(target_arch = "wasm32")]
async fn submit_vote(post_id: &str, direction: &str) -> Result<(), JsValue> {
    let url = config::build_masc_url("api/v1/tools/masc_board_vote");

    let body = format!(
        r#"{{"post_id":"{}","voter":"viewer","direction":"{}"}}"#,
        post_id, direction
    );

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(&body));

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    config::apply_auth_headers(&request.headers())?;
    request.headers().set("Content-Type", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        return Err(JsValue::from_str(&format!("Vote HTTP {}", resp.status())));
    }
    log::info!("Vote submitted: {} {}", post_id, direction);
    Ok(())
}

// ─── Comment Fetch + Submit ──────────────────

#[cfg(target_arch = "wasm32")]
async fn fetch_post_comments(post_id: &str) -> Result<Vec<BoardComment>, JsValue> {
    let url = config::build_masc_url(&format!("api/v1/board/{}", post_id));

    let opts = web_sys::RequestInit::new();
    opts.set_method("GET");
    opts.set_mode(web_sys::RequestMode::Cors);

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    config::apply_auth_headers(&request.headers())?;
    request.headers().set("Accept", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        return Err(JsValue::from_str(&format!("HTTP {}", resp.status())));
    }

    let json = JsFuture::from(resp.json()?).await?;
    let detail: PostDetailResponse = serde_wasm_bindgen::from_value(json)
        .map_err(|e| JsValue::from_str(&format!("parse error: {}", e)))?;

    log::info!(
        "Comments: fetched {} for post {}",
        detail.comments.len(),
        post_id
    );
    Ok(detail.comments)
}

#[cfg(target_arch = "wasm32")]
async fn submit_comment(post_id: &str, content: &str) -> Result<(), JsValue> {
    let url = config::build_masc_url("api/v1/tools/masc_board_comment");

    let body = format!(
        r#"{{"post_id":"{}","content":"{}","author":"viewer"}}"#,
        post_id,
        content.replace('\\', "\\\\").replace('"', "\\\"")
    );

    let opts = web_sys::RequestInit::new();
    opts.set_method("POST");
    opts.set_mode(web_sys::RequestMode::Cors);
    opts.set_body(&JsValue::from_str(&body));

    let request = web_sys::Request::new_with_str_and_init(&url, &opts)?;
    config::apply_auth_headers(&request.headers())?;
    request.headers().set("Content-Type", "application/json")?;

    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let resp_value = JsFuture::from(window.fetch_with_request(&request)).await?;
    let resp: web_sys::Response = resp_value.dyn_into()?;

    if !resp.ok() {
        return Err(JsValue::from_str(&format!(
            "Comment HTTP {}",
            resp.status()
        )));
    }
    log::info!("Comment submitted on post {}", post_id);
    Ok(())
}

// ─── DOM Rendering ───────────────────────────

fn render_posts_to_dom(_posts: &[BoardPost], _shared: &Arc<Mutex<Option<BoardFetchResult>>>) {
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
                "<div class=\"social-empty\">No posts yet. Agents will share updates here.</div>"
            );
            return;
        }

        let mut html = String::with_capacity(_posts.len() * 1024);

        for post in _posts.iter().take(30) {
            let hearth_badge = match &post.hearth {
                Some(h) if !h.is_empty() => {
                    format!("<span class=\"post-hearth\">{}</span>", html_escape(h))
                }
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
                r#"<article class="social-post" id="post-{id}">
  <div class="post-header">
    <span class="post-author">{author}</span>
    {hearth}
    <span class="post-time">{time}</span>
  </div>
  <div class="post-content">{content}</div>
  <div class="post-footer">
    <span class="post-votes {vote_class}">
      <button class="vote-btn vote-btn-up" data-post-id="{id}" data-dir="up">&#9650; <span class="vote-count-up">{up}</span></button>
      <span class="vote-sep">/</span>
      <button class="vote-btn vote-btn-down" data-post-id="{id}" data-dir="down">&#9660; <span class="vote-count-down">{down}</span></button>
    </span>
    <button class="comments-toggle" data-post-id="{id}">&#128172; {replies} replies</button>
  </div>
  <div class="comments-container" id="comments-{id}" style="display:none">
    <div class="comments-list"></div>
    <div class="comment-form">
      <input type="text" class="comment-input" data-post-id="{id}" placeholder="Write a comment..." maxlength="500">
      <button class="comment-submit" data-post-id="{id}">Send</button>
    </div>
  </div>
</article>"#,
                id = html_escape(&post.id),
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

        // Bind interactive event handlers after DOM insertion
        bind_vote_buttons(&doc, _shared);
        bind_comment_toggles(&doc);
        bind_comment_forms(&doc, _shared);
    }
}

fn render_board_error_to_dom(_detail: &str) {
    #[cfg(target_arch = "wasm32")]
    {
        let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
            return;
        };
        let Some(feed) = doc.query_selector("#social-feed").ok().flatten() else {
            return;
        };

        feed.set_inner_html(&format!(
            "<div class=\"social-error\">Board feed unavailable.<br><span class=\"social-error-detail\">{}</span></div>",
            html_escape(_detail)
        ));
    }
}

// ─── Event Binding: Votes ────────────────────

#[cfg(target_arch = "wasm32")]
fn bind_vote_buttons(doc: &web_sys::Document, shared: &Arc<Mutex<Option<BoardFetchResult>>>) {
    let buttons = doc.query_selector_all(".vote-btn");
    let Ok(buttons) = buttons else { return };

    for i in 0..buttons.length() {
        let Some(node) = buttons.item(i) else {
            continue;
        };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };

        let post_id = match el.get_attribute("data-post-id") {
            Some(v) => v,
            None => continue,
        };
        let direction = match el.get_attribute("data-dir") {
            Some(v) => v,
            None => continue,
        };

        let pid = post_id.clone();
        let dir = direction.clone();
        let buf = shared.clone();

        let cb = Closure::wrap(Box::new(move || {
            let pid = pid.clone();
            let dir = dir.clone();
            let buf = buf.clone();

            // Optimistic DOM update
            update_vote_count_in_dom(&pid, &dir);

            // Async POST
            wasm_bindgen_futures::spawn_local(async move {
                if let Err(e) = submit_vote(&pid, &dir).await {
                    log::warn!("Vote failed: {:?}", e);
                }
                // Trigger refresh so next poll corrects any drift
                fire_board_fetch(buf);
            });
        }) as Box<dyn FnMut()>);

        let _ = el.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
        });

        cb.forget();
    }
}

/// Optimistically increment/decrement the vote count in DOM.
#[cfg(target_arch = "wasm32")]
fn update_vote_count_in_dom(post_id: &str, direction: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(article) = doc.get_element_by_id(&format!("post-{}", post_id)) else {
        return;
    };

    let selector = if direction == "up" {
        ".vote-count-up"
    } else {
        ".vote-count-down"
    };

    if let Ok(Some(span)) = article.query_selector(selector) {
        let current: i32 = span
            .text_content()
            .and_then(|t| t.trim().parse().ok())
            .unwrap_or(0);
        span.set_text_content(Some(&(current + 1).to_string()));
    }
}

// ─── Event Binding: Comment Toggle ───────────

#[cfg(target_arch = "wasm32")]
fn bind_comment_toggles(doc: &web_sys::Document) {
    let toggles = doc.query_selector_all(".comments-toggle");
    let Ok(toggles) = toggles else { return };

    for i in 0..toggles.length() {
        let Some(node) = toggles.item(i) else {
            continue;
        };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };

        let post_id = match el.get_attribute("data-post-id") {
            Some(v) => v,
            None => continue,
        };

        let pid = post_id.clone();

        let cb = Closure::wrap(Box::new(move || {
            let pid = pid.clone();
            toggle_comments_container(&pid);
        }) as Box<dyn FnMut()>);

        let _ = el.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
        });

        cb.forget();
    }
}

#[cfg(target_arch = "wasm32")]
fn toggle_comments_container(post_id: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let container_id = format!("comments-{}", post_id);
    let Some(container) = doc.get_element_by_id(&container_id) else {
        return;
    };

    let Some(html_el) = container.dyn_ref::<web_sys::HtmlElement>() else {
        return;
    };
    let style = html_el.style();

    let current = style.get_property_value("display").unwrap_or_default();
    if current == "none" {
        let _ = style.set_property("display", "block");
        // Fetch comments on first open
        let list_selector = format!("#{} .comments-list", container_id);
        if let Ok(Some(list)) = doc.query_selector(&list_selector) {
            if list.inner_html().is_empty() {
                // Show loading state
                list.set_inner_html("<div class=\"comment-loading\">Loading comments...</div>");
                let pid = post_id.to_string();
                wasm_bindgen_futures::spawn_local(async move {
                    match fetch_post_comments(&pid).await {
                        Ok(comments) => render_comments_to_dom(&pid, &comments),
                        Err(e) => {
                            log::warn!("Comment fetch failed: {:?}", e);
                            render_comments_to_dom(&pid, &[]);
                        }
                    }
                });
            }
        }
    } else {
        let _ = style.set_property("display", "none");
    }
}

#[cfg(target_arch = "wasm32")]
fn render_comments_to_dom(post_id: &str, comments: &[BoardComment]) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let selector = format!("#comments-{} .comments-list", post_id);
    let Some(list) = doc.query_selector(&selector).ok().flatten() else {
        return;
    };

    if comments.is_empty() {
        list.set_inner_html("<div class=\"comment-empty\">No comments yet.</div>");
        return;
    }

    let mut html = String::with_capacity(comments.len() * 256);
    for c in comments {
        let time_str = format_relative_time(c.created_at);
        html.push_str(&format!(
            r#"<div class="comment-card">
  <span class="comment-author">{author}</span>
  <span class="comment-time">{time}</span>
  <div class="comment-content">{content}</div>
</div>"#,
            author = html_escape(&c.author),
            time = time_str,
            content = html_escape(&c.content),
        ));
    }
    list.set_inner_html(&html);
}

// ─── Event Binding: Comment Form ─────────────

#[cfg(target_arch = "wasm32")]
fn bind_comment_forms(doc: &web_sys::Document, shared: &Arc<Mutex<Option<BoardFetchResult>>>) {
    let submits = doc.query_selector_all(".comment-submit");
    let Ok(submits) = submits else { return };

    for i in 0..submits.length() {
        let Some(node) = submits.item(i) else {
            continue;
        };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };

        let post_id = match el.get_attribute("data-post-id") {
            Some(v) => v,
            None => continue,
        };

        let pid = post_id.clone();
        let buf = shared.clone();

        let cb = Closure::wrap(Box::new(move || {
            let pid = pid.clone();
            let buf = buf.clone();

            let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
                return;
            };
            let input_sel = format!(".comment-input[data-post-id=\"{}\"]", pid);
            let Some(input) = doc.query_selector(&input_sel).ok().flatten() else {
                return;
            };
            let Some(input_el) = input.dyn_ref::<web_sys::HtmlInputElement>() else {
                return;
            };

            let content = input_el.value();
            let content = content.trim().to_string();
            if content.is_empty() {
                return;
            }

            // Clear input immediately
            input_el.set_value("");

            // Optimistic: append comment to DOM
            append_comment_to_dom(&pid, "viewer", &content);

            // Async POST
            let pid2 = pid.clone();
            wasm_bindgen_futures::spawn_local(async move {
                if let Err(e) = submit_comment(&pid2, &content).await {
                    log::warn!("Comment submit failed: {:?}", e);
                }
                // Trigger board refresh
                fire_board_fetch(buf);
            });
        }) as Box<dyn FnMut()>);

        let _ = el.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
        });

        cb.forget();
    }

    // Also bind Enter key on comment inputs
    bind_comment_input_enter(doc, shared);
}

#[cfg(target_arch = "wasm32")]
fn bind_comment_input_enter(
    doc: &web_sys::Document,
    shared: &Arc<Mutex<Option<BoardFetchResult>>>,
) {
    let inputs = doc.query_selector_all(".comment-input");
    let Ok(inputs) = inputs else { return };

    for i in 0..inputs.length() {
        let Some(node) = inputs.item(i) else { continue };
        let Some(el) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };

        let post_id = match el.get_attribute("data-post-id") {
            Some(v) => v,
            None => continue,
        };

        let pid = post_id.clone();
        let buf = shared.clone();

        let cb = Closure::wrap(Box::new(move |event: web_sys::KeyboardEvent| {
            if event.key() != "Enter" {
                return;
            }
            let pid = pid.clone();
            let buf = buf.clone();

            let Some(target) = event.target() else { return };
            let Some(input_el) = target.dyn_ref::<web_sys::HtmlInputElement>() else {
                return;
            };

            let content = input_el.value();
            let content = content.trim().to_string();
            if content.is_empty() {
                return;
            }

            input_el.set_value("");
            append_comment_to_dom(&pid, "viewer", &content);

            let pid2 = pid.clone();
            wasm_bindgen_futures::spawn_local(async move {
                if let Err(e) = submit_comment(&pid2, &content).await {
                    log::warn!("Comment submit failed: {:?}", e);
                }
                fire_board_fetch(buf);
            });
        }) as Box<dyn FnMut(web_sys::KeyboardEvent)>);

        let _ = el.dyn_ref::<web_sys::EventTarget>().map(|target| {
            target.add_event_listener_with_callback("keydown", cb.as_ref().unchecked_ref())
        });

        cb.forget();
    }
}

/// Append a new comment card to the comments list for a post (optimistic).
#[cfg(target_arch = "wasm32")]
fn append_comment_to_dom(post_id: &str, author: &str, content: &str) {
    let Some(doc) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let selector = format!("#comments-{} .comments-list", post_id);
    let Some(list) = doc.query_selector(&selector).ok().flatten() else {
        return;
    };

    // Remove "No comments yet" or loading placeholder
    if let Ok(Some(empty)) = list.query_selector(".comment-empty, .comment-loading") {
        empty.remove();
    }

    let comment_html = format!(
        r#"<div class="comment-card comment-new">
  <span class="comment-author">{author}</span>
  <span class="comment-time">just now</span>
  <div class="comment-content">{content}</div>
</div>"#,
        author = html_escape(author),
        content = html_escape(content),
    );

    // Insert before the comment-form (at end of list)
    let existing = list.inner_html();
    list.set_inner_html(&format!("{}{}", existing, comment_html));
}

// ─── Utilities ───────────────────────────────

/// Format a Unix timestamp as relative time (e.g., "2h ago", "3d ago").
#[allow(dead_code)]
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
        assert_eq!(
            html_escape("<b>\"a&b\"</b>"),
            "&lt;b&gt;&quot;a&amp;b&quot;&lt;/b&gt;"
        );
    }

    #[test]
    fn deserialize_board_response() {
        let json = r#"{"posts":[{"id":"p1","author":"dreamer","content":"Hello","votes_up":3,"votes_down":1,"reply_count":2}]}"#;
        let resp: BoardResponse =
            serde_json::from_str(json).expect("JSON: BoardResponse deserialization");
        assert_eq!(resp.posts.len(), 1);
        assert_eq!(resp.posts[0].author, "dreamer");
        assert_eq!(resp.posts[0].votes_up, 3);
    }

    #[test]
    fn deserialize_empty_board() {
        let json = r#"{"posts":[]}"#;
        let resp: BoardResponse =
            serde_json::from_str(json).expect("JSON: empty BoardResponse deserialization");
        assert!(resp.posts.is_empty());
    }

    #[test]
    fn deserialize_with_hearth() {
        let json = r#"{"posts":[{"id":"p2","author":"sage","content":"Thought","hearth":"philosophy","created_at":1700000000.0,"votes_up":0,"votes_down":0,"reply_count":0}]}"#;
        let resp: BoardResponse =
            serde_json::from_str(json).expect("JSON: BoardResponse with hearth deserialization");
        assert_eq!(resp.posts[0].hearth.as_deref(), Some("philosophy"));
    }

    #[test]
    fn deserialize_post_detail_with_comments() {
        let json = r#"{
            "post": {"id":"p1","author":"dreamer","content":"Hello","votes_up":5,"votes_down":0,"reply_count":2},
            "comments": [
                {"id":"c1","author":"sage","content":"Great post","created_at":1700000100.0,"votes_up":1,"votes_down":0},
                {"id":"c2","author":"muse","content":"Interesting","created_at":1700000200.0,"votes_up":0,"votes_down":0}
            ]
        }"#;
        let resp: PostDetailResponse =
            serde_json::from_str(json).expect("JSON: PostDetailResponse deserialization");
        assert_eq!(resp.post.id, "p1");
        assert_eq!(resp.comments.len(), 2);
        assert_eq!(resp.comments[0].author, "sage");
        assert_eq!(resp.comments[1].content, "Interesting");
    }

    #[test]
    fn deserialize_comment_with_parent() {
        let json = r#"{"id":"c3","author":"oracle","content":"Reply","parent_id":"c1","created_at":0.0,"votes_up":0,"votes_down":0}"#;
        let comment: BoardComment =
            serde_json::from_str(json).expect("JSON: BoardComment deserialization");
        assert_eq!(comment.parent_id.as_deref(), Some("c1"));
    }

    #[test]
    fn deserialize_post_detail_no_comments() {
        let json = r#"{"post":{"id":"p3","author":"wanderer","content":"Solo"}}"#;
        let resp: PostDetailResponse = serde_json::from_str(json)
            .expect("JSON: PostDetailResponse no-comments deserialization");
        assert!(resp.comments.is_empty());
    }

    #[test]
    fn html_escape_in_comment_content() {
        // Verify XSS vectors are escaped in content that would render as comments
        let malicious = "<script>alert('xss')</script>";
        let escaped = html_escape(malicious);
        assert!(!escaped.contains('<'));
        assert!(!escaped.contains('>'));
        assert!(escaped.contains("&lt;script&gt;"));
    }
}

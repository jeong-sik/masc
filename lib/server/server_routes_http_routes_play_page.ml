(** The page an invite link opens, and the seat it reads (RFC
    play-link-for-the-shared-machine §2.6).

    [GET /play] is public: the page carries no data. It takes the bearer from
    the link's fragment, drops it from the address bar, and keeps it in
    the tab session for reload recovery. It loads nothing from elsewhere; a CSP with a fresh nonce
    lets only its own inline script and style run.

    [GET /api/v1/play/seat] answers who the bearer is, who holds the DOS
    controller, and whom the controller can be handed to. It needs
    [CanPlayMachine] from a bearer. *)

open Server_auth
module Http = Http_server_eio

let seat_path = "/api/v1/play/seat"

(* 16 bytes from the CSPRNG, as hex: the page holds a bearer, so the nonce
   that lets its script run is not a PRNG draw. *)
let nonce_bytes = 16

let csp_header nonce =
  Printf.sprintf
    "default-src 'none'; script-src 'nonce-%s'; style-src 'nonce-%s'; connect-src 'self'; \
     img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    nonce nonce

let page_head =
  {play|<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>masc · 같이 하기</title>
<style nonce="|play}

let page_style =
  {play|">
:root { color-scheme: dark; --bg:#111418; --panel:#1b2027; --ink:#e8ecf1; --dim:#9aa4b2; --mine:#2e7d4f; --line:#2c333d; }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 system-ui, -apple-system, "Apple SD Gothic Neo", sans-serif; }
main { max-width:1120px; min-width:0; margin:0 auto; padding:12px 16px 32px; display:flex; flex-direction:column; gap:12px; overflow-wrap:anywhere; }
main > *, .row > *, #play-layout > *, #game-pane > *, #room-pane > * { min-width:0; max-width:100%; }
#play-layout { display:grid; grid-template-columns:minmax(0, 1.7fr) minmax(0, 1fr); gap:20px; }
#game-pane, #game-controls, #room-pane { display:flex; flex-direction:column; gap:12px; }
@media (max-width:800px) { #play-layout { grid-template-columns:minmax(0, 1fr); } }
#room-pane { border:1px solid var(--line); border-radius:8px; padding:12px; }
#room-messages { list-style:none; margin:0; padding:0; min-height:120px; max-height:460px; overflow:auto; }
#room-messages li { margin:0 0 14px; }
#room-messages p { margin:3px 0 0; white-space:pre-wrap; }
#room-members, #room-status, .room-meta, .room-note { font-size:13px; color:var(--dim); }
#room-members { margin:0; }
.room-meta { display:block; }
textarea { resize:vertical; min-width:0; width:100%; }
#turn { padding:10px 12px; border-radius:8px; background:var(--panel); font-weight:600; }
#turn.mine { background:var(--mine); }
#screen-wrap { background:#000; border-radius:8px; overflow:hidden; outline:none; }
#screen-wrap:focus { box-shadow: 0 0 0 2px var(--dim); }
canvas { display:block; width:100%; height:auto; image-rendering: pixelated; image-rendering: crisp-edges; }
#status { color:var(--dim); min-height:1.5em; }
#agent, #agent a { color:var(--dim); font-size:13px; }
.row { display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
button, input, select, textarea { font:inherit; color:var(--ink); background:var(--panel); border:1px solid var(--line); border-radius:6px; padding:8px 12px; }
button { cursor:pointer; min-width:44px; min-height:44px; }
button:disabled, input:disabled, select:disabled { opacity:.5; cursor:default; }
input { flex:1; min-width:0; }
select { flex:1 1 12em; width:0; text-overflow:ellipsis; }
#activity { margin:0; padding-left:1.2em; color:var(--dim); font-size:13px; }
h2 { font-size:13px; color:var(--dim); margin:4px 0; font-weight:600; }
[hidden] { display:none !important; }
#pad { display:flex; flex-direction:column; gap:10px; user-select:none; -webkit-user-select:none; touch-action:manipulation; container-type:inline-size; }
#pad .shoulders, #pad .body { display:flex; justify-content:space-between; align-items:center; gap:8px; }
#pad .dpad, #pad .face { flex:0 1 188px; min-width:0; aspect-ratio:1; display:grid; grid-template-columns:repeat(3, 1fr); grid-template-rows:repeat(3, 1fr); gap:4px; }
#pad .dpad button, #pad .face button { min-width:0; min-height:0; }
#pad .center { display:flex; flex-direction:column; gap:8px; }
/* The row is two 188px grids (60px cells), SELECT and START at 44px, and two
   8px gaps: 436px. A narrower pad -- a 375px phone leaves 343 -- puts SELECT
   and START under the grids, and the grids share the width. */
@container (max-width: 435px) {
  #pad .body { flex-wrap:wrap; }
  #pad .dpad, #pad .face { flex:1 1 0; max-width:188px; }
  #pad .center { order:1; flex:1 0 100%; flex-direction:row; justify-content:center; }
}
#pad button { font-size:13px; padding:4px; }
#pad [data-button="BTN_DPAD_UP"], #pad [data-button="BTN_NORTH"] { grid-column:2; grid-row:1; }
#pad [data-button="BTN_DPAD_LEFT"], #pad [data-button="BTN_WEST"] { grid-column:1; grid-row:2; }
#pad [data-button="BTN_DPAD_RIGHT"], #pad [data-button="BTN_EAST"] { grid-column:3; grid-row:2; }
#pad [data-button="BTN_DPAD_DOWN"], #pad [data-button="BTN_SOUTH"] { grid-column:2; grid-row:3; }
#pad .face button { border-radius:50%; }
</style>
</head>
<body>
<main>
  <div class="row"><strong>MASC · 같이 보기</strong>
    <select id="machine-view" aria-label="관전할 게임"><option value="dos">DOS</option><option value="msx">MSX</option></select>
    <button id="leave" type="button">연결 끊기</button></div>
  <div id="play-layout">
  <section id="game-pane" aria-label="게임 관전">
  <div id="turn">연결하는 중이에요</div>
  <div id="screen-wrap" tabindex="0" aria-label="게임 화면. 누르고 키보드로 조작해요"><canvas id="screen" width="320" height="200"></canvas></div>
  <div id="status"></div>
  <div id="game-controls">
  <div id="pad" hidden aria-label="masc 패드">
    <div class="shoulders"><button data-button="BTN_TL"></button><button data-button="BTN_TR"></button></div>
    <div class="body">
      <div class="dpad">
        <button data-button="BTN_DPAD_UP"></button><button data-button="BTN_DPAD_LEFT"></button>
        <button data-button="BTN_DPAD_RIGHT"></button><button data-button="BTN_DPAD_DOWN"></button>
      </div>
      <div class="center"><button data-button="BTN_SELECT"></button><button data-button="BTN_START"></button></div>
      <div class="face">
        <button data-button="BTN_NORTH"></button><button data-button="BTN_WEST"></button>
        <button data-button="BTN_EAST"></button><button data-button="BTN_SOUTH"></button>
      </div>
    </div>
  </div>
  <div class="row" id="keys">
    <button data-key="up">↑</button><button data-key="down">↓</button>
    <button data-key="left">←</button><button data-key="right">→</button>
    <button data-key="return">결정</button><button data-key="esc">취소</button>
    <button data-key="space">공백</button>
  </div>
  <div class="row">
    <input id="text" autocomplete="off" placeholder="숫자나 이름을 입력해요">
    <button id="send-text">입력</button>
  </div>
  <div class="row">
    <select id="pass-to"></select>
    <button id="pass">차례 넘기기</button>
  </div>
  </div>
  <h2>최근 기록</h2>
  <ol id="activity"></ol>
  </section>
  <section id="room-pane" aria-label="공용 게임 대화">
    <h2>공용 게임 대화</h2>
    <p class="room-note">이 방에 보낸 말은 Keeper와 초대된 참여자 모두에게 보여요.</p>
    <p id="room-members">참여자를 읽고 있어요.</p>
    <div class="row"><button id="room-older" type="button" disabled>이전 대화</button><button id="room-latest" type="button" hidden>최근 대화</button></div>
    <ol id="room-messages" aria-label="대화 기록" aria-live="polite"></ol>
    <div id="room-status" role="status"></div>
    <textarea id="chat-text" rows="2" aria-label="공용 대화 입력" placeholder="함께 보는 사람에게 말해요. Enter로 전송, Shift+Enter로 줄바꿈"></textarea>
    <button id="chat-send" type="button">대화 보내기</button>
  </section>
  </div>
|play}

(* An agent that fetches the link reads this page without running its script.
   The line points it at the guide ([Server_routes_http_routes_play_guide]). *)
let agent_note =
  String.concat ""
    [ {play|  <p id="agent" lang="en">An AI agent handed this link joins by reading <a href="|play}
    ; Play_invite.agent_guide_path
    ; {play|">|play}
    ; Play_invite.agent_guide_path
    ; {play|</a>.</p>
</main>
<script nonce="|play}
    ]

let page_script =
  {play|">
'use strict';
// The TUI reads the same live route every 0.3 s.
const POLL_MS = 300;
// Seat authority scans credentials; frame reads do not need that inventory.
const SEAT_POLL_MS = 5000;
const ACTIVITY_SHOWN = 8;
const LIVE_PATH = '/api/v1/lane-addons/live?source_kind=';
const SEAT_PATH = '/api/v1/play/seat';
const PAD_PATH = '/api/v1/play/pad';
const ROOM_PATH = '/api/v1/play/room';

// A physical gamepad in the standard mapping (W3C Gamepad, "Remapping") ->
// the masc pad's buttons. Pads in any other mapping are not read.
const GAMEPAD_BUTTONS = {
  0: 'BTN_SOUTH', 1: 'BTN_EAST', 2: 'BTN_WEST', 3: 'BTN_NORTH',
  4: 'BTN_TL', 5: 'BTN_TR', 8: 'BTN_SELECT', 9: 'BTN_START',
  12: 'BTN_DPAD_UP', 13: 'BTN_DPAD_DOWN', 14: 'BTN_DPAD_LEFT', 15: 'BTN_DPAD_RIGHT'
};
const RELEASE_OPTION = '';

// Browser key -> the DOS lane's key names (masc_dos_press). Anything not
// listed and not a single character is not sent.
const KEY_NAMES = {
  ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right',
  Home: 'home', End: 'end', PageUp: 'pgup', PageDown: 'pgdn',
  Insert: 'insert', Delete: 'delete', Enter: 'return', Escape: 'esc',
  ' ': 'space', Backspace: 'backspace',
  F1: 'f1', F2: 'f2', F3: 'f3', F4: 'f4', F5: 'f5',
  F6: 'f6', F7: 'f7', F8: 'f8', F9: 'f9', F10: 'f10'
};

const SESSION_KEY = 'masc.play.invite';
const PENDING_KEY = 'masc.play.pending';
const invitation = location.hash.slice(1);
let token = invitation;
let invitationConflict = false;
let unsettled = false;
try {
  const retained = sessionStorage.getItem(SESSION_KEY) || '';
  if (retained !== '') {
    token = retained;
    invitationConflict = invitation !== '' && invitation !== retained;
  } else if (token !== '') sessionStorage.setItem(SESSION_KEY, token);
  unsettled = token !== '' && sessionStorage.getItem(PENDING_KEY) !== null;
} catch (_) { /* A browser may deny storage; the original link still works. */ }
history.replaceState(null, '', location.pathname + location.search);
// Opening an invitation again in this tab can be only a fragment navigation.
// Re-enter initialization after disconnect or for the same invitation. A new
// identity must not abandon a still-valid controller held by this connection.
window.addEventListener('hashchange', () => {
  const invitation = location.hash.slice(1);
  if (invitation === '') return;
  if (!ended && invitation !== token) {
    history.replaceState(null, '', location.pathname + location.search);
    setStatus('invitation', '새 초대를 열려면 현재 연결을 먼저 끊은 뒤 새 초대 링크를 다시 열어 주세요.');
    return;
  }
  location.reload();
});
// Restoring a document also restores its old JS heap. A newer document in
// this tab may have dispatched a write or changed the retained identity.
window.addEventListener('pageshow', event => { if (event.persisted) location.reload(); });

const el = (id) => document.getElementById(id);
const canvas = el('screen');
const ctx = canvas.getContext('2d');
let me = null;
let controller = null;
let controllerRecoverable = false;
let controllerError = null;
let machine = false;
let since = null;
let lastActivityKey = null;
let observedActivityKey = null;
let latestSeatRequest = null;
let nextSeatPollAt = 0;
let handoffRead = null;
let ended = false;
let disconnecting = false;
let sending = Promise.resolve();
let textSending = false;
let viewMachine = 'dos';
let viewRevision = 0;
function roomId() {
  return [...crypto.getRandomValues(new Uint8Array(16))].map(byte => byte.toString(16).padStart(2, '0')).join('');
}
// A new page gets a separate presence lease, including duplicated tabs.
const roomClient = roomId();
let roomSending = Promise.resolve();
let roomBusy = false;
let chatSending = false;
let roomBefore = null;
let roomSnapshot = null;
let roomMessagesKey = null;
let roomNextRead = 0;
let pendingChat = null;
let roomAbort = null;
let roomDetached = false;
let roomDraftVersion = null;
const ROOM_DRAFT_KEY = 'masc.play.room.draft';
// The saves name the seat last reported (null: nothing loaded), and the one
// the pad on screen was read for (undefined: not read yet, or the last read
// failed). The pad is read again while the two differ.
let seatSavesName = null;
let padFor = undefined;
let padBound = new Set();
const gamepadHeld = new Set();
let gamepadLoop = false;

const statusMessages = new Map();
const UNKNOWN_MESSAGE = '전송 결과를 확인하지 못해 초대 연결을 유지했어요. 추가 입력과 연결 끊기를 멈췄어요. 운영자에게 초대 회수를 요청한 뒤 새 링크를 새 탭에서 열어 주세요.';
if (unsettled) setStatus('action', UNKNOWN_MESSAGE);
if (invitationConflict) setStatus('invitation', '새 초대를 열려면 현재 연결을 먼저 끊은 뒤 새 초대 링크를 다시 열어 주세요.');
function setStatus(source, text) {
  if (text === '') statusMessages.delete(source);
  else statusMessages.set(source, text);
  el('status').textContent = [...statusMessages.values()].join(' ');
}

function setControlsEnabled(enabled) {
  for (const node of document.querySelectorAll('#game-controls button, #game-controls input, #game-controls select')) {
    node.disabled = !enabled;
  }
  el('game-controls').hidden = viewMachine !== 'dos';
  el('machine-view').disabled = ended || disconnecting;
  el('leave').disabled = ended || disconnecting;
  setRoomControls();
}

function connectionSettled() {
  try {
    const retained = sessionStorage.getItem(SESSION_KEY);
    const pending = sessionStorage.getItem(PENDING_KEY);
    if (retained !== token) {
      unsettled = true;
      setStatus('connection', '이 탭의 연결 정보가 바뀌었어요. 페이지를 새로고침해 주세요.');
    }
    if (pending !== null) unsettled = true;
    if (unsettled) {
      setControlsEnabled(false);
      setStatus('action', UNKNOWN_MESSAGE);
      return false;
    }
    return true;
  } catch (_) {
    setControlsEnabled(false);
    setStatus('action', '브라우저에 연결 상태를 저장하지 못해 입력을 보내지 않았어요. 이 사이트의 탭 저장소를 허용해 주세요.');
    return false;
  }
}

function end(text) {
  if (ended) return;
  // Check storage at the forget boundary too, including authentication
  // failures delivered to a restored document with an older cached state.
  if (token !== '' && (!connectionSettled() || !roomConnectionCurrent(true))) return;
  ended = true;
  if (token !== '') {
    try {
      sessionStorage.removeItem(SESSION_KEY);
      sessionStorage.removeItem(ROOM_DRAFT_KEY);
    } catch (_) { /* Storage can be disabled. */ }
  }
  token = '';
  setStatus('disconnect', '');
  setStatus('invitation', '');
  setControlsEnabled(false);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  el('turn').className = '';
  el('turn').textContent = text;
}

async function api(method, path, body, signal) {
  const init = { method, headers: { Authorization: 'Bearer ' + token }, cache: 'no-store', credentials: 'omit' };
  if (signal) init.signal = signal;
  if (body !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  const response = await fetch(path, init);
  let json = null;
  try { json = await response.json(); } catch (_) { json = null; }
  // Authentication/read failures do not settle an earlier admitted write.
  if (!unsettled && (response.status === 401 || response.status === 403)) end('초대가 끝났거나 회수됐어요. 운영자에게 새 링크를 받아 주세요.');
  return { status: response.status, json };
}

function setRoomControls() {
  const closed = ended || disconnecting || roomDetached;
  el('chat-text').disabled = closed;
  el('chat-send').disabled = closed || chatSending || el('chat-text').value.trim() === '';
  el('room-older').disabled = closed || roomBusy || !roomSnapshot || !roomSnapshot.has_more;
  el('room-latest').disabled = closed || roomBusy;
  el('room-latest').hidden = roomBefore === null;
}

// Public conversation remains available during an uncertain game write, but
// a restored document must not send as an identity or replace a draft that
// another document in this tab has superseded.
function roomConnectionCurrent(checkDraft = false) {
  if (ended || roomDetached) return false;
  try {
    if (sessionStorage.getItem(SESSION_KEY) === token
        && (!checkDraft || sessionStorage.getItem(ROOM_DRAFT_KEY) === roomDraftVersion)) return true;
  } catch (_) { /* Without stored authority, preserve the existing draft. */ }
  roomDetached = true;
  el('room-status').textContent = '이 탭의 대화 또는 연결 정보를 확인하지 못했어요. 새로고침해 주세요.';
  setRoomControls();
  return false;
}

function saveRoomDraft() {
  if (!roomConnectionCurrent(true)) return false;
  try {
    const saved = JSON.stringify({ token, text:el('chat-text').value, pending:pendingChat });
    sessionStorage.setItem(ROOM_DRAFT_KEY, saved);
    roomDraftVersion = saved;
    return true;
  } catch (_) {
    el('room-status').textContent = '대화 초안을 저장하지 못해 보내지 않았어요. 이 사이트의 탭 저장소를 허용해 주세요.';
    return false;
  }
}

function restoreRoomDraft() {
  try {
    roomDraftVersion = sessionStorage.getItem(ROOM_DRAFT_KEY);
    const saved = JSON.parse(roomDraftVersion || 'null');
    if (!saved || saved.token !== token || typeof saved.text !== 'string') return;
    el('chat-text').value = saved.text;
    const p = saved.pending;
    if (p && typeof p.client_id === 'string' && typeof p.message_id === 'string'
        && typeof p.text === 'string' && (p.machine === 'msx' || p.machine === 'dos')) pendingChat = p;
  } catch (_) { /* A malformed saved draft is not a message to send. */ }
}

function validRoom(snapshot) {
  const machine = value => value === 'msx' || value === 'dos';
  const speaker = value => value === 'keeper' || value === 'participant';
  return snapshot && typeof snapshot.has_more === 'boolean'
    && Array.isArray(snapshot.messages) && snapshot.messages.every(message =>
      Number.isSafeInteger(message.id) && message.id > 0 && Number.isFinite(message.at)
      && typeof message.who === 'string' && typeof message.text === 'string'
      && machine(message.machine) && speaker(message.speaker))
    && Array.isArray(snapshot.members) && snapshot.members.every(member =>
      typeof member.name === 'string' && Number.isFinite(member.seen_at)
      && machine(member.machine) && speaker(member.speaker));
}

function renderRoom(snapshot, showMessages = true) {
  el('room-members').textContent = snapshot.members.length === 0 ? '현재 참여한 사람이 없어요.'
    : '참여 중 · ' + snapshot.members.map(member => member.name + ' (' + member.machine.toUpperCase() + ')').join(', ');
  if (!showMessages) return;
  roomSnapshot = snapshot;
  const messageKey = JSON.stringify([me, roomBefore, snapshot.messages]);
  if (messageKey === roomMessagesKey) { setRoomControls(); return; }
  roomMessagesKey = messageKey;
  const list = el('room-messages');
  const atBottom = list.scrollHeight - list.clientHeight - list.scrollTop < 24;
  const previousTop = list.scrollTop;
  list.replaceChildren();
  for (const message of snapshot.messages) {
    const item = document.createElement('li');
    const meta = document.createElement('span');
    meta.className = 'room-meta';
    const mark = message.who === me ? '▶' : message.speaker === 'keeper' ? '●' : '◀';
    meta.textContent = mark + ' ' + message.who + ' · ' + message.machine.toUpperCase()
      + ' · ' + new Date(message.at * 1000).toLocaleTimeString([], { hour:'2-digit', minute:'2-digit' });
    const body = document.createElement('p');
    body.textContent = message.text;
    item.append(meta, body);
    list.append(item);
  }
  if (snapshot.messages.length === 0) {
    const empty = document.createElement('li');
    empty.textContent = '아직 대화가 없어요. 먼저 말을 걸어 보세요.';
    list.append(empty);
  }
  list.scrollTop = atBottom && roomBefore === null ? list.scrollHeight : previousTop;
  setRoomControls();
}

function roomRequest(body) {
  roomSending = roomSending.catch(() => {}).then(() => {
    if (ended || disconnecting || !roomConnectionCurrent()) return null;
    const abort = new AbortController();
    roomAbort = abort;
    return api('POST', ROOM_PATH, body, abort.signal).finally(() => {
      if (roomAbort === abort) roomAbort = null;
    });
  });
  return roomSending;
}

function refreshRoom() {
  if (ended || disconnecting || roomDetached || roomBusy || Date.now() < roomNextRead) return;
  roomBusy = true;
  setRoomControls();
  const before = roomBefore, revision = viewRevision;
  // While reading an older page, keep it stable and renew presence separately.
  const body = { action:'read', client_id:roomClient, machine:viewMachine };
  if (before !== null) body.before = before;
  roomRequest(body).then(result => {
    if (ended || !result || !roomConnectionCurrent()) return;
    if (result.status === 200 && validRoom(result.json)) {
      renderRoom(result.json, before === roomBefore);
      if (!pendingChat) el('room-status').textContent = '';
    } else el('room-status').textContent = '공용 대화를 읽지 못했어요 (' + result.status + '). 다시 읽고 있어요.';
  }).catch(() => {
    if (!ended && !roomDetached) el('room-status').textContent = '공용 대화 연결이 끊겼어요. 다시 읽고 있어요.';
  }).finally(() => {
    roomBusy = false;
    roomNextRead = before === roomBefore && revision === viewRevision ? Date.now() + 2000 : 0;
    setRoomControls();
  });
}

function sendChat() {
  const text = el('chat-text').value;
  if (ended || disconnecting || chatSending || text.trim() === '' || !roomConnectionCurrent(true)) return;
  if (new TextEncoder().encode(text).length > 4096) {
    el('room-status').textContent = '대화 한 번은 UTF-8 4096바이트까지 보낼 수 있어요.';
    return;
  }
  if (!pendingChat || pendingChat.text !== text) {
    pendingChat = { client_id:roomClient, message_id:roomId(), machine:viewMachine, text };
  }
  const request = pendingChat;
  chatSending = true;
  if (!saveRoomDraft()) { chatSending = false; setRoomControls(); return; }
  setRoomControls();
  roomRequest({ action:'say', ...request }).then(result => {
    if (ended || !result || !roomConnectionCurrent(true)) return;
    if (result.status === 200 && validRoom(result.json)) {
      pendingChat = null;
      if (el('chat-text').value === request.text) el('chat-text').value = '';
      roomBefore = null;
      renderRoom(result.json);
      el('room-messages').scrollTop = el('room-messages').scrollHeight;
      el('room-status').textContent = '';
    } else if (result.status >= 400 && result.status < 500) {
      pendingChat = null;
      el('room-status').textContent = (result.json && result.json.error) || '대화 전송이 거절됐어요. 초안은 남겨 두었어요.';
    } else {
      el('room-status').textContent = '전송 결과를 확인하지 못했어요. 다시 보내면 같은 메시지를 확인해요.';
    }
    saveRoomDraft();
  }).catch(() => {
    if (!ended && !roomDetached) el('room-status').textContent = '전송 결과를 확인하지 못했어요. 다시 보내면 같은 메시지를 확인해요.';
  }).finally(() => {
    chatSending = false;
    roomNextRead = 0;
    setRoomControls();
  });
}

async function mutate(path, body) {
  if (!connectionSettled()) return null;
  let pending;
  try {
    // Persist before dispatch: closing/reloading the document can lose its
    // response while the authenticated server operation is still pending.
    pending = JSON.stringify({ token, operation: crypto.randomUUID() });
    sessionStorage.setItem(PENDING_KEY, pending);
  } catch (_) {
    setStatus('action', '브라우저에 연결 상태를 저장하지 못해 입력을 보내지 않았어요. 이 사이트의 탭 저장소를 허용해 주세요.');
    return null;
  }
  unsettled = true;
  setControlsEnabled(false);
  try {
    const r = await api('POST', path, body);
    const success = r.status >= 200 && r.status < 300 && r.json?.ok === true;
    const refusal = r.status >= 400 && r.status < 600 && r.json &&
      (r.json.ok === false || typeof r.json.auth_error_code === 'string' ||
       (typeof r.json.code === 'string' && typeof r.json.error === 'string'));
    if (!success && !refusal) throw new Error('unconfirmed operation response');
    // Only this operation's terminal response clears its marker. Seat/frame
    // reads are not ordered behind it, and cannot acknowledge it instead.
    if (sessionStorage.getItem(SESSION_KEY) !== token || sessionStorage.getItem(PENDING_KEY) !== pending)
      throw new Error('connection or operation changed before acknowledgement');
    sessionStorage.removeItem(PENDING_KEY);
    unsettled = false;
    if (r.status === 401 || r.status === 403) end('초대가 끝났거나 회수됐어요. 운영자에게 새 링크를 받아 주세요.');
    return r;
  } catch (_) {
    setStatus('action', UNKNOWN_MESSAGE);
    return null;
  }
}

function canMove() {
  return viewMachine === 'dos' && machine && controllerError === null && !ended && !disconnecting && !unsettled
    && (controller === null || controller === me || controllerRecoverable);
}

function renderTurn() {
  const turn = el('turn');
  setControlsEnabled(canMove());
  if (viewMachine === 'msx') {
    turn.className = '';
    turn.textContent = 'MSX · 관전 중이에요. 공용 대화에 함께 참여할 수 있어요.';
  } else if (!machine) {
    turn.className = '';
    turn.textContent = '지금 켜진 게임이 없어요.';
  } else if (controllerError !== null) {
    turn.className = '';
    turn.textContent = '조종권을 확인하지 못했어요. 다시 읽고 있어요.';
  } else if (controller === null) {
    turn.className = '';
    turn.textContent = '조종권이 비어 있어요. 먼저 누르는 사람이 가져가요.';
  } else if (controller === me) {
    turn.className = 'mine';
    turn.textContent = '내 차례예요 (' + me + ')';
  } else if (controllerRecoverable) {
    turn.className = '';
    turn.textContent = controller + ' 님이 떠났어요. 먼저 누르는 사람이 이어받아요.';
  } else {
    turn.className = '';
    turn.textContent = controller + ' 님 차례예요';
  }
}

function renderPassTargets(participants) {
  const select = el('pass-to');
  const chosen = select.value;
  select.replaceChildren();
  for (const name of participants) {
    if (name === me) continue;
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    select.append(option);
  }
  const release = document.createElement('option');
  release.value = RELEASE_OPTION;
  release.textContent = '(아무에게도 주지 않고 내려놓기)';
  select.append(release);
  if ([...select.options].some((o) => o.value === chosen)) select.value = chosen;
}

async function refreshSeat() {
  // Only a successful read may acknowledge the activity that prompted it.
  // A failed read after sending a move must be retried by the poll as well.
  lastActivityKey = null;
  const request = {};
  latestSeatRequest = request;
  nextSeatPollAt = performance.now() + SEAT_POLL_MS;
  let r;
  try {
    r = await api('GET', SEAT_PATH);
  } catch (_) {
    if (ended || latestSeatRequest !== request) return null;
    controllerError = '자리 정보를 읽지 못했어요. 다시 시도하고 있어요.';
    renderTurn();
    setStatus('seat', controllerError);
    return null;
  }
  if (ended || latestSeatRequest !== request) return null;
  if (r.status !== 200 || !r.json || typeof r.json.machine !== 'boolean'
      || typeof r.json.name !== 'string'
      || !(r.json.controller === null || typeof r.json.controller === 'string')
      || typeof r.json.controller_recoverable !== 'boolean'
      || !(r.json.controller_error === undefined || typeof r.json.controller_error === 'string')
      || !(r.json.saves_name === null || typeof r.json.saves_name === 'string')
      || !Array.isArray(r.json.participants)
      || !r.json.participants.every(name => typeof name === 'string')) {
    controllerError = '자리 정보를 읽지 못했어요 (' + r.status + ')';
    renderTurn();
    setStatus('seat', controllerError);
    return null;
  }
  me = r.json.name;
  controller = r.json.controller;
  controllerRecoverable = r.json.controller_recoverable;
  controllerError = r.json.controller_error ?? null;
  machine = r.json.machine;
  renderTurn();
  renderPassTargets(r.json.participants);
  seatSavesName = r.json.saves_name;
  setStatus('seat', controllerError ?? '');
  // Return this response's authority as well as rendering it. A concurrent
  // live response may change the shared projection before a caller resumes.
  return controllerError === null
    ? { name: r.json.name, machine: r.json.machine, controller: r.json.controller }
    : null;
}

// A pointer opening also focuses the select. Those events share one read;
// a later reopening still asks again even if the select never lost focus.
function refreshHandoffTargets() {
  if (ended || handoffRead !== null) return;
  handoffRead = refreshSeat().finally(() => { handoffRead = null; });
}

function showPad(savesName, buttons) {
  const pad = el('pad');
  padFor = savesName;
  padBound = new Set(buttons.map((b) => b.button));
  for (const node of pad.querySelectorAll('button[data-button]')) {
    const binding = buttons.find((b) => b.button === node.dataset.button);
    node.hidden = binding === undefined;
    node.textContent = binding === undefined ? '' : binding.label;
    node.title = binding === undefined ? '' : binding.keys.join(' ');
  }
  pad.hidden = buttons.length === 0;
  el('keys').hidden = buttons.length !== 0;
  setStatus('pad', '');
}

// No machine, or a program with no layout: the plain keys row stays. Only
// an answer about a program settles the pad -- its layout (200) or that it
// has none (404) -- and it settles on the saves name that answer carries.
// Any other answer, or a read that throws, leaves it unsettled with the keys
// row showing, and the next poll reads it again.
async function syncPad() {
  if (seatSavesName === padFor) return;
  if (seatSavesName === null) { showPad(null, []); return; }
  showPad(undefined, []);
  const r = await api('GET', PAD_PATH);
  if (ended) return;
  const named = r.json !== null && typeof r.json.saves_name === 'string';
  if (r.status === 200 && named && Array.isArray(r.json.buttons)) showPad(r.json.saves_name, r.json.buttons);
  else if (r.status === 404 && named) showPad(r.json.saves_name, []);
  else setStatus('pad', '패드 배치를 읽지 못했어요 (' + r.status + '). 다시 읽고 있어요.');
}

// The saves name goes with the button: a program loaded since the pad was
// read is refused by the server rather than sent this layout's keys.
function padPress(button) {
  if (ended || !padBound.has(button)) return;
  send(PAD_PATH, { button, saves_name: padFor });
}

// Rising edges only, so a held button presses once.
function pollGamepads() {
  if (ended) return;
  for (const gamepad of navigator.getGamepads()) {
    if (!gamepad || gamepad.mapping !== 'standard') continue;
    for (const [index, button] of Object.entries(GAMEPAD_BUTTONS)) {
      const held = gamepad.index + ':' + index;
      const pressed = gamepad.buttons[index] !== undefined && gamepad.buttons[index].pressed;
      if (pressed && !gamepadHeld.has(held)) { gamepadHeld.add(held); padPress(button); }
      if (!pressed) gamepadHeld.delete(held);
    }
  }
  requestAnimationFrame(pollGamepads);
}

// Whether the frame was drawn; a frame that was not says why in the status.
function draw(screen) {
  if (!screen || screen.format !== 'rgb8') { setStatus('frame', '이 화면 형식은 아직 그릴 수 없어요'); return false; }
  try {
    const raw = atob(screen.rgb_base64);
    const width = screen.width;
    const height = screen.height;
    // An rgb8 frame is width * height pixels of three bytes. A frame that says
    // otherwise is not drawn, rather than drawn from missing bytes.
    if (!(Number.isInteger(width) && width > 0 && Number.isInteger(height) && height > 0 && raw.length === width * height * 3)) {
      setStatus('frame', '화면을 읽지 못했어요 (' + width + 'x' + height + ', ' + raw.length + ' bytes)');
      return false;
    }
    if (canvas.width !== width || canvas.height !== height) { canvas.width = width; canvas.height = height; }
    const image = ctx.createImageData(width, height);
    for (let pixel = 0, source = 0; pixel < width * height; pixel += 1, source += 3) {
      const target = pixel * 4;
      image.data[target] = raw.charCodeAt(source);
      image.data[target + 1] = raw.charCodeAt(source + 1);
      image.data[target + 2] = raw.charCodeAt(source + 2);
      image.data[target + 3] = 255;
    }
    ctx.putImageData(image, 0, 0);
    return true;
  } catch (_) {
    setStatus('frame', '화면을 읽지 못했어요. 다시 읽고 있어요.');
    return false;
  }
}

function renderActivity(activity) {
  const list = el('activity');
  list.replaceChildren();
  for (const entry of activity.slice(0, ACTIVITY_SHOWN)) {
    const item = document.createElement('li');
    item.textContent = entry.who + ' · ' + entry.action;
    list.append(item);
  }
}

// One poll. Every way it can fail -- the network, the seat read, a frame
// that will not decode -- is shown and the next poll is still scheduled, so
// the page never freezes on an old frame without saying so.
async function tick() {
  try {
    await poll();
  } catch (_) {
    setStatus('connection', '연결이 잠시 끊겼어요. 다시 시도하고 있어요.');
  } finally {
    if (!ended) setTimeout(tick, POLL_MS);
  }
}

async function poll() {
  if (ended) return;
  refreshRoom();
  const watched = viewMachine, revision = viewRevision;
  const query = since === null ? '' : '&since=' + since.count + '&incarnation=' + encodeURIComponent(since.incarnation);
  const r = await api('GET', LIVE_PATH + watched + '_capture' + query);
  if (ended || revision !== viewRevision) return;
  if (r.status !== 200 || !r.json) {
    setStatus('connection', '연결이 잠시 끊겼어요. 다시 시도하고 있어요.');
  } else {
    setStatus('connection', '');
    const live = r.json;
    if (live.state === 'no_machine') {
      since = null;
      if (watched === 'dos') {
        latestSeatRequest = null;
        machine = false;
        controller = null;
        controllerRecoverable = false;
        seatSavesName = null;
      }
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      setStatus('frame', '지금 켜진 게임이 없어요.');
      renderTurn();
      if (watched === 'dos') showPad(null, []);
    } else if (live.state === 'changed') {
      if (draw(live.screen)) {
        since = { count: live.change_count, incarnation: live.incarnation };
        setStatus('frame', '');
      }
    }
    const activity = live.activity || [];
    renderActivity(activity);
    // Machine activity prompts a seat read; failed reads remain pending.
    // Opening the handoff selector refreshes participants independently.
    const key = activity.length === 0 ? '' : JSON.stringify(activity[0]) + '#' + activity.length;
    // Expiry and Keeper stops need not move the machine. An observer must
    // still discover that its holder departed, so a real move can recover it.
    if (watched === 'dos') {
      const activityChanged = observedActivityKey !== null && key !== observedActivityKey;
      observedActivityKey = key;
      const waitingForController = controller !== null && controller !== me && !controllerRecoverable;
      if ((activityChanged || (performance.now() >= nextSeatPollAt && (key !== lastActivityKey || waitingForController)))
          && await refreshSeat()) lastActivityKey = key;
      await syncPad();
    }
  }
}

function send(path, body) {
  sending = sending.then(async () => {
    if (!canMove()) return false;
    const r = await mutate(path, body);
    if (ended || r === null) return false;
    const applied = r.status >= 200 && r.status < 300 && r.json && r.json.ok === true;
    if (!applied) setStatus('action', (r.json && (r.json.message || r.json.error)) || ('요청이 거절됐어요 (' + r.status + ')'));
    else setStatus('action', '');
    await refreshSeat();
    return applied;
  }).catch(() => {
    setStatus('action', '요청 뒤 화면을 갱신하지 못했어요. 다시 읽고 있어요.');
    return false;
  });
  return sending;
}

async function disconnect() {
  if (ended || disconnecting || !roomConnectionCurrent(true)) return;
  disconnecting = true;
  if (roomAbort) roomAbort.abort();
  setControlsEnabled(false);
  setStatus('disconnect', '조종권을 확인하고 연결을 끊고 있어요.');
  try {
    // A previously admitted move can acquire a formerly free controller.
    // Drain it before observing/releasing our seat, and admit no new moves.
    await sending;
    await roomSending.catch(() => {});
    if (ended) return;
    if (unsettled) {
      setStatus('disconnect', '');
      setStatus('action', UNKNOWN_MESSAGE);
      return;
    }
    const seat = await refreshSeat();
    if (ended) return;
    if (seat === null) {
      if (!ended) setStatus('disconnect', '조종권을 확인하지 못했어요. 초대 연결을 유지했으니 다시 연결 끊기를 눌러 주세요.');
      return;
    }
    if (seat.machine && seat.controller === seat.name) {
      const r = await mutate('/api/v1/dos/pass', {});
      if (ended) return;
      if (r === null) { setStatus('disconnect', ''); return; }
      if (!(r.status >= 200 && r.status < 300 && r.json && r.json.ok === true)) {
        setStatus('disconnect', '조종권 반납을 확인하지 못했어요. 초대 연결을 유지했으니 다시 연결 끊기를 눌러 주세요.');
        return;
      }
    }
    // Presence expires on its own; its cleanup cannot delay disconnect after
    // the controller is released. Dispatch with our credential before end().
    void api('POST', ROOM_PATH, { action:'leave', client_id:roomClient, machine:viewMachine }).catch(() => {});
    end('연결을 끊었어요. 다시 들어오려면 받은 초대 링크를 열어 주세요.');
  } catch (_) {
    if (!ended) setStatus('disconnect', '조종권 반납 결과를 확인하지 못했어요. 초대 연결을 유지했으니 다시 연결 끊기를 눌러 주세요.');
  } finally {
    disconnecting = false;
    if (!ended) renderTurn();
  }
}

function press(key) { send('/api/v1/dos/press', { keys: [key] }); }

function keyName(event) {
  if (event.key === 'Tab') return event.shiftKey ? 'backtab' : 'tab';
  if (Object.prototype.hasOwnProperty.call(KEY_NAMES, event.key)) return KEY_NAMES[event.key];
  if (event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey) return event.key;
  return null;
}

el('screen-wrap').addEventListener('keydown', (event) => {
  const name = keyName(event);
  if (name === null || ended) return;
  // A held key repeats every few tens of milliseconds while one press can run
  // the machine for about 170 ms, so repeats would queue without end. One
  // press per key down.
  if (event.repeat) { event.preventDefault(); return; }
  event.preventDefault();
  press(name);
});
el('screen-wrap').addEventListener('click', () => el('screen-wrap').focus());
for (const button of document.querySelectorAll('#keys button')) {
  button.addEventListener('click', () => press(button.dataset.key));
}
for (const button of document.querySelectorAll('#pad button[data-button]')) {
  button.addEventListener('click', () => padPress(button.dataset.button));
}
window.addEventListener('gamepadconnected', () => {
  if (gamepadLoop) return;
  gamepadLoop = true;
  requestAnimationFrame(pollGamepads);
});
el('send-text').addEventListener('click', () => {
  const text = el('text').value;
  if (text === '' || textSending) return;
  textSending = true;
  send('/api/v1/dos/type', { text }).then(applied => {
    if (applied && el('text').value === text) el('text').value = '';
  }).finally(() => { textSending = false; });
});
el('text').addEventListener('keydown', (event) => { if (event.key === 'Enter') el('send-text').click(); });
// Invites and Keeper seats can change while the machine is idle. Refresh
// when choosing a handoff target; machine activity does not version this list.
el('pass-to').addEventListener('focus', refreshHandoffTargets);
el('pass-to').addEventListener('pointerdown', refreshHandoffTargets);
el('pass-to').addEventListener('keydown', event => {
  switch (event.key) {
    case 'ArrowDown': case 'ArrowUp': case 'Enter': case ' ': case 'F4':
      refreshHandoffTargets();
      break;
  }
});
el('pass').addEventListener('click', () => {
  const to = el('pass-to').value;
  send('/api/v1/dos/pass', to === RELEASE_OPTION ? {} : { to });
});
el('leave').addEventListener('click', disconnect);
el('machine-view').addEventListener('change', () => {
  const selected = el('machine-view').value;
  if (ended || disconnecting || (selected !== 'msx' && selected !== 'dos')) return;
  viewMachine = selected;
  viewRevision += 1;
  since = null;
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  setStatus('frame', '화면을 읽고 있어요.');
  roomNextRead = 0;
  renderTurn();
});
el('chat-send').addEventListener('click', sendChat);
el('chat-text').addEventListener('input', () => { saveRoomDraft(); setRoomControls(); });
el('chat-text').addEventListener('keydown', event => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    sendChat();
  }
});
el('room-older').addEventListener('click', () => {
  if (roomBusy || !roomSnapshot || !roomSnapshot.has_more || roomSnapshot.messages.length === 0) return;
  roomBefore = roomSnapshot.messages[0].id;
  roomNextRead = 0;
  refreshRoom();
});
el('room-latest').addEventListener('click', () => {
  roomBefore = null;
  roomNextRead = 0;
  refreshRoom();
});

restoreRoomDraft();
setControlsEnabled(false);
if (token === '') {
  end('링크에 초대 토큰이 없어요. 받은 링크를 그대로 열어 주세요.');
} else {
  refreshSeat().catch(() => setStatus('seat', '자리 정보를 읽지 못했어요. 다시 시도하고 있어요.')).finally(tick);
}
</script>
</body>
</html>
|play}

let page ~nonce = String.concat "" [ page_head; nonce; page_style; agent_note; nonce; page_script ]

let serve_page _request reqd =
  let nonce = Random_id.hex ~bytes:nonce_bytes in
  Http.Response.html
    ~headers:
      [ ("content-security-policy", csp_header nonce)
      ; ("referrer-policy", "no-referrer")
      ; ("x-content-type-options", "nosniff")
      ; ("cache-control", "no-store")
      ]
    (page ~nonce) reqd

(* Read under the machine's lock, off the Eio domain. No machine: nobody holds
   it. The screen read fails in no other way the lane documents, but each is
   named, so a new one is not read as "free". *)
let controller_json ~transaction ~config ~now =
  match Tool_misc_dos_lane.off_domain Dos_lane.screen with
  | Ok { Dos_lane.controller; saves_name; _ } ->
    let recoverable = match controller with
      | None -> false
      | Some holder ->
        Option.is_some (Keeper_dos_controller.holder_left ~transaction ~config ~now holder)
    in
    [ ("machine", `Bool true)
    ; ("controller", Json_util.string_opt_to_json controller)
    ; ("controller_recoverable", `Bool recoverable)
    ; ("saves_name", Json_util.string_opt_to_json saves_name)
    ]
  | Error Dos_lane.No_machine ->
    [ ("machine", `Bool false); ("controller", `Null)
    ; ("controller_recoverable", `Bool false); ("saves_name", `Null) ]
  | Error
      (( Dos_lane.Activity_disabled | Dos_lane.Activity_unobserved | Dos_lane.Invalid_request _ | Dos_lane.Unreadable _ | Dos_lane.Held_by _
       | Dos_lane.Guest_fault _ | Dos_lane.Unsaveable _ | Dos_lane.Checkpoint_refused _
       | Dos_lane.Other_program _ ) as err) ->
    [ ("machine", `Bool true); ("controller", `Null); ("saves_name", `Null)
    ; ("controller_recoverable", `Bool false)
    ; ("controller_error", `String (Dos_lane.error_to_string err)) ]

let seat_response ~config ~name =
  let snapshot = Auth.with_credential_transaction config.Workspace.base_path (fun transaction ->
    let now = Time_compat.now () in
    Result.map (fun participants ->
      `Assoc
        ((("name", `String name) :: controller_json ~transaction ~config ~now)
         @ [ ("participants", `List (List.map (fun p -> `String p) participants)) ]))
      (Play_seat.hand_to_in_transaction ~transaction config ~now))
    |> Result.map_error Masc_domain.masc_error_to_string |> Result.join in
  match snapshot with
  | Error detail ->
    `Service_unavailable, Server_refusal.json ~code:"keepers_unreadable" detail
  | Ok seat -> `OK, seat

let add_routes router =
  router
  |> Http.Router.get play_page_path serve_page
  |> Http.Router.get seat_path (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanPlayMachine
         (fun state name request reqd ->
           let status, json = seat_response ~config:(Mcp_server.workspace_config state) ~name in
           respond_json_value_with_cors ~status request reqd json)
         request reqd)

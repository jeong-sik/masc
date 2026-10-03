(** The page an invite link opens, and the seat it reads (RFC
    play-link-for-the-shared-machine §2.6).

    [GET /play] is public: the page carries no data. It takes the bearer from
    the link's fragment, drops it from the address bar, and keeps it in
    memory only. It loads nothing from elsewhere; a CSP with a fresh nonce
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
main { max-width: 760px; margin: 0 auto; padding: 12px 16px 32px; display:flex; flex-direction:column; gap:12px; }
#turn { padding:10px 12px; border-radius:8px; background:var(--panel); font-weight:600; }
#turn.mine { background:var(--mine); }
#screen-wrap { background:#000; border-radius:8px; overflow:hidden; outline:none; }
#screen-wrap:focus { box-shadow: 0 0 0 2px var(--dim); }
canvas { display:block; width:100%; height:auto; image-rendering: pixelated; image-rendering: crisp-edges; }
#status { color:var(--dim); min-height:1.5em; }
#agent, #agent a { color:var(--dim); font-size:13px; }
.row { display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
button, input, select { font:inherit; color:var(--ink); background:var(--panel); border:1px solid var(--line); border-radius:6px; padding:8px 12px; }
button { cursor:pointer; min-width:44px; min-height:44px; }
button:disabled, input:disabled, select:disabled { opacity:.5; cursor:default; }
input { flex:1; min-width:0; }
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
  <div id="turn">연결하는 중이에요</div>
  <div id="screen-wrap" tabindex="0" aria-label="게임 화면. 누르고 키보드로 조작해요"><canvas id="screen" width="320" height="200"></canvas></div>
  <div id="status"></div>
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
  <h2>최근 기록</h2>
  <ol id="activity"></ol>
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
const ACTIVITY_SHOWN = 8;
const LIVE_PATH = '/api/v1/lane-addons/live?source_kind=dos_capture';
const SEAT_PATH = '/api/v1/play/seat';
const PAD_PATH = '/api/v1/play/pad';

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

const token = location.hash.slice(1);
history.replaceState(null, '', location.pathname + location.search);

const el = (id) => document.getElementById(id);
const canvas = el('screen');
const ctx = canvas.getContext('2d');
let me = null;
let controller = null;
let controllerError = null;
let machine = false;
let since = null;
let lastActivityKey = null;
let latestSeatRequest = null;
let handoffRead = null;
let ended = false;
let sending = Promise.resolve();
// The saves name the seat last reported (null: nothing loaded), and the one
// the pad on screen was read for (undefined: not read yet, or the last read
// failed). The pad is read again while the two differ.
let seatSavesName = null;
let padFor = undefined;
let padBound = new Set();
const gamepadHeld = new Set();
let gamepadLoop = false;

const statusMessages = new Map();
function setStatus(source, text) {
  if (text === '') statusMessages.delete(source);
  else statusMessages.set(source, text);
  el('status').textContent = [...statusMessages.values()].join(' ');
}

function setControlsEnabled(enabled) {
  for (const node of document.querySelectorAll('button, input, select')) node.disabled = !enabled;
}

function end(text) {
  ended = true;
  setControlsEnabled(false);
  el('turn').className = '';
  el('turn').textContent = text;
}

async function api(method, path, body) {
  const init = { method, headers: { Authorization: 'Bearer ' + token }, cache: 'no-store', credentials: 'omit' };
  if (body !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  const response = await fetch(path, init);
  let json = null;
  try { json = await response.json(); } catch (_) { json = null; }
  if (response.status === 401 || response.status === 403) end('초대가 끝났거나 회수됐어요. 운영자에게 새 링크를 받아 주세요.');
  return { status: response.status, json };
}

function renderTurn() {
  const turn = el('turn');
  setControlsEnabled(machine && controllerError === null && !ended);
  if (!machine) {
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
  let r;
  try {
    r = await api('GET', SEAT_PATH);
  } catch (_) {
    if (ended || latestSeatRequest !== request) return false;
    setStatus('seat', '자리 정보를 읽지 못했어요. 다시 시도하고 있어요.');
    return false;
  }
  if (ended || latestSeatRequest !== request) return false;
  if (r.status !== 200 || !r.json || typeof r.json.machine !== 'boolean'
      || typeof r.json.name !== 'string'
      || !(r.json.controller === null || typeof r.json.controller === 'string')
      || !(r.json.controller_error === undefined || typeof r.json.controller_error === 'string')
      || !(r.json.saves_name === null || typeof r.json.saves_name === 'string')
      || !Array.isArray(r.json.participants)
      || !r.json.participants.every(name => typeof name === 'string')) {
    setStatus('seat', '자리 정보를 읽지 못했어요 (' + r.status + ')');
    return false;
  }
  me = r.json.name;
  controller = r.json.controller;
  controllerError = r.json.controller_error ?? null;
  machine = r.json.machine;
  renderTurn();
  renderPassTargets(r.json.participants);
  seatSavesName = r.json.saves_name;
  setStatus('seat', controllerError ?? '');
  return controllerError === null;
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
  const query = since === null ? '' : '&since=' + since.count + '&incarnation=' + encodeURIComponent(since.incarnation);
  const r = await api('GET', LIVE_PATH + query);
  if (ended) return;
  if (r.status !== 200 || !r.json) {
    setStatus('connection', '연결이 잠시 끊겼어요. 다시 시도하고 있어요.');
  } else {
    setStatus('connection', '');
    const live = r.json;
    if (live.state === 'no_machine') {
      since = null;
      latestSeatRequest = null;
      machine = false;
      controller = null;
      seatSavesName = null;
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      setStatus('frame', '지금 켜진 게임이 없어요.');
      renderTurn();
      showPad(null, []);
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
    if (key !== lastActivityKey && await refreshSeat()) lastActivityKey = key;
    await syncPad();
  }
}

function send(path, body) {
  sending = sending.then(async () => {
    if (ended || !machine || controllerError !== null) return;
    const r = await api('POST', path, body);
    if (ended) return;
    if (!r.json || r.json.ok !== true) setStatus('action', (r.json && (r.json.message || r.json.error)) || ('요청이 거절됐어요 (' + r.status + ')'));
    else setStatus('action', '');
    await refreshSeat();
  }).catch(() => setStatus('action', '보내지 못했어요. 연결을 확인해 주세요.'));
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
  if (text === '') return;
  el('text').value = '';
  send('/api/v1/dos/type', { text });
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
let controller_json () =
  match Tool_misc_dos_lane.off_domain Dos_lane.screen with
  | Ok { Dos_lane.controller; saves_name; _ } ->
    [ ("machine", `Bool true)
    ; ("controller", Json_util.string_opt_to_json controller)
    ; ("saves_name", Json_util.string_opt_to_json saves_name)
    ]
  | Error Dos_lane.No_machine -> [ ("machine", `Bool false); ("controller", `Null); ("saves_name", `Null) ]
  | Error
      (( Dos_lane.Invalid_request _ | Dos_lane.Unreadable _ | Dos_lane.Held_by _
       | Dos_lane.Guest_fault _ | Dos_lane.Unsaveable _ | Dos_lane.Checkpoint_refused _
       | Dos_lane.Other_program _ ) as err) ->
    [ ("machine", `Bool true); ("controller", `Null); ("saves_name", `Null)
    ; ("controller_error", `String (Dos_lane.error_to_string err)) ]

let seat_response ~config ~name =
  match Play_seat.hand_to config ~now:(Time_compat.now ()) with
  | Error detail ->
    `Service_unavailable, Server_refusal.json ~code:"keepers_unreadable" detail
  | Ok participants ->
    ( `OK
    , `Assoc
        ((("name", `String name) :: controller_json ())
         @ [ ("participants", `List (List.map (fun p -> `String p) participants)) ]) )

let add_routes router =
  router
  |> Http.Router.get play_page_path serve_page
  |> Http.Router.get seat_path (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanPlayMachine
         (fun state name request reqd ->
           let status, json = seat_response ~config:(Mcp_server.workspace_config state) ~name in
           respond_json_value_with_cors ~status request reqd json)
         request reqd)

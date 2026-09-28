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
.row { display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
button, input, select { font:inherit; color:var(--ink); background:var(--panel); border:1px solid var(--line); border-radius:6px; padding:8px 12px; }
button { cursor:pointer; min-width:44px; min-height:44px; }
button:disabled, input:disabled, select:disabled { opacity:.5; cursor:default; }
input { flex:1; min-width:0; }
#activity { margin:0; padding-left:1.2em; color:var(--dim); font-size:13px; }
h2 { font-size:13px; color:var(--dim); margin:4px 0; font-weight:600; }
</style>
</head>
<body>
<main>
  <div id="turn">연결하는 중이에요</div>
  <div id="screen-wrap" tabindex="0" aria-label="게임 화면. 누르고 키보드로 조작해요"><canvas id="screen" width="320" height="200"></canvas></div>
  <div id="status"></div>
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
</main>
<script nonce="|play}

let page_script =
  {play|">
'use strict';
// The TUI reads the same live route every 0.3 s.
const POLL_MS = 300;
const ACTIVITY_SHOWN = 8;
const LIVE_PATH = '/api/v1/lane-addons/live?source_kind=dos_capture';
const SEAT_PATH = '/api/v1/play/seat';
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
let since = null;
let lastActivityKey = null;
let ended = false;
let sending = Promise.resolve();

function setStatus(text) { el('status').textContent = text; }

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
  if (controller === null) {
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
  const r = await api('GET', SEAT_PATH);
  if (ended) return;
  if (r.status !== 200 || !r.json) { setStatus('자리 정보를 읽지 못했어요 (' + r.status + ')'); return; }
  me = r.json.name;
  controller = r.json.controller;
  renderTurn();
  renderPassTargets(r.json.participants);
}

// Whether the frame was drawn; a frame that was not says why in the status.
function draw(screen) {
  if (!screen || screen.format !== 'rgb8') { setStatus('이 화면 형식은 아직 그릴 수 없어요'); return false; }
  const raw = atob(screen.rgb_base64);
  const width = screen.width;
  const height = screen.height;
  // An rgb8 frame is width * height pixels of three bytes. A frame that says
  // otherwise is not drawn, rather than drawn from missing bytes.
  if (!(Number.isInteger(width) && width > 0 && Number.isInteger(height) && height > 0 && raw.length === width * height * 3)) {
    setStatus('화면을 읽지 못했어요 (' + width + 'x' + height + ', ' + raw.length + ' bytes)');
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
    setStatus('연결이 잠시 끊겼어요. 다시 시도하고 있어요.');
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
    setStatus('연결이 잠시 끊겼어요. 다시 시도하고 있어요.');
  } else {
    const live = r.json;
    if (live.state === 'no_machine') {
      since = null;
      setStatus('지금 켜진 게임이 없어요.');
    } else if (live.state === 'changed') {
      since = { count: live.change_count, incarnation: live.incarnation };
      if (draw(live.screen)) setStatus('');
    }
    const activity = live.activity || [];
    renderActivity(activity);
    // The feed moves on every press, pass and load; the seat is read again
    // only then, instead of on every poll.
    const key = activity.length === 0 ? '' : JSON.stringify(activity[0]) + '#' + activity.length;
    if (key !== lastActivityKey) { lastActivityKey = key; await refreshSeat(); }
  }
}

function send(path, body) {
  sending = sending.then(async () => {
    if (ended) return;
    const r = await api('POST', path, body);
    if (ended) return;
    if (!r.json || r.json.ok !== true) setStatus((r.json && r.json.message) || ('요청이 거절됐어요 (' + r.status + ')'));
    await refreshSeat();
  }).catch(() => setStatus('보내지 못했어요. 연결을 확인해 주세요.'));
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
el('send-text').addEventListener('click', () => {
  const text = el('text').value;
  if (text === '') return;
  el('text').value = '';
  send('/api/v1/dos/type', { text });
});
el('text').addEventListener('keydown', (event) => { if (event.key === 'Enter') el('send-text').click(); });
el('pass').addEventListener('click', () => {
  const to = el('pass-to').value;
  send('/api/v1/dos/pass', to === RELEASE_OPTION ? {} : { to });
});

if (token === '') {
  end('링크에 초대 토큰이 없어요. 받은 링크를 그대로 열어 주세요.');
} else {
  refreshSeat().catch(() => setStatus('자리 정보를 읽지 못했어요. 다시 시도하고 있어요.')).finally(tick);
}
</script>
</body>
</html>
|play}

let page ~nonce = String.concat "" [ page_head; nonce; page_style; nonce; page_script ]

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
  | Ok { Dos_lane.controller = Some holder; _ } -> [ ("machine", `Bool true); ("controller", `String holder) ]
  | Ok { Dos_lane.controller = None; _ } -> [ ("machine", `Bool true); ("controller", `Null) ]
  | Error Dos_lane.No_machine -> [ ("machine", `Bool false); ("controller", `Null) ]
  | Error
      (( Dos_lane.Invalid_request _ | Dos_lane.Unreadable _ | Dos_lane.Held_by _
       | Dos_lane.Guest_fault _ | Dos_lane.Unsaveable _ | Dos_lane.Checkpoint_refused _ ) as err) ->
    [ ("machine", `Bool true); ("controller", `Null); ("controller_error", `String (Dos_lane.error_to_string err)) ]

let seat_response ~config ~name =
  match Play_seat.keeper_names config with
  | Error detail ->
    `Service_unavailable, `Assoc [ ("error", `String "keepers_unreadable"); ("message", `String detail) ]
  | Ok keepers ->
    let participants =
      Play_seat.participants ~base_path:config.Workspace.base_path ~keepers ~now:(Time_compat.now ())
    in
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

(* The key table — data first, then the display projections. Most dispatch
   remains the ordered match in masc_tui.ml; cross-surface shortcuts whose
   spelling is shared with the displays classify through this module too.
   That keeps one binding record authoritative for both behaviour and
   discoverability (#30356 taught the cost of the two drifting apart). *)

open Masc_tui_types

type group = Navigate | Act | Search | Meta

(* Whether a binding answers while a surface's detail is open. A surface that
   owns a detail draws one footer for two states, so it advertised exactly one
   key the dispatcher refuses in the state on screen: [Right / Enter] once a
   detail is already open, [[ / ]] while it is not. The fact was in the table
   already -- but only as prose inside [help] ("while a detail is open"), which
   no footer can read. This is that same fact as a value, so the footer and the
   dispatcher stop disagreeing. *)
type detail_state =
  | Either  (** answers in both states; the default *)
  | List_only  (** only while no detail is open *)
  | Detail_only  (** only while a detail is open *)

(* Whether a binding needs a row under the cursor. A list with no rows has
   nothing for [j/k] to step over, [Right / Enter] to open or [y / x] to
   answer, and the dispatcher ends each of those in [()]. The footer drew them
   anyway, first in line, so on a narrow terminal it gave up the keys that do
   act -- [n] on an empty Schedules list -- before them. As with
   [detail_state], the fact is a value in the table, so the footer and the
   dispatcher stop disagreeing. *)
type row_need =
  | Rowless  (** answers with no row under the cursor; the default *)
  | Needs_row  (** steps over, opens or answers a row; refused on an empty list *)
  | Needs_reading
      (** opens a reading: a row's details, or what replaced the list when
          its read failed. An empty list has one only after a failed read. *)

type binding = {
  key : string;
  label : string;
  label_ko : string;
  help : string option;
  group : group;
  detail : detail_state;
  rows : row_need;
}

let b ?help ~ko ?(detail = Either) ?(rows = Rowless) group key label =
  { key; label; label_ko = ko; help; group; detail; rows }

(* The one spelling of "key:label". The footer atoms, the Keeper tab row and
   the Questions heading all read it. Hand-written copies had drifted: the
   queue footer said [a:answer a question] where the heading said
   [a:open answers]. [label] replaces the binding's own: [hints_in_order]
   passes the Korean wording, and the Approvals footer passes a shorter word
   for one mode. *)
let key_hint ?label (binding : binding) =
  binding.key ^ ":" ^ (match label with Some word -> word | None -> binding.label)

(* [None] is shared by all Config panes; [Some panes] belongs only to those
   input handlers. Keep availability beside the binding, not in a second key
   list inferred from the rendered label. *)
let config_bindings =
  [ b ~ko:"선택 / 스크롤" Navigate "j/k" "select / scroll", Some
      [ Config_runtime; Config_models; Config_params; Config_prompts
      ; Config_presets; Config_themes; Config_voice ]
  ; b ~ko:"다음 탭" Navigate "p" "next pane"
      ~help:"runtime.toml / models / params / prompts / presets / themes / voice", None
  ; b ~ko:"활동" Navigate "A" "activity"
      ~help:"event history under System", None
  ; b ~ko:"로그" Navigate "L" "logs"
      ~help:"server logs under System", None
  ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
      ~help:"pages runtime.toml, the voice reading and the detail of params, prompts \
             and presets, and moves the selection a page on models and themes",
      Some [ Config_runtime; Config_models; Config_params; Config_prompts; Config_presets
           ; Config_themes; Config_voice ]
  ; b ~ko:"상세 처음/끝" Navigate "Home/End" "detail"
      ~help:"first or last wrapped detail row of a selected preset, or of a prompt registry or asset document",
      Some [ Config_presets; Config_prompts ]
  ; b ~ko:"적용 상태" Navigate "v" "read status"
      ~help:"runtime.toml: source revision, validation issues, and application/restart details",
      Some [ Config_runtime ]
  ; b ~ko:"런타임" Navigate "9" "Runtime"
      ~help:"runtime status, lane routing, probes and connected clients", None
  ; b ~ko:"리소스" Navigate "s" "resources"
      ~help:"the MCP resource catalog under Features & plugins", None
  ; b ~ko:"도구" Navigate "t" "tools"
      ~help:"the tool catalog, receipts, and usage under Features & plugins", None
  ; b ~ko:"편집" Act "e" "edit"
      ~help:"runtime.toml previews; models open fields; prompts save an override; voice opens the setup wizard",
      Some [ Config_runtime; Config_models; Config_prompts; Config_voice ]
    (* One item, because they are one action: on params [e] and [Enter] both
       open the same type-aware field ([handle_runtime_param_edit_open]
       ~advanced:false). Apart, this pane spent two of its slots on one door,
       and the fitter -- which reads position, not meaning -- gave up [E] at
       80 cells, the only other thing the pane does. A reader left with
       [e:edit] and [Enter:edit / use] would also read the pane as having one
       way to edit and no advanced one. *)
  ; b ~ko:"모델 복사" Act "c" "copy model" ~help:"same account/API model, independent variant settings", Some [Config_models]
  ; b ~ko:"전체 상세" Navigate "v" "full details" ~help:"read complete account/model settings without editing", Some [Config_models]
  ; b ~ko:"모델 원본" Act "m" "model source", Some [Config_models]
  ; b ~ko:"편집" Act "e / Enter" "edit"
      ~help:"on params: edit the selected value with a type-aware field",
      Some [ Config_params ]
  ; b ~ko:"JSON 편집" Act "E" "advanced JSON"
      ~help:"on params only: edit the exact JSON value", Some [ Config_params ]
    (* Split from the pair above. What [Enter] does on themes is not editing,
       and one label reading "edit / use" made each pane carry the other's
       word: a params reader met "use" with nothing to use. *)
  ; b ~ko:"적용" Act "Enter" "use"
      ~help:"on themes, use that colour scheme", Some [ Config_themes ]
  ; b ~ko:"기본값" Act "x" "default"
      ~help:"parameters: return the selected value to its default", Some [ Config_params ]
  ; b ~ko:"재정의 해제" Act "x" "clear override"
      ~help:"prompts: clear the selected override", Some [ Config_prompts ]
  ; b ~ko:"터미널 색상" Act "x" "terminal colours"
      ~help:"themes: follow terminal colours", Some [ Config_themes ]
  ; b ~ko:"필터" Act "f" "filter"
      ~help:"on themes, cycle All / Dark / Light schemes", Some [ Config_themes ]
    (* Pane-scoped writes. Each of these is the only key that does what it
       does, and none of them were listed: presets could be made and put
       back, and the prompt list could be switched between three readings,
       with nothing on screen saying so. Short labels: the pane each belongs
       to and what it does are in the help, which the ? overlay draws in
       full. *)
  ; b ~ko:"새로 저장" Act "n" "new"
      ~help:"on presets, name a preset holding the current configuration; in the name field PgUp/PgDn and Home/End scroll details",
      Some [ Config_presets ]
  ; b ~ko:"미전송 명령 복사" Act "c" "copy unsent command"
      ~help:"presets: copy the next retained unsent chat save command to the terminal clipboard",
      Some [ Config_presets ]
  ; b ~ko:"미전송 원문 보기" Act "v" "show unsent originals"
      ~help:"presets: show hidden unsent chat save receipts and their original commands",
      Some [ Config_presets ]
  ; b ~ko:"입력" Act "i" "input"
      ~help:"on prompts, the input this prompt was last given", Some [ Config_prompts ]
  ; b ~ko:"계정 추가" Act "a" "add account"
      ~help:"runtime.toml: declare an account by copying a provider", Some [ Config_runtime ]
  ; b ~ko:"기억 판정" Act "m" "recall"
      ~help:"runtime.toml: choose which keepers memory recall asks Jev about", Some [ Config_runtime ]
  ; b ~ko:"판정 서버 제외" Act "x" "exclude"
      ~help:"runtime.toml: choose which keepers no [typesafeai] gate asks a destination about",
      Some [ Config_runtime ]
  ; b ~ko:"조각" Act "a" "fragments"
      ~help:"prompts: show or hide internal fragments", Some [ Config_prompts ]
  ; b ~ko:"키퍼 목소리" Act "a" "keeper voices"
      ~help:"voice: assign a voice to a keeper", Some [ Config_voice ]
    (* [u] and the retained-draft keys come after [a]: a cut row drops them
       first, and while a draft is retained the runtime.toml pane names them
       in its own heading. *)
  ; b ~ko:"복원" Act "u" "restore"
      ~help:"presets: restore the selected preset; press twice to confirm", Some [ Config_presets ]
  ; b ~ko:"리비전 채택" Act "u" "adopt revision"
      ~help:"runtime.toml: keep the draft and adopt the displayed current file revision; S saves",
      Some [ Config_runtime ]
    (* Upper case, as Runtime's lane removal: x on the other panes puts a
       default back, and a delete cannot be put back. *)
  ; b ~ko:"삭제" Act "D" "delete"
      ~help:"on presets, delete the selected one; press twice to confirm. \
             A preset listed with ! under a valid name is deleted with \
             /preset delete <name>",
      Some [ Config_presets ]
  ; b ~ko:"저장 알림 숨기기" Act "x" "hide save notice"
      ~help:"presets: hide the most recent save notice; unconfirmed saves remain guarded",
      Some [ Config_presets ]
  ; b ~ko:"초안 저장" Act "S" "save draft"
      ~help:"runtime.toml: retry the retained draft against its original or explicitly adopted revision",
      Some [ Config_runtime ]
  ; b ~ko:"파일 비교" Act "C" "compare file"
      ~help:"runtime.toml: switch between the retained draft and the current file read with r",
      Some [ Config_runtime ]
  ; b ~ko:"현재 본문 사용" Act "U" "use current text"
      ~help:"runtime.toml: replace the retained draft with the displayed current file without writing",
      Some [ Config_runtime ]
  ; b ~ko:"초안 버리기" Act "X" "discard draft"
      ~help:"runtime.toml: discard only the local draft and read the current file",
      Some [ Config_runtime ]
  ; b ~ko:"자산" Act "o" "assets"
      ~help:"on prompts, switch between the read-only runtime assets and \
             the registry you can override",
      Some [ Config_prompts ]
  (* "back", not the destination's name: [Esc] is pinned on every row, so
     each cell of its label comes out of the pane's own keys. Spelled
     "dashboard", params at 80 columns gave up [E], its only way to the JSON
     value. The help names where it goes. *)
  ; b ~ko:"뒤로" Act "Esc" "back" ~help:"back to Dashboard", None
  ; b ~ko:"새로고침" Meta "r" "reload", None
  ; b ~ko:"다음" Meta "Tab" "next", None
  ; b ~ko:"종료" Meta "q" "quit", None
  ]

(* The Runtime keys, by the reading they act on. [p] goes somewhere different
   from each reading, so the footer names where it goes from here while the
   cheat sheet names the whole walk. The lane edits -- [e], [a], [x], [J]/[K],
   [D] -- act on the keeper lane under the cursor, and the all-runtimes reading
   has no lane row to act on. *)
type runtime_key =
  | Every_reading of binding
  | Detail_reading of binding
      (** answers only with a detail open; the footer drawn for the readings
          never names it, and the cheat sheet does *)
  | Keeper_lanes_only of binding
  | Reading_edit
  | Reading_walk

let runtime_reading_walk_help =
  "walk the three substrate readings; the third is the Features surface"

let runtime_keys =
  [ Every_reading (b ~ko:"이동 / 스크롤" Navigate "j/k" "move / scroll")
  ; Every_reading (b ~ko:"상세 페이지" Navigate "PgUp/PgDn" "detail page"
      ~help:"page an open detail; in the media editor page declared slots; while typing a lane name, PgUp opens the complete draft/context reader and Esc returns to the unchanged field")
  ; Every_reading
      (b ~ko:"상세" Act "Right / Enter" "detail"
         ~help:"show the full runtime, lane, dispatch, and probe fields")
  ; Every_reading
      (b ~ko:"거절 흐리게" Act "h" "dim refusals"
         ~help:"toggle de-emphasis for exhausted, rate-limited, and spent runtimes")
  ; Every_reading
      (b ~ko:"라우트 / 상태" Act "v" "routes / status"
         ~help:"read complete default and media routes, boot admission and probe diagnostics")
  ; Reading_walk
  ; Every_reading
      (b ~ko:"클라이언트" Navigate "c" "clients"
         ~help:"everyone attached to this workspace, off the ring under Runtime")
  ; Reading_edit
  ; Keeper_lanes_only
      (b ~ko:"새 레인" Act "a" "new lane"
         ~help:"name a new lane, then pick its first runtime; e adds the rest")
  ; Keeper_lanes_only
      (b ~ko:"후보 빼기" Act "x" "drop candidate"
         ~help:"take the candidate under the cursor out of its lane; the last one \
                cannot go, remove the lane instead")
  ; Keeper_lanes_only
      (b ~ko:"후보 순서" Act "J/K" "move candidate" ~help:"move the candidate under the cursor down or up its lane")
  ; Keeper_lanes_only
      (b ~ko:"기본 런타임" Act "f" "default runtime"
         ~help:"replace [runtime].default, what a keeper with no assignment walks")
  ; Keeper_lanes_only
      (b ~ko:"비전 런타임" Act "m" "vision runtimes"
         ~help:"edit [runtime].media_failover: j/k, PgUp/PgDn and Home/End select declared slots; a appends, x drops, J/K reorder, 1 makes first, v reads all IDs/results without closing the editor. Admission and write refusals remain in the reading")
  ; Keeper_lanes_only
      (b ~ko:"레인 이름 변경" Act "R" "rename lane"
         ~help:"give the lane under the cursor another name; the assignments \
                that route to it and [runtime].default, when it names it, are \
                rewritten in the same write. The field opens on the name it \
                has now")
  ; Keeper_lanes_only
      (b ~ko:"레인 제거" Act "D" "remove lane"
         ~help:"remove the lane under the cursor; press twice. Refused while a keeper is \
                assigned to it")
  ; Every_reading (b ~ko:"뒤로" Act "Esc" "back" ~help:"back to Config")
  ; Detail_reading
      (b ~ko:"목록" Act "Left / Esc" "list" ~help:"close the open detail, back to the list")
  ; Every_reading
      (b ~ko:"찾기" Search "/" "find" ~help:"jump the cursor to a matching lane id or runtime id")
  ; Every_reading (b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match")
  ]

let runtime_sheet_binding = function
  | Every_reading binding | Detail_reading binding | Keeper_lanes_only binding -> binding
  | Reading_edit ->
    b ~ko:"모델 설정 / 후보 추가" Act "e" "model settings / add candidate"
      ~help:"on all runtimes, open the selected binding in Config Models; \
             on keeper lanes, append a candidate to the lane under the cursor"
  | Reading_walk ->
    b ~ko:"키퍼 레인 / 전체 런타임 / 서비스 레인" Navigate "p" "keeper lanes / all runtimes / service lanes"
      ~help:runtime_reading_walk_help

let runtime_footer_binding ~(mode : runtime_mode) = function
  | Every_reading binding -> Some binding
  | Detail_reading _ -> None
  | Keeper_lanes_only binding ->
    (match mode with
     | Runtime_lanes -> Some binding
     | Runtime_all -> None)
  | Reading_edit ->
    Some
      (match mode with
       | Runtime_all ->
         b ~ko:"모델 설정" Act "e" "model settings"
           ~help:"open the selected binding in Config Models; Esc then c copies a variant"
       | Runtime_lanes ->
         b ~ko:"후보 추가" Act "e" "add candidate"
           ~help:"append a candidate to the candidate order of the lane under the cursor")
  | Reading_walk ->
    Some
      (match mode with
       | Runtime_lanes ->
         b ~ko:"전체 런타임" Navigate "p" "all runtimes" ~help:runtime_reading_walk_help
       | Runtime_all ->
         b ~ko:"서비스 레인" Navigate "p" "service lanes" ~help:runtime_reading_walk_help)

(* Ctrl-S folds the turn dashboard back to its progress line, and unfolds it.
   The terminal used to take this byte for flow control -- raw mode clears
   IXON now, which is what makes it bindable at all. A letter would not do:
   in the composer every letter is text. The Tools Available section folds
   its diagnostics with the same key: that heading is not a row the cursor
   stops on, and the letters are taken (RFC tui-one-screen-grammar, 3.1).

   The byte and the printed name sit together because the chat pane prints
   the name on the folded line while masc_tui.ml matches the byte. Apart,
   one of them drifts and the line names a key that does nothing. *)
let expand_turn_key = "\019"
let expand_turn_label = "Ctrl-S"

(* The control keys a body row names beside a figure or a draft. They are
   here, beside the bindings that list them, so a row and the footer cannot
   spell one key two ways: the composer said "^Y" under a footer saying
   "Ctrl-Y", and the context header "^X" for a key the table did not list. *)
let voice_speak_key = "Ctrl-Y"
let voice_listen_key = "Ctrl-A"
let roster_toggle_key = "Ctrl-B"
let chat_schedules_key = Masc_tui_types.chat_schedule_toggle_key
let chat_schedules_label = Masc_tui_types.chat_schedule_toggle_label

(* [t] on a keeper: the Keeper Calls view, where a call's served input and
   output are drawn whole. Named for the rows that fold a long payload and
   say where the rest is. *)
let keeper_calls_key = "t"
let keeper_chat_key = "c"

(* Ctrl-X opens the context inspector from the chat. It is named on the
   context header, beside the figure it explains, and nowhere else: the
   footer has no room for a key whose home is that row. *)
let context_inspector_key = "\024"
let context_inspector_label = "Ctrl-X"


let keepers_jump =
  b ~ko:"키퍼" Meta "3" "keepers"
    ~help:"jump to Keepers when the active field or panel does not use 3"

let mouse_toggle_key = "f2"
let mouse_toggle_label = "F2"

let global =
  [ b ~ko:"다음 / 이전 화면" Meta "Tab / Shift-Tab" "next / previous surface"
      ~help:"next / previous surface; the chat composer keeps them to complete a /command"
  ; keepers_jump
  ; b ~ko:"지금 화면 새로 조회" Meta "r" "refresh the current surface"
  ; b ~ko:"입력 줄로 가기; 운영에서는 키퍼 고르기" Meta "i"
      "focus the composer; on Dashboard, choose a Keeper"
  ; b ~ko:"명령 팔레트" Meta ":" "command palette"
  ; b ~ko:"일정: 다가오는 일과 나를 기다리는 키퍼; Enter 로 줄 열기" Meta ";"
      "agenda: what is coming, and who is waiting on you; Enter opens a row"
  ; b ~ko:"응답 중: 턴을 돌고 있거나 막 끝낸 키퍼; Enter 로 채팅 열기" Meta "@"
      "answering: who is mid-turn or just finished; Enter opens their chat"
  ; b ~ko:"이 도움말" Meta "?" "this help"
      ~help:"the keys of this screen; `?` again lists every screen, the global keys and the slash commands, and `/` finds a key or a command among them all"
  ; b ~ko:"Collab: MSX/DOS 보기와 플레이 링크 관리 (`:` go Collab 로도 열림)" Meta "&"
      "Collab: watch MSX/DOS and manage play links (also `:` go Collab)"
  ; b ~ko:"키퍼 명단 보이기 / 숨기기" Meta roster_toggle_key "show or hide the Keeper roster"
      ~help:"show or hide the Keeper roster; it starts hidden and the \
             choice persists across navigation and resizing"
  ; b ~ko:"활동 창을 좁게, 넓게, 숨김 순서로: 키퍼마다 지금 하는 일, 변경 탭에서는 고른 \
           키퍼의 파일 (머리 줄을 눌러 전환)"
      Meta "Ctrl-L"
      "the Activity pane, narrow, wide or hidden in turn: what every keeper is doing \
       right now, and on its Changes tab the selected keeper's files (press the header to switch)"
      ~help:"cycle the Activity pane narrow, wide or hidden; the wheel over the pane \
             scrolls the full list; a press picks a keeper, a second press opens its chat; \
             /activity order turns the order of its calls, /activity scroll moves the pane"
  ; b ~ko:"활동 창으로 가기" Navigate "Ctrl-W" "focus the Activity pane"
      ~help:"focus the Activity pane: a cursor lands on its first row, j/k walk the rows a press \
             acts on and scroll past the last, Enter opens or closes the call under it, \
             Esc or Ctrl-W gives the keys back; the chat keeps Ctrl-W for its draft until \
             the draft is empty"
  ; b ~ko:"브라우저 레인 보이기 / 숨기기; 탭과 스크롤은 그대로" Meta "Ctrl-^"
      "show or hide Browser Lane; retain tab and scroll"
  ; b ~ko:"마우스를 터미널에 넘기고 되받기; masc 가 쥐면 끌어서 한 창을 복사" Meta mouse_toggle_label
      "mouse to the terminal and back; with masc, a drag copies one pane"
      ~help:"the mouse starts with masc: a drag selects inside the pane it began in \
             (Keeper roster, surface or Activity pane) and copies it on release via OSC 52, \
             a press that does not move clicks, and Esc drops a selection still held; \
             F2 hands the mouse to the terminal for its own selection across the \
             whole window, and F2 again takes it back"
  ; b ~ko:"커서 아래 참조 따라가기" Navigate "Ctrl-]" "follow the reference under the cursor"
      ~help:"follow the reference under the cursor; Esc on the surface it opens comes back here"
  ; b ~ko:"종료" Meta "q" "quit"
  ]

(* The plain-listing tail every converted footer shares. *)
let listing_refresh = b ~ko:"새로 조회" Meta "r" "refresh"
let goal_candle_refresh_key = "z"
let listing_next = b ~ko:"다음 화면" Meta "Tab" "next"
let listing_quit = b ~ko:"종료" Meta "q" "quit"
let listing_meta = [ listing_refresh; listing_next; listing_quit ]

(* Tools' [r] keeps the listing's footer word, but what it reloads follows
   what is open there -- the original Task, the original request, or the
   list -- and the sheet says which. A binding of its own, so
   [sheet_bindings] keeps it where it drops the shared tail. *)
let tools_refresh =
  b ~ko:"새로 조회" Meta "r" "refresh"
    ~help:"refresh the open original Task body/history, original request \
           detail, or Tools list"

let tools_volume_gc_binding =
  b ~ko:"볼륨" Act Masc_tui_volume_gc.key "volumes"
    ~help:"in All tools, open retired Keeper volumes and request a report; \
           in that reading, an armed V reclaims only the reported names, \
           other input disarms, and Esc returns to the catalog position"

(* The views [v] walks, named from the walk itself so the sheet cannot list
   one the key skips. *)
let keeper_list_view_names =
  String.concat " / "
    (List.map Masc_tui_keeper_list_model.view_label Masc_tui_keeper_list_model.views)

let keeper_actions =
  [ b ~ko:"채팅" Act keeper_chat_key "chat" ~help:"chat with the keeper"
  ; b ~ko:"로그" Act "l" "logs"
  ; b ~ko:"호출" Act keeper_calls_key "calls" ~help:"tool calls"
  ; b ~ko:"런타임" Act "u" "runtime" ~help:"pick a runtime candidate order"
  ; b ~ko:"yolo / auto" Act "g" "yolo / auto" ~help:"toggle yolo / auto tool approval"
  ; b ~ko:"일시 정지 / 깨우기" Act "p / w" "pause / wake"
  ; b ~ko:"내리기" Act "s" "shutdown"
  ; b ~ko:"설정 TOML/JSON" Act "e/E" "settings TOML/JSON"
  ; b ~ko:"파일" Act "f" "files" ~help:"file changes this keeper wrote"
  ; b ~ko:"새 키퍼" Act "a" "new" ~help:"new keeper"
  ; b ~ko:"삭제" Act "x" "delete" ~help:"stop and permanently remove the confirmed keeper"
  ; b ~ko:"삭제 기록" Navigate "D" "deletions" ~help:"durable deletion records, failures and cleanup retry"

  ]

(* The keys that move a row list by more than a step. Shared rather than
   retyped per surface: they answer wherever [row_list] in masc_tui.ml finds a
   list, and that is one decision, so the table should not be able to claim
   them for one listing and forget them on the next. Each needs a row: with
   [rl_count = 0] the dispatcher answers them with [()]. *)
let row_list_page = b ~ko:"페이지" ~rows:Needs_row Navigate "PgUp/PgDn" "page"
let row_list_jumps =
  [ row_list_page
  ; b ~ko:"처음/끝" ~rows:Needs_row Navigate "Home/End" "top/bottom"
  ]

(* The same two, minus the page key, for the surfaces whose own entry already
   spells one because a detail pane under them pages too. *)
let row_list_edges = [ b ~ko:"처음/끝" ~rows:Needs_row Navigate "Home/End" "top/bottom" ]

(* The two keys the whole surface exists for, as one binding. Spelled apart
   ("y" and "n") they were two items a fitted row could drop one at a time,
   and the row that cannot lose the way to answer keeps its keys by that
   spelling: [Masc_tui_footer.never_dropped_keys] pins "y / n", which the open
   approval's own footer never said. *)
let approval_decide =
  b ~ko:"승인 / 거절" Act "y / n" "decide" ~help:"y confirms, n denies the approval under the cursor"

let approval_retry =
  b ~ko:"Auto Judge 다시" Act "R" "retry Auto Judge"
    ~help:"only when the blocked row is safely rearmable"

let approval_move = b ~ko:"선택" Navigate "j/k" "move"
let approval_read =
  b ~ko:"요청 전체 읽기" Act "Enter" "read the whole ask"
    ~help:"the reader takes its own keys: j/k and the page keys scroll it, \
           Home/End reach its ends, [ / ] step asks, Esc goes back"
let approval_value_bytes =
  b ~ko:"문자열 바이트" Navigate "v" "string bytes" ~detail:Detail_only
    ~help:"read decoded top-level Gate string values as bytes, not JSON wire; v or Esc returns"
let approval_answer_receipt =
  b ~ko:"마지막 답변" Navigate "v" "last answer" ~detail:List_only
    ~help:"while browsing, capture the last answer receipt, original question identity and retained follow-up; scroll or search the complete text; v or Esc returns"
let approval_answer =
  b ~ko:"질문에 답하기" Act "a" "answer a question"
    ~help:"open the selected question, from a Keeper or a Lane Add-on installation, in its own mode; Esc leaves it"
let approval_answer_hint = key_hint approval_answer
let approval_installation_results =
  b ~ko:"설치 결과" Act "g" "installation Results"
    ~help:"after answering an installation's question, open that installation's Results in Plugins, where the reveal appears"
let approval_origin =
  b ~ko:"출처 / 살펴보기" Act "o / O" "source / inspect"
    ~help:"o shows the question source; O opens that immutable turn's retained input. With no open question use the last answer's source. Esc returns to the question draft; a missing source is never replaced by the Keeper's latest turn"
let approval_walk =
  b ~ko:"요청" Navigate "[ / ]" "ask"
    ~help:"while browsing or answering a question, move to the previous or next ask; \
           with an approval detail open, move to the previous or next approval"
let approval_workspace =
  b ~ko:"작업 공간 모드" Act "w" "Workspace mode"
    ~help:"choose manual, Auto Judge or allow-all; Enter applies, Esc cancels"
let approval_outside =
  b ~ko:"외부 모드" Act "e" "Outside mode"
    ~help:"choose how calls into outside services are reviewed; Enter applies"
let approval_question =
  b ~ko:"질문" Navigate "Left/Right" "question"
    ~help:"while answering, step through the open ask's questions; \
           j/k and the arrows do the same"
let approval_pick =
  b ~ko:"고르기" Act "1-9" "pick"
    ~help:"while answering, choose by the position the server listed"
let approval_write =
  b ~ko:"쓰기" Act "t" "write"
    ~help:"while answering, open the free-text editor; Enter saves it, \
           Esc drops it"
let approval_skip =
  b ~ko:"건너뛰기" Act "s" "skip"
    ~help:"while answering, leave this question unanswered"
let approval_clear =
  b ~ko:"지우기" Act "c" "clear"
    ~help:"while answering, drop what is drafted for this question"
let approval_back =
  b ~ko:"뒤로" Act "Esc" "back"
    ~help:"leave the answering mode; with the editor open it drops the draft first"

(* Where a Fusion run's caller and its Board evidence are, on the list and
   in the detail alike: one binding each, so the two footers cannot name the
   key two ways. *)
(* The keys a post answers to, in the Board's surface list and in the read
   footer alike. The read pane spelled them a second time in its own row --
   "[c] Reply   [v/V] Vote (+/-)   [Y] Copy Link   [Esc] Back" -- above a
   footer that spelled c, Y and Esc again and had no vote key at all, so that
   row was the only place on the screen that said v votes. *)
let board_vote_key =
  b ~ko:"추천 / 비추천" Act "v / V" "up / down"
    ~help:"press twice to vote: v up, V down; while reading, on the selected \
           comment when the comments have focus, otherwise on the post"
let board_reply_key =
  b ~ko:"댓글" Act "c" "reply" ~detail:Detail_only ~help:"reply (while reading)"
let board_copy_key = b ~ko:"링크 복사" Act "Y" "copy link" ~help:"copy the selected post reference"
let board_read_focus_key =
  b ~ko:"본문 / 댓글" Navigate "b" "post / comments" ~detail:Detail_only
    ~help:"switch the focused reading window; on the comments, j/k select a \
           comment and PgUp/PgDn scroll by rows"

(* Both read the run under the cursor. On the list with no run they answer
   with a notice and move nothing; an open run has its own footer. *)
let fusion_caller_key = b ~ko:"부른 키퍼" ~rows:Needs_row Navigate "K" "calling Keeper"
let fusion_board_key = b ~ko:"게시판 근거" ~rows:Needs_row Navigate "B" "Board evidence"

let keeper_navigation_hints ~lang =
  match lang with
  | Masc_tui_types.Lang_ko -> "Up/Down:선택  Enter:열기  Right/Esc:뒤로"
  | Masc_tui_types.Lang_en -> "Up/Down:move  Enter:open  Right/Esc:back"

let tools_bracket_binding ~pane =
  let ko, label = match pane with
    | Tools_surface -> "실행", "run"
    | Tools_async | Tools_activations | Tools_usage | Tools_storage
    | Tools_catalog (Tools_catalog_list | Tools_catalog_volumes _) -> "키퍼", "Keeper"
  in
  b ~ko Navigate "[ / ]" label
    ~help:"in Available, older/newer retained original run; in other panes, previous/next Keeper"

type metrics_key_scope =
  | Metrics_all
  | Metrics_usage
  | Metrics_usage_sections of usage_section list
  | Metrics_telemetry

let metrics_bindings =
  [ b ~ko:"스크롤" Navigate "j/k" "scroll", Metrics_all
  ; b ~ko:"사용량 / 진단" Navigate "p" "Usage / Telemetry"
      ~help:"switch between quota and Keeper usage, and engine telemetry", Metrics_all
  ; b ~ko:"계정 선택" Navigate "f" "account"
      ~help:"search quota accounts; selection follows Plan and Trend", Metrics_usage_sections [Usage_plan; Usage_trend]
  ; b ~ko:"전체 계정" Navigate "a" "all accounts"
      ~help:"clear the quota account selection", Metrics_usage_sections [Usage_plan; Usage_trend]
  ; b ~ko:"한도 그룹 표시" Navigate "x" "toggle limit group"
      ~help:"on Plan: show or hide the group for reports at limit or observed exhaustion", Metrics_usage_sections [Usage_plan]
  ; b ~ko:"보기" Navigate "v / V" "view"
      ~help:"cycle the Usage reading: Plan, Trend, Keepers, Calls; V goes back", Metrics_usage
  ; b ~ko:"1 / 7 / 14일" Navigate "w" "1d / 7d / 14d"
      ~help:"on Usage: cycle the exact UTC day window for provider report history and tool calls", Metrics_usage_sections [Usage_trend; Usage_calls]
  ; b ~ko:"지표 선택" Navigate "1 / 2 / 3" "telemetry section"
      ~help:"on Telemetry: Engine, Work, or Tools", Metrics_telemetry
  ; b ~ko:"뒤로" Act "Esc" "Dashboard", Metrics_all
  ; b ~ko:"새로 조회" Meta "r" "refresh", Metrics_all
  ; b ~ko:"다음" Meta "Tab" "next", Metrics_all
  ; b ~ko:"종료" Meta "q" "quit", Metrics_all
  ]

let memory_browser_pages =
  [ b ~ko:"최근 / 조회 / 변화 / 저장" Act "1 / 2 / 3 / 4" "recent / retrievals / changes / storage"
      ~help:"one Memory browser; changes require an individual Keeper, while storage opens the fleet health view" ]

let for_surface = function
  | Overview ->
      [ b ~ko:"조치 원인" Navigate "v" "action reasons"
          ~help:"read every reason in the last server rollup; scroll and search the captured reading; Esc returns without changing a decision or setting"
      ; b ~ko:"키퍼" Navigate "Left" "Keepers" ~help:"open the Keeper list; Enter opens a chat; Right or Esc returns"
      ; b ~ko:"선택" Navigate "j/k" "choose" ~help:"select a destination"
      ; b ~ko:"열기" Navigate "Enter" "open" ~help:"open the selected destination; never approve"
      ; b ~ko:"승인·질문" Navigate "p" "requests" ~help:"approvals and questions"
      ; b ~ko:"퀴즈" Navigate "g" "quiz" ~help:"the operator quiz's Results: scorecard windows and wrong-answer notes"
      ; b ~ko:"일정·요청" Navigate ";" "agenda" ~help:"held calls, questions, Goal confirmations and tasks on the operator list"
      ; b ~ko:"사용량" Navigate "m" "Usage" ~help:"account windows and Keeper usage"
      ; b ~ko:"음악" Navigate "s" "music" ~help:"phrases, arrangements and recorded takes; no Keeper or score required"
      ]
      @ listing_meta
  | Acting ->
      [ b ~ko:"이벤트 / 로그" Navigate "e / l" "Events / Logs"
          ~help:"Events, or the server's own log lines"
      ; b ~ko:"선택" Navigate "j/k" "move" ~help:"select an event / scroll its evidence"
      (* [Navigate], not [Act]: the group is documented as "doing something to
         the thing under the cursor", and this key does nothing to the event
         the cursor is on -- it chooses which events the list holds at all,
         the way Planning spells its own filter. The group is also the
         retention order, so in [Act] this key was given up before
         [Home/End]. *)
      ; b ~ko:"거르기" Navigate "f" "filter" ~help:"cycle Turns / Actions / Everything; Turns has no individual event evidence"
      (* "evidence", not "event evidence": every row on this surface is an
         event, so the label was saying the surface's own subject back to the
         reader. The six cells it gives back are what lets [f] stay on the row
         beside it -- see the footer case in test_tui_keys. *)
      ; b ~ko:"증거" Act "Enter" "evidence" ~detail:List_only ~rows:Needs_reading
          ~help:"Actions/Everything: exact selected event; Turns are aggregates"
      (* One key, one row. Esc closes the evidence pane when one is open
         (masc_tui.ml guards the close on acting_detail) and otherwise
         leaves the surface, so two rows read as two bindings. *)
      ; b ~ko:"뒤로" Act "Esc" "back"
          ~help:"close event evidence; from the list, back to Dashboard"
      (* One row per action. g and G reach the ends Home and End reach, and
         l the tab 2 opens; a row for each spent two of the footer's places
         on actions it already showed, and at 120 columns the fitter dropped
         Enter -- the key that opens an event -- to keep them. The rows are
         the spellings every other reader shares; the extras are in help. *)
      ; b ~ko:"최신 / 처음" Navigate "Home/End" "newest / oldest"
          ~help:"g and G as well; the ring counts back from the newest, so \
                 its top is now"
      ; b ~ko:"다음 화면" Meta "Tab" "next"
      ; b ~ko:"종료" Meta "q" "quit"
      ]
  | Metrics ->
      List.map fst metrics_bindings
  | Keepers Keeper_list ->
      (b ~ko:"선택" Navigate "j/k" "move"
         ~help:"move the roster cursor; a grouping view also stops on each group heading")
      :: (b ~ko:"보기" Navigate "v" "view"
            ~help:("cycle " ^ keeper_list_view_names ^ "; a press on a name opens that view"))
      :: (b ~ko:"줄 수" Navigate "V" "density" ~help:"one or two lines per Keeper")
      :: (b ~ko:"그룹" Navigate "[ / ]" "group"
            ~help:"jump to the previous or next group heading in a grouping view")
      :: (b ~ko:"접기 / 펴기" Navigate "Left / Right" "fold" ~help:"on a group heading, fold or unfold its rows")
      :: (b ~ko:"정렬" Navigate "o" "order" ~help:"cycle priority / recent / oldest / activity / name")
      :: (b ~ko:"일정" Act "J" "jobs" ~help:"open the selected Keeper's schedules")
      :: (b ~ko:"Keeper 요청" Act "K" "relations" ~help:"browse Keeper-origin requests queued for the selected Keeper")
      :: (b ~ko:"Story" Act "Enter" "story"
            ~help:"open the selected Keeper Story or shared World window; Enter closes its story/world page")
      :: (b ~ko:"World" Act "W" "world"
            ~help:"select shared World and open its dock; outside memory/age, switch to age; lowercase w still wakes a Keeper")
      :: (b ~ko:"상세" Act "Right" "detail" ~help:"keeper detail")
      :: (b ~ko:"관측 오류" Act "!" "read errors"
            ~help:"read every current Keeper-list observation error and its complete reason; Esc returns")
      :: (b ~ko:"쪽" Act "Tab / s / m" "pages"
            ~help:"with a Keeper Story open: next page / schedules / memory; World keeps its own page; Esc closes either window")
      :: (b ~ko:"기억" Act "1 / 2 / 3 / 4" "memory"
            ~help:"with Keeper Memory preview open: browse recent records / retrievals / committed changes / storage in the shared Memory browser; Enter also opens recent records")
      :: keeper_actions
      @ [ b ~ko:"찾기" Search "/" "search" ~help:"search names; Enter keeps the query"
        ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match"
        ; b ~ko:"뒤로" Act "Esc" "dashboard"
        ]
      @ row_list_jumps @ listing_meta
  | Keepers Keeper_detail ->
      [ b ~ko:"창" Navigate "h/l" "pane" ~help:"move between roster and detail"
        (* The tabs come from the list the strip draws. Named by hand this row
           said "Info / Settings / Secrets / GitHub" while the strip drew
           nine, so a reader who trusted the sheet did not know Sandbox,
           Identity, Channels, Automation or Runs existed -- and Sandbox is
           the second tab. Config's [p] had the same drift and a test to
           catch it; this row cannot drift at all now. *)
      ; b ~ko:"탭" Navigate "[ / ]" "tabs"
          ~help:
            ("detail tabs: "
             ^ String.concat " / "
                 (List.map Masc_tui_types.keeper_detail_tab_label
                    Masc_tui_types.keeper_detail_tabs))
      ; b ~ko:"로그" Act "o" "logs"
          ~help:"open container logs in Sandbox; Keeper activity elsewhere"
      ; b ~ko:"런타임" Act "U" "runtime"
          ~help:"pick a runtime candidate order (on the Channels tab U is unbind all)"
      ; b ~ko:"뒤로" Act "Left / Esc" "back"
      ; b ~ko:"처음/끝" Navigate "Home/End" "top/bottom" ~help:"the ends of this tab"
      ]
      @ List.filter
          (fun binding -> binding.key <> "l" && binding.key <> "u")
          keeper_actions
  | Keepers Keeper_logs ->
      (* The shared tail was missing here while the renderer's own footer
         string carried it, so the sheet and the footer disagreed about
         whether r/q worked on this screen. *)
      (* The page and edge keys have arms of this screen's own (masc_tui.ml:
         [home] and [end] set [log_scroll], and the page dispatcher walks the
         tail window), and the table named none of them. Rows are drawn newest
         first, so these two are not the top and bottom of a list: Home is
         now and End is the oldest row the tail window holds. *)
      [ b ~ko:"스크롤" Navigate "j/k" "scroll"
      ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
      ; b ~ko:"지금 / 처음" Navigate "Home/End" "now / oldest"
      ; b ~ko:"뒤로" Act "Left / Esc" "back"
      ]
      @ listing_meta
  | Keepers Keeper_calls ->
      [ b ~ko:"스크롤" Navigate "j/k" "scroll"
      ; b ~ko:"처음/끝" Navigate "Home/End" "top/bottom"
      ; b ~ko:"뒤로" Act "Left / Esc" "back"
      ]
      @ listing_meta
  | Keepers Keeper_message ->
      [ b ~ko:"목록" Navigate "Left" "roster" ~help:"empty composer: open the Keeper list; with text: move the cursor left"
      ; b ~ko:"채팅" Navigate "Right" "chat"
          ~help:"roster focused: return focus to the chat composer"
      ; (* One key, several jobs: the roster when it holds focus, the history
           when the chat is scrolled back, the completions while a /command is
           typed, and otherwise the lines the operator sent. Listed once so the
           table keeps the one-key-one-row contract (#33236). *)
        b ~ko:"목록 선택 / 스크롤" Navigate "Up / Down" "roster move / scroll"
          ~help:
            "roster focused: move; chat scrolled back: adjust by one line; \
             while a /command is typed: pick among its completions; \
             otherwise walk the history of lines you sent: Up recalls the \
             previous one (a line still waiting in the queue comes back as \
             an edit of that line), Down steps back toward your draft"
      ; b ~ko:"전송 / 열기" Act "Enter" "send / open"
          ~help:"send from chat, or open the selected Keeper from the roster"
      ; b ~ko:"줄바꿈" Act "Ctrl-J" "newline"
          ~help:"newline in the draft; Shift-Enter does the same where the terminal reports it"
      ; b ~ko:"자동 완성" Act "Tab / Shift-Tab" "complete"
          ~help:
            "complete the /command being typed, or its argument such as a \
             Keeper name; the chat composer keeps these keys, so they do not \
             switch surface here"
      ; b ~ko:"말하기" Act voice_speak_key "speak"
          ~help:"record into the draft; again to stop and keep what was said"
      ; b ~ko:"계속 듣기" Act voice_listen_key "keep listening"
          ~help:"continuous capture on/off: each sentence starts the next capture"
      ; b ~ko:"다음 키퍼" Act "Ctrl-G" "next keeper" ~help:"next keeper with a chat open"
      ; b ~ko:"지우기" Act "Ctrl-U" "clear" ~help:"clear the draft"
      ; b ~ko:"대기 줄" Act "Ctrl-K / Ctrl-P" "queued line"
          ~help:"cancel / edit the last queued line"
      ; b ~ko:"일정 상태" Act chat_schedules_label "Job status"
          ~help:"fold or expand this Keeper's scheduled Jobs, pending occurrences, holds and latest result"
      ; b ~ko:"대기열" Act "Ctrl-T" "queue"
          ~help:"inspect and manage waiting turns"
      ; b ~ko:"이전 대화" Navigate "PgUp/PgDn" "history" ~help:"scroll history by a page"
      ; b ~ko:"최신" Navigate "Ctrl-E / End" "newest"
          ~help:"after reading back, jump to the newest row"
      ; b ~ko:"추론" Act "Ctrl-R" "reasoning" ~help:"cycle reasoning hidden / folded / full"
      ; b ~ko:"도구 상세" Act "Ctrl-D" "tool detail" ~help:"cycle compact / results / full tool detail"
      ; b ~ko:"턴 상세" Act expand_turn_label "turn detail"
          ~help:
            "unfold the running turn's status rows, or fold them back to the \
             progress line"
      ; b ~ko:"기록 상세" Act "Ctrl-N" "journal detail"
          (* The three words are the states' own, the way Ctrl-R above spells
             its own. Pressing this answers "Librarian/Memory timeline: full",
             so a help promising "full detail" sends a reader looking for a
             state the pane never names. *)
          ~help:"cycle Memory journal summary / full / hidden"
      ; b ~ko:"메시지 정보" Act "Ctrl-F" "message metadata"
          ~help:"cycle no clock / inline clock / full timestamp and request id"
      ; b ~ko:"이미지 / 다이어그램" Act "Ctrl-O" "image / diagram"
          ~help:"preview the newest image or Mermaid diagram; /images lists all; any key returns"
      ; b ~ko:"이미지 붙여넣기" Act "Ctrl-V" "paste image"
          ~help:"paste the clipboard image: it is staged for the next message and an [Image #1] marker lands in the draft"
      ; b ~ko:"승인 / 거절" Act "/approve /deny" "approval" ~help:"type a command and Enter to answer a tool approval"
      ; b ~ko:"답 복사" Act "/copy" "copy reply"
          ~help:"send the selected Keeper's latest completed reply to the terminal clipboard via OSC 52"
      ; b ~ko:"나가기" Act "Q / Ctrl-Q" "leave"
          ~help:"Q on an active turn with an empty draft or hidden composer; Ctrl-Q always leaves without interrupting"
      ; (* One key, two focuses, listed once for the reason [Up / Down] above
           is: the dispatcher reads Esc from the roster as the way back to the
           composer and from the chat as the way off the screen. Spelled as two
           bindings, both reached the same row and the footer drew
           [Right / Esc:chat] and [Esc:back] side by side. *)
        b ~ko:"채팅 / 뒤로" Act "Esc" "chat / back"
          ~help:
            "roster focused: return to the composer; chat focused: back, and \
             during a turn interrupt it"
      ]
  | Keepers Keeper_runtime_pick ->
      (* The picker claims its own keys through [Masc_tui_pick_list], page and
         edge among them, and the table carried both inside [j/k]'s help
         instead of declaring them. Prose there reaches the sheet and never
         the footer.

         Only the page pair is declared: measured through the fitter at
         eighty cells, declaring both costs [d] and [/] their place, and [d]
         is the one key this screen exists for. [d]'s label is shortened in
         the same breath -- with "use the default" spelled out it did not fit
         beside the page pair either, and its help still says what it drops
         and what it follows. The edge pair stays in the help until #39082
         decides what this screen owes a guard that reads help for key
         names. *)
      [ b ~ko:"선택" Navigate "j/k" "move" ~help:"move; Home/End jump to the top or bottom"
      ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
      ; b ~ko:"필터" Navigate "/" "filter"
          ~help:"type to narrow the lanes and runtimes; Esc drops the filter"
      ; b ~ko:"고르기" Act "Enter" "choose"
      ; b ~ko:"기본값" Act "d" "default"
          ~help:"drop this Keeper's own binding and follow [runtime].default"
      ; b ~ko:"뒤로" Act "Esc" "back"
      ]
  | Lanes ->
      [ b ~ko:"선택" Navigate "j/k" "move" ~help:"move the lane cursor"
      (* One destination, two keys. [o] came from #35915 and [A] from #35761,
         and each arrived with its own binding and its own wording -- the
         footer then spent two of its items saying "Lane Add-ons" and
         "add-ons", the heading named [o], and the guide named [A]. The
         dispatch was one arm the whole time ([Some "o" | Some "O" | Some "A"]
         on Lanes), so the table says so too. Both keys stay: a PTY walk
         presses [A] and the guide's first line names it. *)
      ; b ~ko:"플러그인" Navigate "o / A" "Plugins"
          ~help:"inspect Lane Add-on declarations, instances and observations"
      ; b ~ko:"전체 읽기" Navigate "d" "reading" ~help:"read the selected Lane's complete configuration and observation"
      ; b ~ko:"문제 읽기" Navigate "i" "read issues" ~help:"read inventory problems without hiding the Lane list"
      ; b ~ko:"열기" Act "Right / Enter" "open"
          ~help:"open exact runs, the selected Browser or machine, or a package configuration/instance"
      ; b ~ko:"exact 슬롯 추가" Act "a" "exact: add slot"
          ~help:"add a candidate to the selected exact-output lane's walk order"
      ; b ~ko:"켜고 끄기" Act "Space" "activity"
          ~help:"open Exact or machine activity settings; Space changes the draft, s saves explicitly; Required Exact lanes cannot be off"
      ; b ~ko:"exact 모델" Act "s" "exact: models"
          ~help:"edit the model order: r replaces the selected model/effort, \
                 a adds a fallback, 1 makes it first within its HTTP/CLI group, \
                 x removes, J/K reorders, Enter/d opens the selected \
                 slot's config table, e opens the lane table, Esc closes; \
                 HTTP runs before CLI"
        (* The lane detail spent four rows on the file's shape and on this
           key, the same two sentences under every lane. They are here, where
           the key is. *)
      ; b ~ko:"exact 설정" Navigate "e" "exact: config"
          ~help:
            "open this lane's runtime.exact_output_lanes section in the \
             preview-checked runtime.toml editor; slots is a catalog-ref array \
             and cli_slots an official-client runtime-id array, either may be \
             left out, and an enabled lane needs one slot across the two"
      ; b ~ko:"exact 출력" Navigate "[ / ]" "exact output"
          ~help:
            "on a Lane Add-on package row, choose one of its exact outputs; the \
             preview lists each with its binding: bound, unbound, off, or a \
             table the package does not declare. e then opens that output's \
             runtime.addon_exact_lanes table, or says runtime.toml has none yet"
      ; b ~ko:"런타임" Navigate "p" "runtime"
          ~help:"open the Runtime surface"
      ; b ~ko:"뒤로" Act "Esc" "dashboard" ~help:"back to Dashboard"
      ; b ~ko:"찾기" Search "/" "find"
          ~help:"jump the cursor to a matching lane; the run list \
                 and a run's detail carry no searchable rows"
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match"
      ]
      @ row_list_jumps @ listing_meta
  | Clients ->
      [ b ~ko:"선택" Navigate "j/k" "move" ~rows:Needs_row ~help:"move the roster cursor"
      ; b ~ko:"상세" Act "Enter" "detail" ~rows:Needs_row
          ~help:"read the client's full identity and observation"
      ; b ~ko:"기능" Act "p / Esc" "features"
          ~help:"back to Features & plugins"
      ; b ~ko:"찾기" Search "/" "find" ~rows:Needs_row
          ~help:"jump the cursor to a matching attached name"
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match" ~rows:Needs_row
      ]
      @ row_list_jumps @ listing_meta
  | Board ->
      [ b ~ko:"선택" Navigate "j/k" "move"
      ; b ~ko:"읽기" Act "Right / Enter" "read" ~help:"read the post"
        (* Left closes the open post and does nothing on the list
           ([Board_list | Board_compose -> ()] in the [Some "left"] arm of
           masc_tui.ml); Esc leaves the list for the Dashboard. One row per
           state, so the list footer stops offering a key that does nothing
           there. *)
      ; b ~ko:"뒤로" Act "Esc" "back" ~detail:List_only ~help:"back to Dashboard"
      ; b ~ko:"뒤로" Act "Left / Esc" "back" ~detail:Detail_only ~help:"close the post"
      ; b ~ko:"글쓰기" Act "w" "write" ~help:"write a post"
      ; board_vote_key
      ; board_reply_key
      ; b ~ko:"첨부" Navigate "1–9" "attachment" ~detail:Detail_only
          ~help:"preview a stored image or read a stored File/Score here; other media use their existing action"
      ; b ~ko:"원본 이미지" Navigate "O" "original image" ~detail:Detail_only
          ~help:"after selecting a stored image, read it and open or save its verified original"
      ; b ~ko:"다이어그램" Navigate "Ctrl-O" "diagram" ~detail:Detail_only
          ~help:"preview the selected post or comment's Mermaid diagram"
      ; b ~ko:"다이어그램 선택" Navigate ", / ." "diagram choice" ~detail:Detail_only
          ~help:"choose the previous or next Mermaid diagram in the selected post or comment"
      (* Three keys below answer only while a post is open, and the table said
         so in prose the footer cannot read. The list footer named them and
         the dispatcher refused all three there: [[ / ]] steps the open post
         ([step_board_read] returns on [Board_list]), [z] and [h/l] want a
         detail pane beside the list. *)
      ; b ~ko:"후속 글" Navigate "S" "successor" ~detail:Detail_only
          ~help:"follow the closed post's recorded successor; Esc returns to this post"
      ; b ~ko:"이전 / 다음 글" Navigate "[ / ]" "previous / next post" ~detail:Detail_only
          ~help:"while reading, open the post before or after this one"
      ; b ~ko:"정렬" Navigate "s" "sort" ~help:"cycle hot / trending / recent / updated / discussed"
      ; b ~ko:"다음 / 이전 게시판" Search "f / F" "next / previous hearth"
          ~help:"move forward or backward through all hearths"
      ; b ~ko:"게시판 선택" Search "H" "choose hearth" ~help:"search hearth names and choose directly"
      ; b ~ko:"상세 넓히기" Navigate "z" "wide detail" ~detail:Detail_only
          ~help:"hide or show the post list while reading"
      ; board_read_focus_key
      ; board_copy_key
      ; b ~ko:"영역" Navigate "Ctrl-W" "pane"
          ~help:"cycle the post list, the detail pane, and the Activity pane when it is drawn"
      ; b ~ko:"영역" Navigate "h/l" "pane" ~detail:Detail_only
          ~help:"focus the post list or detail pane"
        (* Beside [f], not instead of it: [f] narrows the list to one hearth,
           this jumps the cursor to a post without changing what is listed. *)
      ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
          ~help:"page through the focused post list, body, or comments"
      ; b ~ko:"찾기" Search "/" "find" ~help:"jump the cursor to a matching post id, author or title"
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match"
      ]
      @ row_list_edges @ listing_meta
  | Approvals ->
      [ approval_move
        (* The list draws each ask on one row. Enter is where a multi-line
           argument is readable before y answers it. *)
      ; approval_read
      ; approval_value_bytes
      ; approval_answer_receipt
      ; approval_decide
      ; approval_retry
        (* The footer names this key and the sheet did not, so an operator who
           pressed [?] to find out how to answer a Keeper's question found
           every other key on the surface and not that one. The approval queue
           owns this surface's arrows and its y/n, which is why answering
           opens as its own mode rather than as a key on the row. *)
      ; approval_answer
      ; approval_installation_results
      ; approval_origin
      ; approval_walk
      ; approval_workspace
      ; approval_outside
        (* The answering mode's own keys. It opens with [a] and rewrites the
           footer entirely, so the sheet was the only place left to learn
           them -- and it named none: [?] on this surface found every
           browsing key and nothing about answering a question. Each help
           says when the key answers, the way [[ / ]] above does. *)
      ; approval_question
      ; approval_pick
      ; approval_write
      ; approval_skip
      ; approval_clear
      ; approval_back
      ]
      @ row_list_jumps @ listing_meta
  | Planning ->
      (* With no Goal on the list, the keys that read the one under the cursor
         do nothing or answer with a notice. [b], [t], [p], [v], [f] and [s]
         still act: a filter that leaves no Goal is undone with [f]. *)
      [ b ~ko:"선택" Navigate "j/k" "move" ~rows:Needs_row
      ; b ~ko:"요약" Act "b" "summary" ~detail:List_only
          ~help:"read captured Goal totals, the global Task backlog, history, and snapshot changes"
        (* [t] and [p] answer on the list only. In a Goal detail [p] is Pause
           and [r] is Resume (the Actions row), so the detail footer must not
           name [p] as Approvals. *)
      ; b ~ko:"목표 / 작업" Navigate "t" "Goals / Tasks" ~detail:List_only
          ~help:"switch between Goals and the active task list"
      ; b ~ko:"승인" Navigate "p" "Approvals" ~detail:List_only
          ~help:"open operator approvals and Keeper questions; Esc returns to Work"
      ; b ~ko:"다음 작업 탭" Navigate "v" "next Work tab"
          ~help:"Goals, then the two task surfaces: Task Review and \
                 Task Verdicts. Not stages of one flow"
      ; b ~ko:"상세" Act "Right / Enter" "detail" ~detail:List_only ~rows:Needs_row
        (* Left only closes an open Goal or Task detail ([Planning_list -> ()]
           in the [Some "left"] arm of masc_tui.ml); Esc also leaves Work. *)
      ; b ~ko:"뒤로" Act "Esc" "back" ~detail:List_only ~help:"leave Work for the Dashboard"
      ; b ~ko:"뒤로" Act "Left / Esc" "back" ~detail:Detail_only ~help:"close the detail"
      ; b ~ko:"필터" Navigate "f" "filter" ~help:"cycle all / active / completed / dropped"
      ; b ~ko:"정렬" Navigate "s" "sort" ~help:"cycle phase / updated / due"
      ; b ~ko:"이전 / 다음" Navigate "[ / ]" "previous / next" ~detail:Detail_only
          ~help:"while a detail is open, step to the row before or after it"
      ; b ~ko:"완료 요청" Act "c" "request completion" ~detail:Detail_only
          ~help:"in Goal detail, request completion or recovery; press again to submit"
      ; b ~ko:"근거 확인" Act "a" "confirm proof" ~detail:Detail_only
          ~help:"in Goal detail, read the proof; confirm it after it is shown and awaiting confirmation"
      ; b ~ko:"중단" Act "x" "drop" ~detail:Detail_only
          ~help:"in Goal detail, enter a reason and press Enter"
      ; b ~ko:"다시 열기" Act "o" "reopen" ~detail:Detail_only
          ~help:"in Goal detail, press twice to request reopening"
      ; b ~ko:"Candle" Act goal_candle_refresh_key "Candle" ~rows:Needs_row
          ~help:"open the selected Goal's Candle payout from the list, or read it again in detail"
      ; b ~ko:"링크 복사" Act "Y" "copy link" ~rows:Needs_row
          ~help:"copy the selected goal reference"
        (* Over the goals [f] and [s] left on screen, in the order they are
           drawn: the search walks what the list shows, not the snapshot. *)
      ; b ~ko:"찾기" Search "/" "find" ~detail:List_only ~rows:Needs_row
          ~help:"jump the cursor to a matching goal id or title"
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match" ~detail:List_only
          ~rows:Needs_row
      ]
      @ row_list_jumps @ listing_meta
  | Schedules ->
      [ b ~ko:"선택" Navigate "j/k" "move" ~rows:Needs_row
          ~help:"move; in details, scroll the payload"
      ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page" ~rows:Needs_row
      ; b ~ko:"이전 / 다음 쪽" Navigate "< / >" "schedule pages" ~detail:List_only
          ~help:"previous / next server page; pages are separate observations"
      ; b ~ko:"상세" Act "Right / Enter" "details" ~detail:List_only ~rows:Needs_row
          ~help:"open schedule details"
      ; b ~ko:"뒤로" Act "Esc" "back" ~detail:List_only ~help:"back to Work"
      ; b ~ko:"뒤로" Act "Left / Esc" "back" ~detail:Detail_only
          ~help:"back to the schedule list"
      ; b ~ko:"이전 / 다음" Navigate "[ / ]" "previous / next" ~detail:Detail_only
          ~help:"while a detail is open, step to the row before or after it"
      ; b ~ko:"새 일정" Act "n" "new" ~help:"create a schedule through a $EDITOR JSON form"
      ; b ~ko:"편집" Act "e" "modify" ~rows:Needs_row
          ~help:"edit the selected active schedule; running/finished rows refuse"
      ; b ~ko:"취소" Act "x" "cancel" ~rows:Needs_row ~help:"arm / confirm cancellation"
      ; b ~ko:"링크 복사" Act "Y" "copy link" ~rows:Needs_row
          ~help:"copy the selected schedule reference"
      ]
      @ row_list_edges @ listing_meta
  | Verification ->
      [ b ~ko:"선택" Navigate "j/k" "move" ~rows:Needs_row
          ~help:"move; in details, scroll the evidence"
      ; b ~ko:"다음 작업 탭" Navigate "v" "next Work tab"
          ~help:"on to Task Verdicts, then back to Goals"
      ; b ~ko:"대기 / 기록" Navigate "h" "queue / history"
          ~help:"the queue is what a task is still waiting on; the history is \
                 every request ever submitted, which nothing removes"
      ; b ~ko:"상세" Act "Right / Enter" "details" ~detail:List_only ~rows:Needs_row
          ~help:"read the request and evidence"
      ; b ~ko:"뒤로" Act "Esc" "back" ~detail:List_only ~help:"back to Work"
      ; b ~ko:"뒤로" Act "Left / Esc" "back" ~detail:Detail_only ~help:"back to the list"
      ; b ~ko:"이전 / 다음" Navigate "[ / ]" "previous / next" ~detail:Detail_only
          ~help:"while a detail is open, step to the row before or after it"
      ; b ~ko:"최근 / 앞선 쪽" Navigate "< / >" "newer / older"
          ~help:"step either list a page at a time; one page holds two \
                 hundred rows, so a shorter queue arrives whole"
      (* One item, spelled the way Approvals spells its own pair. Apart, the
         fitter gave up [x] and then [a], and what was left was a queue of
         work with no visible way to act on it -- which is the one thing this
         surface exists for. [Masc_tui_footer.never_dropped_keys] pins the
         pair whole; pinning [a] or [x] alone would pin the [a] that creates
         a keeper and the [x] that deletes one. *)
      ; b ~ko:"다음 / 이전 증거" Navigate "e / E" "next / previous evidence" ~detail:Detail_only
          ~help:"read one submitted evidence item at a time"
      ; b ~ko:"증거 목록 접기/펼치기" Act "i" "fold / unfold the evidence list" ~detail:Detail_only
      ; b ~ko:"증거 열기" Act "o" "open evidence" ~detail:Detail_only
          ~help:"download the retained copy and open it with a local application"
      ; b ~ko:"증거 사본 저장" Act "s" "save an evidence copy" ~detail:Detail_only
          ~help:"save this exact evidence item privately on this machine; its local path stays in the detail"
      ; b ~ko:"승인 / 반려" Act "a / x" "approve / reject" ~rows:Needs_row
          ~help:"a approves the row under the cursor (press twice); x rejects \
                 with a reason ($EDITOR form)"
      (* The row search reads the list's rows. An open detail has none, so the
         footer drawn for it leaves the pair out. *)
      ; b ~ko:"찾기" Search "/" "find" ~detail:List_only
          ~help:"jump the cursor to a matching task id, title, or submitter; \
                 the queue answers this, an open detail does not"
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match" ~detail:List_only
          ~rows:Needs_row
      ]
      @ row_list_jumps @ listing_meta
  | Harness ->
      [ b ~ko:"선택" Navigate "j/k" "move" ~rows:Needs_row
          ~help:"move; in a verdict, scroll"
      ; b ~ko:"다음 작업 탭" Navigate "v" "next Work tab" ~help:"back round to Goals"
      ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page" ~rows:Needs_row
      ; b ~ko:"판정" Act "Right / Enter" "verdict" ~detail:List_only ~rows:Needs_row
          ~help:"open the full evaluator verdict"
      ; b ~ko:"뒤로" Act "Esc" "back" ~detail:List_only ~help:"back to Work"
      ; b ~ko:"뒤로" Act "Left / Esc" "back" ~detail:Detail_only
          ~help:"back to the verdict list"
      ; b ~ko:"이전 / 다음" Navigate "[ / ]" "previous / next" ~detail:Detail_only
          ~help:"while a detail is open, step to the row before or after it"
        (* One item, spelled the way Verification spells its own pair. Apart,
           the fitter gives them up one at a time, and the screen that loses
           them first is the verdict pane -- the one place an operator reads a
           ruling in full before answering it. [Masc_tui_footer.never_dropped_keys]
           pins the pair whole; pinning [y] or [x] alone would pin the [y] of
           every [y / n] and the [x] that deletes a keeper.

           [x], not [n]: this surface answers the row search, and [n] / [N]
           step it. *)
      ; b ~ko:"동의 / 뒤집기" Act "y / x" "agree / overrule" ~rows:Needs_row
          ~help:"y records the machine's verdict as yours; x records the \
                 opposite, with $EDITOR taking the reason"
      ; b ~ko:"작업 복사" Act "Y" "copy task" ~rows:Needs_row
          ~help:"copy a link to the task in Work"
      ; b ~ko:"찾기" Search "/" "find" ~detail:List_only
          ~help:"jump the cursor to a matching task id or title"
      (* [/] opens its prompt on a read list with no row, so it stays; the
         jump has no match to step to and ends in [()] -- the same split
         Task Review draws. *)
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match" ~detail:List_only
          ~rows:Needs_row
      ]
      @ row_list_edges @ listing_meta
  | Fusion ->
      (* [fusion_mode] owns list/detail (masc_tui_types.ml); the detail
         footer is [footer_hints_fusion_detail], which also appends the live
         scroll position this static table cannot know. *)
      [ b ~ko:"선택" Navigate "j/k" "move" ~rows:Needs_row
      ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page" ~rows:Needs_row
      ; b ~ko:"열기" Act "Enter" "open" ~rows:Needs_row
          ~help:"open a retained run or its historical Board evidence"
      ; b ~ko:"이전 / 다음" Navigate "[ / ]" "previous / next" ~detail:Detail_only
          ~help:"while a detail is open, step to the row before or after it"
      ; fusion_caller_key
      ; fusion_board_key
        (* Spelled as Keepers spells its own [a]: new. The form is the
           schema form the Lane Add-ons action uses, so its keys are that
           form's; the footer names them while it is open. *)
      ; b ~ko:"새 실행" Act "a" "new run"
          ~help:"launch a Fusion run from the list: pick the Keeper, preset \
                 and topology, type the prompt, then Ctrl-S reviews and \
                 Enter starts it"
      ; b ~ko:"복사" Act "Y" "copy" ~rows:Needs_row
          ~help:"copy the selected Fusion run reference"
      ; b ~ko:"찾기" Search "/" "find" ~rows:Needs_row
          ~help:"jump the cursor to a matching run id, Keeper or preset; an \
                 open run's detail carries no searchable rows"
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match" ~rows:Needs_row
      ; b ~ko:"뒤로" Act "Esc" "back" ~help:"leave detail, or return to Dashboard"
      ]
      @ row_list_edges @ listing_meta
  | Memory ->
      memory_browser_pages @
      [ b ~ko:"선택" Navigate "j/k" "move" ~help:"move the keeper row"
      ; b ~ko:"기억 항목" Act "Enter" "facts"
          ~help:"browse what the selected keeper actually remembers"
      ; b ~ko:"상태 상세" Act "v" "health details"
          ~help:"read the complete fleet summary and selected keeper health in a scrollable capture"
      ; b ~ko:"전체 Keeper" Act "a / A" "all fleet"
          ~help:"browse and search consolidated memory across the entire fleet"
      ; b ~ko:"정렬" Act "s" "sort"
          ~help:"cycle sort keepers (facts, size, delta, state, name)"
      ; b ~ko:"단위" Act "u" "units"
          ~help:"switch stored memory and request input between tokens and KiB"
      ; b ~ko:"상세" Act "d" "detail"
          ~help:"show the selected keeper's ledger rows, or fold them back to \
                 its state, last save and actions"
      ; b ~ko:"지우기 / 뒤로" Act "Esc" "clear / back"
          ~help:"clear the filter, or return to Dashboard"
      ; b ~ko:"찾기" Search "/" "filter"
          ~help:"show only keepers whose id or state matches"
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match"
      ]
      @ row_list_jumps @ listing_meta
  | Repositories ->
      (* With no repository registered, the keys that read the one under the
         cursor do nothing or answer with a notice. [a] and [/] still act:
         the first opens the editor to register one, the second opens the
         search line. [v] needs a reading, not a row: after a failed read it
         opens the failure with no repository selected. *)
      [ b ~ko:"전체 정보" Navigate "v" "full details" ~rows:Needs_reading
          ~help:"read the complete selected path, Keeper assignments and errors"
      ; b ~ko:"이동" Navigate "j/k" "scroll" ~rows:Needs_row
      ; b ~ko:"파일" Act "Enter" "browse" ~rows:Needs_row
          ~help:"open the repository tree, or the selected changed file"
      ; b ~ko:"쓰기 이력" Navigate "H" "recent activity" ~rows:Needs_row
          ~help:"recorded clone writes by Keeper and Task in the last day"
      ; b ~ko:"Git 변경" Act "d" "Git changes" ~rows:Needs_row
          ~help:"show the selected repository's current working-tree changes"
      ; b ~ko:"등록" Act "a" "add" ~help:"register a repository; opens $EDITOR"
      ; b ~ko:"뒤로" Act "Esc" "back"
          ~help:"return to Dashboard; inside Git changes, close the diff, \
                 then Git changes (Left does the same there)"
      ; b ~ko:"찾기" Search "/" "find"
          ~help:"jump the cursor to a matching repository, or to a changed \
                 path while Git changes is open"
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match" ~rows:Needs_row
      ]
      @ row_list_jumps @ listing_meta
  | Changes ->
      (* "move", not "scroll": the keys move the marked row and the window
         follows it, which is also what the surface's own footer says.

         A keeper that wrote nothing in the window has no row. The keys that
         read the row under the cursor answer with a notice or do nothing;
         [ / ] still switches to the next keeper, so it stays. *)
      [ b ~ko:"선택" Navigate "j/k" "move" ~rows:Needs_row
      ; b ~ko:"키퍼" Navigate "[ / ]" "keeper" ~help:"previous / next keeper"
      ; b ~ko:"쓴 변경" Act "Right / Enter" "written diff" ~rows:Needs_row
          ~help:"what the call wrote, as a diff"
        (* Left closes an open diff and does nothing on the list; Esc closes
           the diff too and, on the list, goes back to the Keeper screen the
           list was opened from. The diff footers are their own strings, so
           this table's footer is the list's. *)
      ; b ~ko:"뒤로" Act "Esc" "back" ~detail:List_only
          ~help:"back to the Keeper screen this list was opened from"
      ; b ~ko:"뒤로" Act "Left / Esc" "back" ~detail:Detail_only ~help:"close the diff"
      ; b ~ko:"트리 diff" Act "d" "tree diff" ~rows:Needs_row ~help:"what the tree holds now"
      ; b ~ko:"코드 보기" Act "v" "view code" ~rows:Needs_row
          ~help:"the file on the Code surface, read from the keeper's own \
                 workspace"
      ; b ~ko:"찾기" Search "/" "find" ~rows:Needs_row
          ~help:"jump the cursor to a matching written path"
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match" ~rows:Needs_row
      ; b ~ko:"편집기" Act "o" "editor" ~rows:Needs_row ~help:"open in $EDITOR / $NVIM"
      ]
      @ row_list_jumps @ listing_meta
  | Connectors ->
      [ b ~ko:"브라우저" Navigate "B" "Browser Lane"
          ~help:"read browser tabs and page text; choose Automatic or a connected browser"
      ; b ~ko:"브라우저 화면" Act "Ctrl-O" "Browser screenshot"
          ~help:"inside Browser Lane: preview the selected tab; any key returns"
      ; b ~ko:"스크롤" Navigate "j/k" "scroll"
      ; b ~ko:"연결 / 해제" Act "b / u" "bind / unbind" ~help:"bind / unbind a channel"
      ; b ~ko:"기능" Act "Esc" "features" ~help:"back to Features & plugins"
      ; b ~ko:"찾기" Search "/" "find" ~help:"jump the cursor to a matching transport"
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match"
      ]
      @ row_list_jumps @ listing_meta
  | Runtime ->
      List.map runtime_sheet_binding runtime_keys @ row_list_edges @ listing_meta
  | Config ->
      List.map fst config_bindings
  | Resources ->
      (* Two panes with two meanings, and the keys below say so once rather
         than per row: with the list focused the cursor moves and [/] lands
         it on a match; with the text focused the same keys move the reading.
         Both ends answer to Home and End. *)
      [ b ~ko:"형식" Act "f" "format" ~help:"cycle all resources, artifacts, Markdown and HTML"
      ; b ~ko:"체크 / 해제" Act "c" "check / uncheck"
          ~help:"explicitly toggle shared confirmation for the selected exact report revision"
      ; b ~ko:"다음 미체크" Navigate "u" "next unchecked"
          ~help:"select the next unchecked report in this format/day scope; open it when the reader is focused"
      ; b ~ko:"오늘" Act "t" "today" ~help:"toggle the local publication day captured at this keypress"
      ; b ~ko:"배치" Act "w" "layout" ~help:"switch full-width list/reader and side-by-side browsing"
      ; b ~ko:"문서 / 원문" Act "v" "document / source" ~detail:Detail_only
          ~help:"show the document or its original text syntax; copied bytes stay original"
      ; b ~ko:"리소스 정보" Act "i" "resource info" ~detail:Detail_only
          ~help:"expand the source, URI, type, size and complete metadata for an MCP resource or report; the body is shown first by default"
      ; b ~ko:"선택" Navigate "j/k" "move"
          ~help:"move the list; with the text focused, scroll it"
      ; b ~ko:"창" Navigate "h/l" "pane" ~help:"focus the resource list or text"
      ; b ~ko:"초점" Navigate "Ctrl-W" "focus"
          ~help:"cycle the resource list, the text, and the Activity pane when it is drawn"
      ; b ~ko:"본문 스크롤" Navigate "J/K" "scroll text"
      ; b ~ko:"이전 / 다음" Navigate "[ / ]" "previous / next" ~detail:Detail_only
          ~help:"while the detail is focused, read the adjacent resource"
      ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
          ~help:"a page of the list, or of the text when it is focused"
      ; b ~ko:"처음/끝" Navigate "Home/End" "top/bottom"
          ~help:"the first or last resource, or the ends of the text when it \
                 is focused"
      ; b ~ko:"읽기" Act "Enter" "read" ~help:"read the selected resource"
      ; b ~ko:"이전 / 다음 판" Navigate "{ / }" "older / newer revision" ~detail:Detail_only
          ~help:"read the adjacent published report revision from its validated history"
      ; b ~ko:"그림" Navigate ", / ." "image" ~detail:Detail_only
          ~help:"select the previous or next image or Mermaid diagram in the loaded resource"
      ; b ~ko:"그림 미리보기" Act "Ctrl-O" "preview image" ~detail:Detail_only
          ~help:"open the selected image or Pele diagram from the retained resource bytes"
      ; b ~ko:"본문 조각" Navigate "( / )" "text part" ~detail:Detail_only
          ~help:"select the previous or next original text part for copying"
      ; b ~ko:"원본 저장" Act "s" "save original" ~detail:Detail_only
          ~help:"choose a local destination; Enter exclusively creates the selected report revision's exact bytes, Esc closes path input; the retained result stays with that original report"
      ; b ~ko:"Dashboard 열기" Act "o" "open Dashboard" ~detail:Detail_only
          ~help:"open the selected fixed report revision; the browser uses its own authentication"
      ; b ~ko:"외부 공유" Act "P" "external sharing" ~detail:Detail_only
          ~help:"enable or revoke external access to all revisions of this report"
      ; b ~ko:"공유 맞추기" Act "U" "reconcile share" ~detail:Detail_only
          ~help:"inspect the original recorded share operation"
      ; b ~ko:"공유 복구 확인" Act "!" "confirm share recovery" ~detail:Detail_only
          ~help:"confirm the displayed original operation after its preview is shown"
      ; b ~ko:"공개 링크 복사" Act "Y" "copy public link" ~detail:Detail_only
          ~help:"copy the selected revision's link when external sharing is enabled"
      ; b ~ko:"판 다시 읽기" Act "R" "reread revision" ~detail:Detail_only
          ~help:"reread the exact open resource, including an older report revision"
      ; b ~ko:"원문 복사" Act "y" "copy source" ~detail:Detail_only
          ~help:"send the selected text part's original bytes via OSC 52; terminal support is unconfirmed"
      ; b ~ko:"뒤로" Act "Esc" "back"
          ~help:"the text hands back to the list; the list returns to Features & plugins"
      ; b ~ko:"찾기" Search "/" "find"
          ~help:"find a resource name in the list, or text in the loaded detail"
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match"
      ; b ~ko:"다시 읽기" Meta "r" "reload"
      ; b ~ko:"다음 화면" Meta "Tab" "next"
      ; b ~ko:"종료" Meta "q" "quit"
      ]
  | Code ->
      (* A row surface: masc_tui_types gives it a searchable row list
         (code_entries), so the cursor and "/" are real here, and Enter drills
         one directory level (the /workspace/children route is lazy). Claimed
         from those two facts rather than from the render, so the footer does
         not advertise a key nothing handles. *)
      [ b ~ko:"선택" Navigate "j/k" "move"
      ; b ~ko:"창" Navigate "h/l" "pane" ~help:"focus the tree or open file"
      ; b ~ko:"파일 찾기" Search "Ctrl-P" "file finder"
          ~help:"filter all tracked and nonignored files in the owning Git checkout; Enter opens, Esc returns"
      ; b ~ko:"브랜치" Search "Ctrl-R" "branches"
          ~help:"list the local branches of the owning Git checkout, newest tip first, with how each stands against its upstream; type to filter, Enter or Esc returns"
      ; b ~ko:"worktree" Search "W" "worktrees"
          ~help:"list the worktrees of the owning Git repository: each one's directory name, what it has checked out, and whether it is locked or prunable; type to filter, Enter or Esc returns"
      ; b ~ko:"파일 안 검색" Search "Ctrl-G" "search in files"
          ~help:"type text and press Enter to find it in every tracked and nonignored file of the owning Git checkout; pick a match and Enter opens it at that line, Esc returns"
      ; b ~ko:"열기" Act "Right / Enter" "open" ~help:"drill in, or open the file"
        (* Esc walks back out the way Enter came in: it closes an open file
           first, and only climbs a directory once no file is open. From the
           project root, Esc alone leaves for Workspace, the ring parent --
           Left stays on the surface, the same convention as every other
           off-ring child. A key that works and is not listed is the same
           drift as a listed key that does nothing, pointing the other way. *)
      ; b ~ko:"뒤로" Act "Left / Esc" "back"
          ~help:"close the history, then the file, then climb one \
                 directory; Esc at the project root leaves for Workspace"
      ; b ~ko:"좌우 이동" Navigate "Shift-Left / Shift-Right" "pan"
          ~help:"with a file open, scroll it sideways one cell at a time"
      ; b ~ko:"찾기" Search "/" "find"
          ~help:"jump the cursor to a match: the tree, or the open file's \
                 lines"
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match"
        (* The view actions come first among the file keys. Each answers on
           any open file and needs nothing configured. A row gives up keys from
           its back, and the language-server keys, which need a server, and the
           draft keys, which write, stood ahead of them: on the fixture server
           the file footer at 300 cells named K R D B e S V X and none of
           d H m b y. *)
      ; b ~ko:"diff" Act "d" "diff"
          ~help:"on the project tree, list every working-tree change; on an \
                 open file, show that file's diff against HEAD; in the file's \
                 history, on a commit row, show what that commit changed"
      ; b ~ko:"이력" Act "H" "history"
          ~help:"the commits that touched the open file, newest first \
                 (H or Esc closes)"
      ; b ~ko:"blame" Act "b" "blame"
          ~help:"who last touched each run of lines, in the margin; b again \
                 drops it"
      ; b ~ko:"메모" Act "m" "notes"
          ~help:"the memos in the open file: comments on their own row \
                 reading masc(name): text, or masc(name) question: text; m \
                 again closes the list"
      ; b ~ko:"원문 복사" Act "y" "copy source"
          ~help:"send the whole readable file's original bytes to the terminal clipboard via OSC 52; terminal support is unconfirmed"
      ; b ~ko:"이름 설명" Act "K" "hover"
          ~help:"ask the language server what a name on the cursor line is \
                 (one name asks at once; several open the palette as \
                 choices); read the complete answer with j/k or paging, Esc returns to code"
      ; b ~ko:"쓰는 곳" Act "R" "references"
          ~help:"ask the language server where a name on the cursor line is \
                 used; needs the project's reference index, and says which \
                 command builds it when there is none"
      ; b ~ko:"정의" Act "D" "definition"
          ~help:"jump to where a name on the cursor line is defined (one \
                 name jumps at once; several open the palette as choices)"
      ; b ~ko:"정의 뒤로" Act "B" "back"
          ~help:"walk back through the definition jumps, newest first"
      ; b ~ko:"초안 편집" Act "e" "edit draft" ~help:"edit exact server source in $EDITOR; retain draft in this session"
      ; b ~ko:"초안 저장" Act "S" "save draft" ~help:"explicitly save using the original revision; a conflict retains the draft"
      ; b ~ko:"초안 비교" Act "V" "draft comparison" ~help:"compare original/current server source with the retained draft"
      ; b ~ko:"초안 버리기" Act "X" "discard draft" ~help:"discard only the local draft, after any submitted save settles"
      ; b ~ko:"서버 판 받기" Act "A (draft)" "adopt revision" ~help:"after rereading and comparing a conflict, explicitly adopt the server revision"
      ; b ~ko:"열기" Act "Enter (history)" "open"
          ~help:"a commit answers with its pull request, from its (#N) and \
                 the repository's remote"
      ]
      @ row_list_jumps @ listing_meta
  | Tools ->
      [ b ~ko:"스크롤" Navigate "j/k" "scroll"
      ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
      ; b ~ko:"처음/끝" Navigate "Home/End" "top/bottom"
      ; b ~ko:"다음 탭" Navigate "p" "section"
          ~help:"available / async runs / receipts / usage / all tools. \
                 Available shows the selected Keeper's exposed tools and Skills; \
                 ORIGIN names the tool source. Async runs shows workspace requests \
                 and recovery: active counts active ledger requests, runtime-owned \
                 means a current runtime owner, ownership-unknown is unconfirmed. \
                 Receipts keeps current-session Skill evidence: triggered=invoked, \
                 delivered/handed off=delivered, actions=later tool actions. \
                 These are separate events; no record does not prove no use. \
                 Usage aggregates recorded calls by exact Skill revision across \
                 current Keeper sessions; last use is the ledger's recorded time, \
                 and unread ledgers stay qualified. \
                 All tools lists process-wide registrations, separately from \
                 a Keeper's callable surface and observed calls. \
                 DIRECT=direct calls allowed; SURFACES=exposure paths; \
                 none=no exposure path. Use Skill receipts for usage evidence \
                 and Activity for tool input/output."
      ; b ~ko:"스킬" Navigate "J/K" "Skill"
          ~help:"in async runs, select an original request; otherwise select \
                 a published Skill"
      ; b ~ko:"조합 성능" Act "f" "Composition performance"
          ~help:"outside async requests, select the next Composition and load its exact-revision performance charts"
      ; b ~ko:"스킬 그래프" Act "Ctrl-O" "Skill graph"
          ~help:"outside async requests, preview the selected Composition Skill's \
                 declared graph with Pele; Normal Skills have none, and f selects \
                 a Composition"
      (* Enter's Skill-evidence role (outside async runs, masc_tui.ml: the
         "\r" arm) is named on the sheet's Enter row only. The footer table
         cannot carry Enter -- the fitter never drops it -- so advertising it
         here squeezed the action diagnosis out of the 98-cell row and broke
         the sheet-only contract (test_tui_keys, tools_detail_bindings). *)
      ; tools_bracket_binding ~pane:Tools_surface
      ; b ~ko:"새 스킬" Act "c / C" "new Skill"
          ~help:"open $EDITOR on a template for a new Skill; c starts an \
                 instruction Skill, C starts a composition Skill"
      ; b ~ko:"스킬 편집" Act "e" "edit Skill"
          ~help:"open the selected SKILL.md in $EDITOR, validate, CAS-save, and publish"
      ; b ~ko:"스킬 삭제" Act "d" "delete Skill"
          ~help:"remove the selected published package; press d again on the \
                 same row to confirm"
      ; b ~ko:"기능" Act "Esc" "features"
          ~help:"return from original Task to request, then request to list; \
                 otherwise back to Features & plugins"
      ]
      @ [ tools_refresh; listing_next; listing_quit ]
  | System_logs ->
      (* [e] leads, as [e / l] leads on Events. The title row draws the
         Events / Logs strip only where its readings leave room, and at 80
         columns it does not on either reading, so this row is the one place
         that names the other. With [o] first, 80 and 84 columns under an
         ACTION NEEDED notice kept [o:log origin] and dropped [e:Events]. *)
      [ b ~ko:"이벤트" Navigate "e" "Events"
      ; b ~ko:"로그 출처" Navigate "o" "log origin" ~help:"switch between server logs and this TUI's own observations"
      ; b ~ko:"이동 / 스크롤" Navigate "j/k" "move / scroll" ~rows:Needs_row
      ; row_list_page
      ; b ~ko:"이전 / 다음" Navigate "[ / ]" "previous / next" ~detail:Detail_only
          ~help:"while detail is open, inspect the adjacent visible log entry"
      (* The three filter keys put the cursor back on the first row. An open
         entry keeps its place, so [ and ] would then step from the wrong row
         and closing the entry would land on a list nobody saw change. They
         answer on the list only. *)
      ; b ~ko:"최소 수준" Act "l" "level floor" ~detail:List_only
          ~help:"raise the minimum level; after error, back to everything"
      ; b ~ko:"자세히" Act "v" "verbose" ~detail:List_only
          ~help:"toggle DEBUG rows directly; off uses the INFO floor"
      ; b ~ko:"분류" Act "c" "category" ~detail:List_only
          ~help:"cycle through the categories this page carries"
      (* Opens the entry under the cursor. Inside the detail the dispatcher
         has nothing left to open, and a list the filters emptied has no
         entry. *)
      ; b ~ko:"상세" Act "Right / Enter" "detail" ~detail:List_only ~rows:Needs_row
          ~help:"show the full message, source, category, turn, and JSON details"
      ; b ~ko:"뒤로" Act "Esc" "back" ~detail:List_only ~help:"back to Activity"
      ; b ~ko:"뒤로" Act "Left / Esc" "back" ~detail:Detail_only ~help:"close the detail"
      ; b ~ko:"찾기" Search "/" "find" ~detail:List_only
          ~help:"jump the cursor to a matching module, keeper, or message, \
                 over the rows the level and category filters leave"
      ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match" ~detail:List_only ~rows:Needs_row
      ]
      @ row_list_edges @ listing_meta

let group_rank = function Navigate -> 0 | Act -> 1 | Search -> 2 | Meta -> 3

let hints_in_order ~lang bindings =
  bindings
  |> List.map (fun (binding : binding) ->
      let label = match lang with
        | Lang_ko -> binding.label_ko
        | Lang_en -> binding.label
      in
      key_hint ~label binding)
  |> String.concat "  "

(* Sort by group, then flatten to the footer's "key:label  key:label" form.
   Both the static per-surface footer and the Fusion detail footer (which
   appends a live scroll position) render through this one projection. *)
let hints_of_bindings ~lang bindings =
  bindings
  |> List.stable_sort (fun a b -> compare (group_rank a.group) (group_rank b.group))
  |> hints_in_order ~lang

(* [detail_open] is how a surface that owns a detail says which of its two
   states is on screen. A surface without a detail leaves it out, and then
   every binding stands -- which is what every caller did before this argument
   existed, so their footers are unchanged. A surface that does own one and
   forgets to pass it falls back to that same behaviour, which is the bug this
   argument exists to end; [test_tui_footer_detail_state] is what keeps a new
   surface from quietly landing there. *)
(* Whether a binding answers in the state a footer is drawing. Its own
   function because two footers filter their surface's table by hand --
   Resources for the focused pane, Code for the open one -- and a second
   reading of this rule beside them is how a key comes back to a footer that
   refuses it.

   [has_rows] is how a list renderer says whether the list on screen holds a
   row. [Some false] leaves out the keys that need one; a renderer that does
   not pass it keeps every binding, as before. [has_reading] is the same
   answer for the keys that open a reading, which a failed read can leave
   with nothing selected. *)
let answers_in_state ?detail_open ?has_rows ?has_reading binding =
  (match detail_open, binding.detail with
   | _, Either -> true
   | None, (List_only | Detail_only) -> true
   | Some open_, List_only -> not open_
   | Some open_, Detail_only -> open_)
  && (match binding.rows with
      | Rowless -> true
      | Needs_row -> (match has_rows with Some false -> false | Some true | None -> true)
      | Needs_reading ->
          (match has_reading with Some false -> false | Some true | None -> true))

let footer_hints ~lang ?detail_open ?has_rows ?has_reading surface =
  hints_of_bindings ~lang
    (List.filter (answers_in_state ?detail_open ?has_rows ?has_reading)
       (for_surface surface))

(* [r] is Resume for a paused Goal, so the generic refresh label must not
   advertise it as a read in this detail. The Candle read has its own key. *)
let planning_goal_hints ~lang ~detail_open ~has_rows =
  let bindings = for_surface Planning
    |> List.filter (answers_in_state ~detail_open ?has_rows)
    |> List.filter (fun binding -> not detail_open || not (String.equal binding.key "r"))
    |> List.map (fun binding ->
      if detail_open && String.equal binding.key "j/k" then
        {binding with label = "scroll"; label_ko = "스크롤"}
      else binding) in
  let read, others = List.partition (fun binding -> String.equal binding.key goal_candle_refresh_key) bindings in
  hints_in_order ~lang (read @ List.stable_sort (fun a b -> compare (group_rank a.group) (group_rank b.group)) others)

let footer_hints_planning_goal_list ~lang ~has_rows =
  planning_goal_hints ~lang ~detail_open:false ~has_rows:(Some has_rows)

let footer_hints_planning_goal_detail ~lang =
  planning_goal_hints ~lang ~detail_open:true ~has_rows:None

(* The Available section folds its diagnostics -- the runtime, the digests
   and the byte budgets -- under one heading, and draws each digest by its
   first twelve characters. Both keys answer there only, so only that
   section's footer names them. *)
let tools_diagnostics_bindings =
  [ b ~ko:"진단 펴기/접기" Act expand_turn_label "diagnostics"
      ~help:"in Available, unfold or fold the runtime, digest and byte-budget rows"
  ; b ~ko:"진단 복사" Act "Y" "copy diagnostics"
      ~help:"in Available, copy the diagnostics with whole digests and the \
             selected Skill's whole revision"
  ]

let footer_hints_tools ~lang ~pane =
  let bracket = tools_bracket_binding ~pane in
  let bindings =
    List.map (fun (binding : binding) ->
       if String.equal binding.key bracket.key then bracket else binding)
       (for_surface Tools) in
  (* What a reading with no selection takes: it scrolls and moves on. *)
  let reading =
    [ b ~ko:"스크롤" Navigate "j/k" "scroll"
    ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
    ; b ~ko:"처음/끝" Navigate "Home/End" "top/bottom"
    ; b ~ko:"다음 탭" Navigate "p" "section" ]
  in
  match pane with
  | Tools_catalog (Tools_catalog_volumes _) ->
      hints_in_order ~lang
        ((tools_volume_gc_binding :: reading)
         @ [ b ~ko:"목록" Act "Esc" "catalog"
           ; tools_refresh; listing_next; listing_quit ])
  | Tools_catalog Tools_catalog_list ->
      hints_in_order ~lang
        (tools_volume_gc_binding :: List.stable_sort
          (fun a b -> compare (group_rank a.group) (group_rank b.group)) bindings)
  | Tools_storage ->
      hints_in_order ~lang (reading @ [ tools_refresh; listing_next; listing_quit ])
  | Tools_surface ->
      hints_of_bindings ~lang (bindings @ tools_diagnostics_bindings)
  | Tools_async | Tools_activations | Tools_usage ->
      hints_of_bindings ~lang bindings

type ask_supply =
  | No_asks
  | Asks_unselected
  | Ask_selected

type approvals_footer =
  | Approval_browsing of {
      approvals : bool; asks : ask_supply; source : bool; last_answer : bool;
    }
  | Approval_writing
  | Approval_armed
  | Approval_answering of { has_choices : bool; takes_text : bool }

(* The approval queue and its question reader use the same binding records as
   Help. Their modes need a deliberate order and, for Enter, a mode-specific
   verb; the dispatcher gives that key a different action in each mode. *)
let footer_hints_approvals ~lang mode =
  let say korean english =
    match lang with Lang_ko -> korean | Lang_en -> english
  in
  (* A mode's own word for a key replaces the binding's, in both languages. *)
  let hint ?label (binding : binding) =
    match label, lang with
    | Some word, (Lang_ko | Lang_en) -> key_hint ~label:word binding
    | None, Lang_ko -> key_hint ~label:binding.label_ko binding
    | None, Lang_en -> key_hint binding
  in
  let row items = String.concat "  " items in
  match mode with
  | Approval_browsing { approvals; asks; source; last_answer } ->
      (* Each key follows its own source. [j/k] and [y / n] act on an approval
         row; with none the decision answers with a notice. [ / ] selects a
         waiting question and [a] opens the selected one, so a cursor on none
         of them keeps [ / ] and drops [a]. [o / O] read the source of a
         question, the last answer's included. [w] and [e] open a palette and
         act on an empty queue. *)
      row
        ((if approvals then [ hint approval_move; hint approval_decide ] else [])
         @ [ hint approval_workspace; hint approval_outside ]
         @ (match asks with
            | No_asks -> []
            | Asks_unselected -> [ hint approval_walk ]
            | Ask_selected -> [ hint approval_walk; hint approval_answer ])
         @ (if source then [ hint approval_origin ] else [])
         @ (if last_answer then [ hint approval_answer_receipt ] else [])
         @ [ hint listing_refresh; hint listing_next
             (* The way out: the two keys a cut row keeps
                ([Masc_tui_footer.never_dropped_keys]). *)
           ; hint approval_back; hint listing_quit
           ])
  | Approval_writing ->
      row
        [ hint ~label:(say "저장" "save") approval_read
        ; hint ~label:(say "취소" "cancel") approval_back
        ]
  | Approval_armed ->
      say "Enter 를 한 번 더 누르면 전송  |  " "Press Enter again to send  |  "
      ^ row [ hint approval_skip; hint approval_clear; hint approval_back ]
  | Approval_answering { has_choices; takes_text } ->
      row
        ([ hint approval_question; hint row_list_page; hint approval_walk; hint approval_origin ]
        @ (if has_choices then [ hint approval_pick ] else [])
        @ (if takes_text then [ hint approval_write ] else [])
        @ [ hint approval_skip; hint approval_clear
          ; hint ~label:(say "답하기" "answer") approval_read; hint approval_back
          ])

(* Whether this surface's table scopes any binding to one of the two states.
   A surface this answers [true] for owes [footer_hints] a [~detail_open] from
   both of its renderers; [test_tui_footer_detail_state] reads this rather
   than a list written by hand beside it. *)
let has_detail_scoped_keys surface =
  List.exists
    (fun binding ->
      match binding.detail with
      | Either -> false
      | List_only | Detail_only -> true)
    (for_surface surface)

(* The same question for rows: whether this surface's table holds a key that
   needs one, and so owes [footer_hints] a [~has_rows] from its list renderer.
   [test_tui_footer_row_need] reads this rather than a list written by hand
   beside it. *)
let has_row_scoped_keys surface =
  List.exists
    (fun binding ->
      match binding.rows with
      | Rowless -> false
      | Needs_row | Needs_reading -> true)
    (for_surface surface)

let footer_hints_metrics ~lang ~section ~telemetry =
  metrics_bindings
  |> List.filter_map (fun (binding, scope) ->
         let shown = match scope, telemetry with
           | Metrics_all, _
           | Metrics_usage, false | Metrics_telemetry, true -> true
           | Metrics_usage, true | Metrics_telemetry, false
           | Metrics_usage_sections _, true -> false
           | Metrics_usage_sections sections, false -> List.mem section sections
         in
         if shown then Some binding else None)
  |> hints_of_bindings ~lang

(* The keys an open approval answers to. Its footer was written out in the
   renderer, which is how it came to spell the decision keys apart from the
   queue behind it and to call [R] something the key table does not. *)
type approval_value_hint = No_value_reading | Readable_values | Byte_values

let footer_hints_approval_detail ~lang ~value_hint =
  hints_of_bindings ~lang
    ([ b ~ko:"스크롤" Navigate "j/k" "scroll" ]
    @ (match value_hint with
       | No_value_reading -> []
       | Readable_values -> [ approval_value_bytes ]
       | Byte_values -> [ b ~ko:"글자" Navigate "v" "text" ])
    @ [ approval_decide
    ; approval_retry
    ; b ~ko:"뒤로" Act "Esc" "back"
    ])

(* The Board draft's two footers were written out in the renderer, and the
   pane above them then spelled the same key a second way: "Ctrl-E: $EDITOR"
   over a footer saying "Ctrl-E:$EDITOR", with "Enter: newline" beside it
   that the footer never named. Both rows project from here, and the pane
   keeps to what the draft is and where it goes. *)
let board_compose_writing_bindings ~reply =
  [ b ~ko:"줄바꿈" Act "Enter" "newline" ~help:"newline in the draft; Esc opens the send menu"
  ; b ~ko:"$EDITOR" Act "Ctrl-E" "$EDITOR" ~help:"hand the draft to $EDITOR and take it back"
  ]
  (* A comment's wire carries text only, so the hint appears where the key
     works -- a reply's Ctrl-A says why instead of staging. *)
  @ (if reply then []
     else [ b ~ko:"첨부" Act "Ctrl-A" "attach" ~help:"stage a local file to upload with the post" ])
  @ [ b ~ko:"메뉴" Meta "Esc" "menu" ~help:"send, discard, or keep writing"
    ; b ~ko:"화면" Meta "Tab" "surfaces"
    ]

(* No [q] here: while the draft has the keys, [q] is a printable scalar and
   goes into the draft like any other letter. Leaving is Esc and then d. *)
let footer_hints_board_compose_writing ~lang ~reply =
  (match lang with Lang_ko -> "내용 입력  " | Lang_en -> "type to write  ")
  ^ hints_of_bindings ~lang (board_compose_writing_bindings ~reply)

(* The path input after Ctrl-A owns the compose keys until the file is staged
   or the input is cancelled. *)
let board_attach_input_bindings =
  [ b ~ko:"첨부 준비" Act "Enter" "stage"
  ; b ~ko:"취소" Meta "Esc" "cancel"
  ]

let footer_hints_board_attach_input ~lang =
  (match lang with Lang_ko -> "파일 경로 입력  " | Lang_en -> "type the file path  ")
  ^ hints_of_bindings ~lang board_attach_input_bindings

type board_compose_menu_hints = {
  choices : string;
  hints : string;
}

let board_compose_menu_hints ~lang ~reply =
  { choices =
      hints_of_bindings ~lang
        [ b ~ko:"전송" Act "s" "send"
        ; b ~ko:"버리기" Act "d" "discard"
        ; b ~ko:"계속" Meta "Esc" "continue"
        ]
  ; hints =
      hints_of_bindings ~lang
        ([ b ~ko:"$EDITOR에서 편집" Act "e" "edit in $EDITOR" ]
         @ (if reply then []
            else [ b ~ko:"게시판 전환" Act "h" "cycle hearth"
                     ~help:"a new post's sub-board" ]))
  }

(* No [q] here either: while a drop reason has the keys, every printable
   scalar is a letter of it. *)
let goal_drop_reason_bindings =
  [ b ~ko:"중단" Act "Enter" "drop" ~help:"request a drop with this reason; Tasks observed unclaimed may be cancelled"
  ; b ~ko:"취소" Meta "Esc" "cancel" ~help:"close the reason; the goal stays as it is"
  ]

let footer_hints_goal_drop_reason ~lang =
  (match lang with Lang_ko -> "중단 이유 입력  " | Lang_en -> "type why  ")
  ^ hints_of_bindings ~lang goal_drop_reason_bindings

(* A pane's own keys, then the keys all seven panes share. *)
let config_pane_bindings pane =
  let own =
    List.filter_map
      (fun (binding, panes) ->
        match panes with
        | Some panes when List.mem pane panes -> Some binding
        | Some _ | None -> None)
      config_bindings
  in
  let shared =
    List.filter_map
      (fun (binding, panes) ->
        match panes with None -> Some binding | Some _ -> None)
      config_bindings
  in
  (own, shared)

(* The pane's own keys lead the row and the shared ones follow. A cut row
   gives up its back first, and the shared keys are the ones a reader already
   met on the pane before -- the reason r, Tab and q close every row. Sorted
   as one list, the hops to Runtime, Resources and Tools outlived every key a
   pane answers itself: at 120 columns presets lost n and u, and the runtime
   assets lost o, their only way back to the registry. *)
let config_row ~lang ~own ~shared =
  String.concat "  "
    (List.filter
       (fun row -> not (String.equal row ""))
       [ hints_of_bindings ~lang own; hints_of_bindings ~lang shared ])

let footer_hints_config ~lang ~pane =
  let own, shared = config_pane_bindings pane in
  (* Save notices name x, c and v when applicable; retain them in help without
     spending footer slots when there is nothing to hide or copy. *)
  let own = match pane with
    | Config_presets -> List.filter (fun binding ->
        binding.key <> "x" && binding.key <> "c" && binding.key <> "v") own
    | Config_runtime | Config_models | Config_params | Config_prompts
    | Config_themes | Config_voice -> own
  in
  match pane with
  | Config_params | Config_presets ->
    (* At 80 cells the page/selection hints otherwise outlive E, the only
       door to advanced JSON. The pane body already names those navigation
       keys; keep its distinct edit actions ahead of them in the footer.
       Presets the same at 120: n, u and D are the pane's three writes, and
       behind the navigation keys D was the one cut. *)
    let actions, navigation =
      List.partition (fun binding -> binding.group = Act) own in
    String.concat "  "
      [ hints_of_bindings ~lang actions; hints_of_bindings ~lang navigation
      ; hints_of_bindings ~lang shared ]
  | Config_runtime | Config_models | Config_prompts | Config_themes | Config_voice ->
    config_row ~lang ~own ~shared

(* The keeper-voice screen: two lists and one write. The keys are its own --
   the keeper walks under [j]/[k] and the voice under the arrows, so an
   assignment cannot be made by moving one axis and hoping the other
   followed -- and the row is built here rather than written as a string, so
   the spellings are the table's. *)
let voice_agent_bindings =
  [ b ~ko:"키퍼" Navigate "j/k" "keeper"
  ; b ~ko:"목소리" Navigate "\xe2\x86\x90/\xe2\x86\x92" "voice"
  ; b ~ko:"상세 페이지" Navigate "PgUp/PgDn" "metadata page"
  ; b ~ko:"상세 처음/끝" Navigate "Home/End" "metadata edges"
  ; b ~ko:"도움말" Meta "?" "help"
  ; b ~ko:"배정" Act "Enter" "assign" ~help:"write this keeper's voice into voice.tts.agent_voices"
  ; b ~ko:"뒤로" Act "Esc" "back" ~help:"leave the screen; nothing is written"
  ]

let patch_review_bindings =
  [ b ~ko:"좌우 이동" Navigate "Shift+←/→" "pan"
      ~help:"Shift-Left / Shift-Right moves diff text horizontally while file coordinates remain fixed"
  ; b ~ko:"스크롤" Navigate "j/k" "scroll"
  ; b ~ko:"페이지" Navigate "PgUp/PgDn / d/u" "page"
  ; b ~ko:"처음/끝" Navigate "Home/End / g/G" "edges"
  ; b ~ko:"편집" Act "e" "edit" ~help:"leave review and open the project file in your editor"
  ; b ~ko:"도움말" Meta "?" "help"
  ; b ~ko:"닫기" Meta "Esc" "close" ~help:"Esc, q or Q closes the patch reader"
  ]

let runtime_detail_bindings_for ~routes =
  (if routes then [] else [ b ~ko:"모델 설정" Act "e" "model settings" ])
  @ [ b ~ko:"스크롤" Navigate "j/k" "scroll"
    ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
    ; b ~ko:"처음/끝" Navigate "Home/End" "edges"
    ; b ~ko:"목록" Act "Left / Esc" "list"
    ; b ~ko:"새로 조회" Meta "r" "refresh"
    ; b ~ko:"다음 화면" Meta "Tab" "next"
    ; b ~ko:"도움말" Meta "?" "help"
    ]

let footer_hints_patch_review ~lang = hints_of_bindings ~lang patch_review_bindings

let footer_hints_runtime_detail ~lang ~routes =
  hints_of_bindings ~lang (runtime_detail_bindings_for ~routes)

let voice_agent_bindings_for_saving saving =
  if saving then [ b ~ko:"도움말" Meta "?" "help"; b ~ko:"뒤로" Act "Esc" "back" ]
  else voice_agent_bindings

let footer_hints_voice_agent ~lang ?(saving = false) () =
  hints_of_bindings ~lang (voice_agent_bindings_for_saving saving)

(* The account form on runtime.toml takes every key while it is open, so the
   pane's row -- [e], [r], [Tab], [q] -- would name keys that now type into a
   field. The form's row names only what the form reads. *)
let runtime_account_form_bindings =
  [ b ~ko:"제공자" Navigate "\xe2\x86\x90/\xe2\x86\x92" "provider"
      ~help:"on the provider field, the next or previous provider to copy"
  ; b ~ko:"항목" Navigate "\xe2\x86\x91/\xe2\x86\x93" "field"
  ; b ~ko:"다음 / 저장" Act "Enter" "next / save"
      ~help:"move to the next field; on the last one, declare the account and save"
  ; b ~ko:"취소" Act "Esc" "cancel" ~help:"close the form; nothing is written"
  ]

let footer_hints_runtime_account_form ~lang =
  hints_of_bindings ~lang runtime_account_form_bindings

(* The recall form takes every key while it is open, so the pane's row --
   [e], [r], [Tab], [q] -- would name keys the form reads as its own. The row
   names only what the form reads. *)
let memory_recall_form_bindings =
  [ b ~ko:"행" Navigate "\xe2\x86\x91/\xe2\x86\x93" "row"
      ~help:"between the range row and the keeper rows"
  ; b ~ko:"범위" Navigate "\xe2\x86\x90/\xe2\x86\x92" "range"
      ~help:"on the range row: off, picked keepers only, or every keeper"
  ; b ~ko:"고르기" Act "Space" "pick"
      ~help:"on a keeper row, pick or drop that keeper; on the range row, the next range"
  ; b ~ko:"저장" Act "Enter" "save"
      ~help:"write the choice into runtime.toml through the preview and save [e] uses"
  ; b ~ko:"취소" Act "Esc" "cancel" ~help:"close the form; nothing is written"
  ]

let footer_hints_memory_recall_form ~lang =
  hints_of_bindings ~lang memory_recall_form_bindings

(* The exclusion form takes every key while it is open, as the recall form
   does, so its row names only what the form reads. *)
let typesafeai_exclusion_form_bindings =
  [ b ~ko:"행" Navigate "\xe2\x86\x91/\xe2\x86\x93" "row" ~help:"between the keeper rows"
  ; b ~ko:"고르기" Act "Space" "pick"
      ~help:"exclude the keeper under the cursor, or include it again"
  ; b ~ko:"저장" Act "Enter" "save"
      ~help:"write the list into runtime.toml through the preview and save [e] uses"
  ; b ~ko:"취소" Act "Esc" "cancel" ~help:"close the form; nothing is written"
  ]

let footer_hints_typesafeai_exclusion_form ~lang =
  hints_of_bindings ~lang typesafeai_exclusion_form_bindings

(* After a save the form shows the sign-in command and types nothing, so
   [y] copies it as it does in the link and browser views. *)
let runtime_account_saved_bindings =
  [ b ~ko:"로그인 명령 복사" Act "y" "copy sign-in"
      ~help:"send the sign-in command to the terminal clipboard (OSC 52)"
  ; b ~ko:"닫기" Act "Enter / Esc" "close"
  ]

let footer_hints_runtime_account_saved ~lang =
  hints_of_bindings ~lang runtime_account_saved_bindings

(* The prompts pane's read-only half. [o] swaps the registry for the assets
   shipped with the binary, and there [a], [i], [e] and [x] answer with a
   notice rather than acting (masc_tui.ml), so the row leaves them out and
   names where [o] goes back to. *)
let footer_hints_prompt_assets ~lang =
  let registry_only = [ "a"; "i"; "e"; "x" ] in
  let own, shared = config_pane_bindings Config_prompts in
  let own =
    own
    |> List.filter (fun binding -> not (List.mem binding.key registry_only))
    |> List.map (fun binding ->
           if String.equal binding.key "o" then
             { binding with label = "registry"; label_ko = "프롬프트 목록" }
           else binding)
  in
  config_row ~lang ~own ~shared

(* Work's task list, while it owns j/k. The Goals pane under the same
   surface reads [footer_hints Planning]; this is the other half of that one
   screen, so its keys come from a table too rather than from the renderer. *)
let work_tasks_bindings =
  [ b ~ko:"선택" Navigate "j/k" "select" ~help:"move through Work's open tasks"
  ; b ~ko:"목표" Navigate "t / Esc" "Goals" ~help:"hand j/k back to the Goals list"
  ; b ~ko:"상세" Act "Enter" "detail" ~help:"open the selected task"
  ]
  @ listing_meta

let footer_hints_work_tasks ~lang = hints_of_bindings ~lang work_tasks_bindings

(* The step Esc and Left take next on the Code surface. Both walk one ladder,
   from the layer drawn on top down to the project tree; only Esc goes on from
   the bottom rung to the ring parent. The two key arms in masc_tui.ml and the
   footer read this one answer, so the footer cannot name Left where the
   ladder has no step left for it. It used to be two copies of the ladder in
   the arms and the words "Left / Esc" on every tree footer, which at the
   project root named a key that did nothing. *)
type code_back =
  | Close_code_notes
  | Close_code_diff
  | Close_code_history
  | Return_to_code_tree
  | Climb_code_directory
  | Climb_to_code_project
  | Leave_code_for_workspace

let code_back_step (state : state) =
  if state.code_notes_open then Close_code_notes
  else if state.code_diff_open then Close_code_diff
  else if state.code_history_open then Close_code_history
  else if state.code_focus_file = Right_pane then Return_to_code_tree
  else if not (String.equal state.code_dir "") then Climb_code_directory
  else if state.code_scope <> Code_scope_project then Climb_to_code_project
  else Leave_code_for_workspace

(* The Code surface's footer, which the renderer used to spell by hand. It
   named d, H, m and w and nothing else, so the three language-server keys
   never appeared on the screen they work on -- and neither did blame or the
   row search when those arrived. Projected here, from the table the help
   sheet already reads, and narrowed to what the current mode answers: an
   overlay owns the pane, so the keys that act on the code underneath are
   dead while it is up, and the tree pane answers none of the file keys. *)
type code_file_presence =
  | No_file
  | File_current

(* [h] and [l] move focus between the tree and a file, and only while a file
   read is current -- loading, shown or failed. With none there is no pane to
   move to and the keys end in [()]. The dispatcher and the footer both read
   this answer, so the pair is named exactly where it answers. *)
let code_file_is_current (state : state) =
  Option.is_some (Masc_tui_fetched.current_key state.code_file)

(* [d] on the file list opens the project's Git changes. The arm answers the
   project's own workspace only: a keeper's or a repository's tree has no arm
   for the key and it ends in [()]. The dispatcher and the footer both read
   this answer, so the pair is named exactly where it answers. *)
let code_tree_opens_changes = function
  | Code_scope_project -> true
  | Code_scope_keeper _ | Code_scope_repo _ -> false

type code_pane =
  | Code_tree of code_file_presence * code_workspace_scope
      (** the file list has focus below the project root, over the workspace
          the scope names *)
  | Code_root of code_file_presence * code_workspace_scope
      (** the file list has focus at the project root, over the workspace the
          scope names *)
  | Code_file  (** a file is open and nothing covers it *)
  | Code_diff
  | Code_notes  (** wrapped memo document is drawn over the file *)
  | Code_history  (** complete history document is drawn over the file *)

let code_pane_of (state : state) =
  if state.code_focus_file <> Right_pane then
    let file = if code_file_is_current state then File_current else No_file in
    if code_back_step state = Leave_code_for_workspace then
      Code_root (file, state.code_scope)
    else Code_tree (file, state.code_scope)
  else if state.code_notes_open then Code_notes
  else if state.code_history_open then Code_history
  else if state.code_diff_open then Code_diff
  else Code_file

let footer_hints_code_hover ~lang = hints_of_bindings ~lang
  [ b ~ko:"스크롤" Navigate "j/k" "scroll"
  ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
  ; b ~ko:"처음/끝" Navigate "Home/End" "edges"
  ; b ~ko:"코드로" Navigate "Esc / Left" "return to code"
  ; b ~ko:"도움말" Meta "?" "help"
  ]

let code_notes_bindings =
  [ b ~ko:"스크롤" Navigate "j/k" "scroll"
  ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
  ; b ~ko:"처음/끝" Navigate "Home/End" "edges"
  ; b ~ko:"닫기" Act "m" "close"
  ; b ~ko:"뒤로" Navigate "Esc" "back"
  ; b ~ko:"도움말" Meta "?" "help"
  ]

let code_history_bindings =
  [ b ~ko:"Task" Act "t" "Task" ~help:"inspect the Task named by the selected Keeper record; Esc returns to this history position"
  ; b ~ko:"diff" Act "d" "diff" ~help:"on a commit row, show what that commit changed in this file; on a Keeper record, expand or collapse its recorded text (failed calls show attempted text)"
  ; b ~ko:"새로 조회" Meta "r" "refresh"
  ; b ~ko:"스크롤" Navigate "j/k" "scroll"
  ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
  ; b ~ko:"닫기" Navigate "H" "close"
  ; b ~ko:"처음/끝" Navigate "Home/End" "edges"
  ; b ~ko:"열기" Act "Enter" "open" ~help:"open the record owning the first visible row; metadata and failure rows have no target"
  ; b ~ko:"뒤로" Navigate "Left / Esc" "back"
  ; b ~ko:"도움말" Meta "?" "help"
  ]

let footer_hints_code ~lang ~pane =
  (* The draft keys ([e], [S], [V], [X], [A (draft)]) belong here too: the
     dispatcher answers them only with the file pane focused and no diff,
     history or notes drawn over it. *)
  let file_keys =
    [ "Shift-Left / Shift-Right"; "K"; "D"; "R"; "B"; "y"; "b"; "d"; "H"; "m"
    ; "e"; "S"; "V"; "X"; "A (draft)" ]
  in
  (* One key belongs to one pane and was showing on all three: [Enter
     (history)] opens a commit's pull request and only the history view has
     commits. Named apart from [file_keys] because it is the overlay's own,
     not the file's. *)
  let overlay_keys = [ "Enter (history)" ] in
  let dead =
    match pane with
    | Code_tree (file, scope) | Code_root (file, scope) ->
        (* With no file read current, [h] and [l] have no pane to move to
           ([code_file_is_current]), and the row named them on the first
           screen of Code. *)
        let pane_keys = match file with
          | No_file -> [ "h/l" ]
          | File_current -> [] in
        (* [d] on the list is not a file key: it opens the project's Git
           changes where the dispatcher has that arm. *)
        let tree_file_keys =
          if code_tree_opens_changes scope then
            List.filter (fun key -> not (String.equal key "d")) file_keys
          else file_keys in
        overlay_keys @ tree_file_keys @ pane_keys
    | Code_file ->
        (* The arm behind Right and Enter opens a tree row or answers the
           history overlay. With the file pane focused and nothing over it, it
           ends in [()]. The row named the key anyway, and the fitter never
           drops the Enter atom, so a key that does nothing kept its place in
           every narrow file footer. *)
        "Right / Enter" :: overlay_keys
    | Code_diff -> overlay_keys @ ("Right / Enter" ::
        List.filter (fun key -> not (String.equal key "Shift-Left / Shift-Right")) file_keys)
    | Code_notes -> "Right / Enter" :: overlay_keys @ file_keys
    | Code_history ->
        (* [Right / Enter] names the tree and file panes' open. With the
           history overlay up, the one arm behind Right and Enter takes the
           overlay's branch instead, so the row drew two items holding the
           Enter atom and called both of them "open". *)
        "Right / Enter" :: file_keys
  in
  let visible = for_surface Code
      |> List.filter (fun b -> not (List.mem b.key dead)) in
  (* At the project root Left has no step left to take ([code_back_step]);
     Esc alone goes on, to the ring parent. *)
  let esc_alone b =
    if String.equal b.key "Left / Esc" then { b with key = "Esc" } else b in
  (* The footer spells the pan key in arrows: 13 cells with its label where the
     words take 28. The sheet keeps the words. *)
  let pan_arrows b =
    if String.equal b.key "Shift-Left / Shift-Right" then { b with key = "Shift-←/→" }
    else b in
  let visible = match pane with
    | Code_diff ->
        let pan, others = List.partition
            (fun b -> String.equal b.key "Shift-Left / Shift-Right") visible in
        List.map pan_arrows pan @ List.map esc_alone others
    | Code_root _ -> List.map esc_alone visible
    | Code_file -> List.map pan_arrows visible
    | Code_tree _ | Code_notes | Code_history -> visible in
  visible
  |> List.map (fun b ->
       if String.equal b.key "j/k" then
         (match pane with
          | Code_tree _ | Code_root _ -> b
          | Code_file | Code_diff | Code_notes | Code_history ->
              { b with label = "scroll"; label_ko = "스크롤" })
       else if String.equal b.key "d" then
         (* On the list the key shows the project's changes; on an open file
            it shows that file's diff. *)
         (match pane with
          | Code_tree _ | Code_root _ ->
              { b with label = "changes"; label_ko = "변경" }
          | Code_file | Code_diff | Code_notes | Code_history -> b)
       else b)
  |> hints_of_bindings ~lang
  |> fun hints ->
      match pane with
      | Code_notes -> hints_of_bindings ~lang code_notes_bindings
      | Code_history -> hints_of_bindings ~lang code_history_bindings
      | Code_tree _ | Code_root _ | Code_file | Code_diff -> hints

(* The ordinary reading and its picker answer different Enter keys. The
   footer reads the same pick/filter state the dispatcher owns; printable
   letters only belong to the surface while no filter is being typed. *)
let runtime_parent_bindings parent =
  let name_bindings ~ko enter =
    [ b ~ko Act "Enter" enter
    ; b ~ko:"초안·안내 전체" Navigate "PgUp" "read draft/context"
    ; b ~ko:"지우기" Act "Backspace" "erase"
    ; b ~ko:"취소" Act "Esc" "cancel" ] in
  match parent with
  | Runtime_media_parent ->
      [ b ~ko:"전체 읽기" Act "v" "read all"
          ~help:"read full IDs, admission and results without closing the editor; ! marks a declared slot not admitted in the last observation"
      ; b ~ko:"추가" Act "a" "add"
      ; b ~ko:"선택" Navigate "j/k" "select"
      ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
      ; b ~ko:"처음/끝" Navigate "Home/End" "edges"
      ; b ~ko:"제거" Act "x" "drop"
      ; b ~ko:"순서 변경" Act "J/K" "reorder"
      ; b ~ko:"맨 앞으로" Act "1" "make first"
      ; b ~ko:"닫기" Act "Esc" "close"
      ; b ~ko:"새로 조회" Meta "r" "refresh"
      ; b ~ko:"도움말" Meta "?" "help" ]
  | Runtime_prompt_parent (Lane_name_prompt _) ->
      name_bindings ~ko:"첫 런타임 선택" "choose first runtime"
  | Runtime_prompt_parent (Lane_rename_prompt _) ->
      name_bindings ~ko:"이름·참조 변경" "rename and rewrite references"
  | Runtime_prompt_parent (Lane_remove_prompt _) ->
      [ b ~ko:"제거 확인" Act "D" "confirm removal"
      ; b ~ko:"확인 해제·전체 읽기" Act "v" "disarm and read all"
      ; b ~ko:"뒤로" Act "Esc" "back" ]

let footer_hints_runtime_parent ~lang ~parent =
  runtime_parent_bindings parent |> hints_of_bindings ~lang

let footer_hints_runtime ~lang ~(mode : runtime_mode) ~picker =
  match picker with
  | None ->
      List.filter_map (runtime_footer_binding ~mode) runtime_keys
      @ row_list_edges @ listing_meta
      |> hints_of_bindings ~lang
  | Some picker ->
      let pick = picker.rlp_pick in
      let enter = match pick with
        | Pick_new_lane _ -> b ~ko:"만들기" Act "Enter" "create"
        | Pick_conversation_lane _ | Pick_exact_lane _ | Pick_media_failover ->
            b ~ko:"덧붙이기" Act "Enter" "append"
        | Pick_exact_lane_replacement _ | Pick_route_default ->
            b ~ko:"바꾸기" Act "Enter" "replace"
      in
      let controls = match picker.rlp_filter with
        | None ->
            [ b ~ko:"취소" Act "e / E / Esc" "cancel"
            ; b ~ko:"선택" Navigate "j/k" "move"
            ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
            ; b ~ko:"필터" Search "/" "filter"
            ] @ row_list_edges @ listing_meta
        | Some query ->
            let back = match pick with
              | (Pick_exact_lane _ | Pick_exact_lane_replacement _)
                when String.equal query "" -> b ~ko:"취소" Act "Esc" "cancel"
              | Pick_route_default | Pick_conversation_lane _ | Pick_exact_lane _
              | Pick_exact_lane_replacement _ | Pick_new_lane _
              | Pick_media_failover -> b ~ko:"필터 지우기" Act "Esc" "clear filter"
            in
            [ back
            ; b ~ko:"선택" Navigate "↑/↓" "move"
            ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
            ] @ row_list_edges
      in
      enter :: controls |> hints_of_bindings ~lang

let footer_hints_resources ~lang ~detail_focus =
  for_surface Resources
  (* The focused pane is this surface's two states: [[ / ]] reads the
     adjacent resource and the dispatcher answers it only with the text
     focused. *)
  |> List.filter (answers_in_state ~detail_open:detail_focus)
  |> List.map (fun binding ->
         if String.equal binding.key "j/k" then
           if detail_focus then
             { binding with label = "scroll text"; label_ko = "본문 스크롤" }
           else { binding with label = "move"; label_ko = "선택" }
         else binding)
  |> hints_of_bindings ~lang

let footer_hints_resource_save ~lang ~pending =
  (if pending then [] else [b ~ko:"파일 만들기" Act "Enter" "create file"])
  @ [ b ~ko:"입력 닫기" Navigate "Esc" "close input"
    ; b ~ko:"경로 지우기" Act "Ctrl-U" "clear path"
    ; b ~ko:"결과 읽기" Navigate "PgUp/PgDn" "read result" ]
  |> hints_of_bindings ~lang

let opens_keepers ~message_mode key =
  (not message_mode) && String.equal key keepers_jump.key

let chat_quiet_leave ~input_supported ~turn_active ~draft_empty key =
  (String.equal key "Q"
   && (not input_supported || (turn_active && draft_empty)))
  || (String.length key = 1 && Char.code key.[0] = 17)

(* An armed two-press action expires on the next unrelated input: otherwise
   it waits indefinitely and a later press of the same key -- after the
   cursor has moved, after a refresh -- submits work the operator armed
   minutes ago for something else.

   Two facts, not one. [input_seen] says the loop actually read something:
   the loop turns on a timeout as well, and a turn that read nothing is not
   an unrelated input. [key] says what it read, and it is [None] for a
   mouse report, a paste, and a graphics reply -- deliberate input that is
   not the second press, so it cancels.

   The rule lives here because the dispatch loop restated it once per armed
   field and the connector unbind's restatement read the timeout turn as an
   unrelated key. Its arm therefore survived one iteration: the two [u]
   presses removed a binding only when both bytes arrived in the same
   read. *)
let cancels_two_press ~input_seen ~key ~second_press =
  input_seen
  &&
  match key with
  | None -> true
  | Some pressed -> not (List.exists (String.equal pressed) second_press)

(* The Fusion detail view: the keys table owns the key list; the renderer
   owns the live scroll numbers it appends after them. ([view] stays
   [Fusion]; [fusion_mode] decides list vs detail — masc_tui_types.ml.)
   [position] is the window the renderer drew ({!Masc_tui_scroll.window_text}),
   so the footer agrees with what is on screen.

   [K] and [B] answer in the detail as they do on the list (masc_tui.ml
   matches them under [Fusion_detail]); the footer left them out, and a body
   row said "K Keeper · B Board" in its own notation instead. *)
let footer_hints_board_read ~lang ~focus_posts ~focus_comments ~full_history
    ~(layout : board_read_layout) ~has_attachments ~has_successor =
  let pane_keys =
    match layout with
    | Board_read_split -> [ b ~ko:"영역" Navigate "h/l" "pane"; b ~ko:"전환" Navigate "Ctrl-W" "switch" ]
    | Board_read_wide | Board_read_one_pane -> []
  in
  (* The label is where the key goes, and [z] goes both ways. Drawn as "wide"
     in either state it named the screen an operator was already looking at:
     on a wide detail the footer offered to widen it. On one pane there is no
     second layout to reach, and the key is not drawn. *)
  let width_key =
    match layout with
    | Board_read_split -> [ b ~ko:"넓게" Navigate "z" "wide" ]
    | Board_read_wide -> [ b ~ko:"목록" Navigate "z" "list" ]
    | Board_read_one_pane -> []
  in
  (* On the comments j/k move the selection, not the rows, and the vote keys
     act on that selection: the labels say which, so v cannot be read as a
     vote on the post above. *)
  let vote_key =
    if focus_comments && not focus_posts then
      b ~ko:"댓글 추천 / 비추천" Act "v / V" "comment up / down"
    else board_vote_key
  in
  hints_of_bindings ~lang
    ([ b ~ko:(if focus_posts then "글" else if focus_comments then "댓글" else "본문") Navigate "j/k"
         (if focus_posts then "posts"
          else if focus_comments then "comment" else "body")
     ; board_read_focus_key
     ; b ~ko:"글" Navigate "[/]" "post"
     ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
     ]
     @ (if has_successor then [b ~ko:"후속 글" Navigate "S" "successor"] else [])
     @ pane_keys @ width_key
     (* [o] goes after the pane and width keys. The fitter gives up the last
        droppable hint first, so a key placed ahead of them pushes them off:
        at 120 cells the split footer lost Ctrl-W:switch, and at 130
        z:wide, to "o:all comments". Placed here it is the Navigate hint
        dropped first, and up to 134 cells the row is the one drawn before
        [o] existed. *)
     (* A post with attachments numbers them for the open key; the hint
        rides ahead of [o] with a short label, so a narrow footer gives it
        up before the comment reader, which the fitter drops last on this
        row. Measured at 140 cells: [o] and this hint ride the same drop
        wave as [c], [Y], [r] and [Tab] — the row is over budget long
        before this key existed. *)
     @ (if has_attachments then [ b ~ko:"열기" Navigate "1-9" "open"; b ~ko:"원본 이미지" Navigate "O" "original image" ] else [])
     @ (if focus_posts then [] else
          [b ~ko:"다이어그램" Navigate "Ctrl-O" "diagram"; b ~ko:"다이어그램 선택" Navigate ",/." "choose diagram"])
     @ [ b ~ko:(if full_history then "최근 20개" else "모든 댓글") Navigate "o" (if full_history then "newest 20" else "all comments") ]
     @ [ vote_key
       ; board_reply_key
       ; board_copy_key
       ; b ~ko:"뒤로" Act "Left / Esc" "back"
       ; b ~ko:"새로 조회" Meta "r" "refresh"
       ; b ~ko:"다음 화면" Meta "Tab" "next"
       ])

(* A missing post has no read pane or copy target. Keep only the Board
   bindings that still act while loading or after a failed read. *)
let footer_hints_board_pending ~lang =
  for_surface Board
  |> List.filter (fun binding ->
         List.exists (String.equal binding.key) [ "r"; "Left / Esc"; "Tab" ])
  |> hints_of_bindings ~lang

(* The scroll position is not here. It is not a key and it cannot be looked
   up, so it travels to the footer as its own argument
   ([Masc_tui_footer.line]'s [?position]) rather than as two spaces on the end
   of this string -- spelled that way the fitter read it as one more key item
   and gave it up first, and on this surface it was never drawn. *)
let footer_hints_fusion_detail ~lang =
  hints_of_bindings ~lang
    ([ b ~ko:"스크롤" Navigate "j/k" "scroll"
     ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
     (* The table scopes this key to the open detail, and this footer is what
        an open detail draws, so the key belongs on it. It was on the list
        footer instead, where the dispatcher refuses it. *)
     ; b ~ko:"이전 / 다음" Navigate "[ / ]" "previous / next"
         ~help:"step to the run before or after this one"
     ; fusion_caller_key
     ; fusion_board_key
     ; b ~ko:"복사" Act "Y" "copy"
     ; b ~ko:"뒤로" Act "Esc" "back" ~help:"Left or Esc returns to the run list"
     ]
     @ listing_meta)

(* Lanes sub-modes ([lanes_mode] owns overview/list/detail/notice —
   masc_tui_types.ml). The overview footer stays [for_surface Lanes]; these
   name the drill-downs the same way the Fusion detail footer does. *)
(* The run list's own keys. The footer, the [?] sheet and the key reference
   all read this list: the sheet used to open on the Lanes overview's keys
   here, whose Esc row said "back to Dashboard" on a screen where Esc goes
   back to the overview, and it had no row at all for the older page. *)
let lane_run_list_bindings ~has_runs ~has_older =
  (if has_runs then
     [ b ~ko:"선택" Navigate "j/k" "move" ~help:"move the run cursor"
     ; b ~ko:"상세" Act "Right / Enter" "prompt"
         ~help:"open the run's prompt and output"
     ]
   else [])
  @ (if has_older then
       [ b ~ko:"앞선 기록" Navigate ">" "older"
           ~help:"load the next retained-run page from the server" ]
     else [])
  @ [ b ~ko:"뒤로" Act "Left / Esc" "back" ~help:"back to the lane overview" ]

let footer_hints_lanes_run_list ~lang ~has_runs ~has_older =
  hints_of_bindings ~lang
    (lane_run_list_bindings ~has_runs ~has_older @ listing_meta)

let preflight_detail_binding =
  b ~ko:"JEV 근거" Act "d" "JEV evidence" ~help:"in Librarian preflight run detail: expand or fold model, probabilities and original input/output evidence"

let lane_run_detail_bindings =
  [ b ~ko:"스크롤" Navigate "j/k" "compare" ~help:"scroll Input and Output together"
  ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page" ~help:"page both evidence panes"
  ; b ~ko:"이전 / 다음 실행" Navigate "[ / ]" "previous / next run"
      ~help:"step to the run before or after this one in the list"
  ; b ~ko:"뒤로" Act "Left / Esc" "back" ~help:"back to the run list"
  ]

(* The position travels as [Masc_tui_footer.line]'s [?position], for the
   reason spelled over [footer_hints_fusion_detail]. The preflight key goes
   first, ahead of the group order, so a narrow footer gives it up last. *)
let footer_hints_lanes_run_detail_for ~lang ~preflight =
  let detail = hints_of_bindings ~lang (lane_run_detail_bindings @ listing_meta) in
  if preflight then hints_of_bindings ~lang [preflight_detail_binding] ^ "  " ^ detail
  else detail

(* The recorded activity of one repository: its list, and the context of
   the selected change. *)
let footer_hints_workspace_activity ~lang =
  hints_in_order ~lang
    [ b ~ko:"맥락" Navigate "v" "context"
    ; b ~ko:"선택" Navigate "j/k" "select"
    ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
    ; b ~ko:"파일" Navigate "Enter" "file"
    ; b ~ko:"다시 읽기" Act "r" "refresh"
    ; b ~ko:"뒤로" Navigate "Esc" "back"
    ]

let footer_hints_workspace_activity_context ~lang =
  hints_in_order ~lang
    [ b ~ko:"스크롤" Navigate "j/k" "scroll"
    ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
    ; b ~ko:"처음/끝" Navigate "Home/End" "edges"
    ; b ~ko:"파일" Navigate "Enter" "file"
    ; b ~ko:"다시 읽기" Act "r" "refresh"
    ; b ~ko:"목록" Navigate "Esc" "list"
    ]

let footer_hints_git_changes ~lang =
  hints_of_bindings ~lang
    ([ b ~ko:"선택" Navigate "j/k" "move"
     ; b ~ko:"diff" Act "Right / d / Enter" "diff"
     ; b ~ko:"코드에서 열기" Act "v" "open in code"
     ; b ~ko:"PR 열기" Act "p" "open PR"
     ; b ~ko:"작업 / 목표" Act "t/g" "task / goal"
     ; b ~ko:"뒤로" Act "Left / Esc" "back"
     ]
     @ listing_meta)

let footer_hints_git_diff ~lang =
  hints_of_bindings ~lang
    ([ b ~ko:"좌우 이동" Navigate "Shift-Left / Shift-Right" "pan"
     ; b ~ko:"스크롤" Navigate "j/k" "scroll"
     ; b ~ko:"코드에서 열기" Act "v" "open in code"
     ; b ~ko:"PR 열기" Act "p" "open PR"
     ; b ~ko:"작업 / 목표" Act "t/g" "task / goal"
     ; b ~ko:"파일 목록으로" Act "Left / Esc" "back to files"
     ]
     @ listing_meta)

(* The Memory fact browser drawn over the health table. Its own row because
   the keys change with it: the cursor moves rows instead of scrolling the
   table, [c] narrows by the categories the loaded store holds, and Esc
   closes the browser rather than leaving the surface.

   The footer row and the sheet read this one list. The keys are not the
   health row's under these names -- Enter opens the reading, s reorders
   instead of pausing a keeper -- so a reader who has not pressed them learns
   them only from [?], which is what [?] answers. *)
let bindings_memory_changes =
  memory_browser_pages @
  [ b ~ko:"이동" Navigate "j/k" "move"
  ; b ~ko:"전문" Act "Enter" "full reading"
      ~help:"read all original and successor claims of the selected committed change"
  ; b ~ko:"… 변화 카드" Act "." "… change cards"
      ~help:"open only the selected change as before/change/after cards with wrapped claim excerpts; full text remains on Enter"
  ; b ~ko:"연결 트리" Act "Ctrl-O" "connected tree"
      ~help:"open the selected change's complete connected observed memory lineage with the offline Pele Mermaid preview"
  ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
  ; b ~ko:"뒤로" Act "Esc" "back to facts" ]
  @ row_list_edges @ listing_meta

let footer_hints_memory_changes ~lang = hints_of_bindings ~lang bindings_memory_changes

let bindings_memory_facts =
  memory_browser_pages @
  [ b ~ko:"이동 / 스크롤" Navigate "j/k" "move" ~rows:Needs_row
  ; b ~ko:"상세" Act "Enter" "detail" ~rows:Needs_row
      ~help:"read the whole fact in a wide overlay that owns the terminal"
  ; b ~ko:"분류" Act "c / C" "category" ~help:"cycle category filter (forward / backward)"
  ; b ~ko:"분류 영역" Act "d" "Category pane" ~help:"show or hide the Category rail on wide screens; facts use the full width by default"
  ; b ~ko:"정렬" Act "s" "sort" ~help:"cycle sort (recency, last retrieved, retrieved count, category, claim)"
  ; b ~ko:"전체 Keeper" Act "a / A" "all fleet" ~help:"switch to consolidated memory across entire fleet"
  ; b ~ko:"필터" Search "/" "filter" ~help:"live text filter / search"
  ; b ~ko:"다음 / 이전 일치" Search "n / N" "next / previous match" ~rows:Needs_row
  ; b ~ko:"닫기 / 지우기" Act "Esc" "close / clear" ~help:"clear filter or exit to health table"
  ]
  @ row_list_edges @ listing_meta

(* [has_rows] is whether the browser holds a fact. A keeper with none, or a
   filter that left none, has nothing for [j/k], [Enter] and [n / N] to act on.
   [c / C], [s], [a / A] and [/] stay: a filter that left no fact is undone
   with them. *)
let footer_hints_memory_facts ~lang ~cols ~has_rows =
  let bindings =
    if cols >= Masc_tui_roster_pane.threshold_cols then bindings_memory_facts
    else List.filter (fun (binding : binding) -> binding.key <> "d") bindings_memory_facts
  in
  hints_of_bindings ~lang (List.filter (answers_in_state ~has_rows) bindings)

(* The reading the browser's Enter opens. One fact scrolls under the cursor
   instead of the cursor moving rows, so it owns page and edge keys the
   browser row has none of. The window marker it leads with is not a key, and
   the renderer adds it. *)
let bindings_memory_fact_detail =
  [ b ~ko:"이동 / 스크롤" Navigate "j/k" "scroll"
  ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
  ; b ~ko:"처음/끝" Navigate "g / G" "top/bottom"
      ~help:"jump to the first or last line of the fact"
  ; b ~ko:"닫기" Act "Esc" "close" ~help:"return to the fact list"
  ]

let memory_fact_detail_hints ~lang = hints_of_bindings ~lang bindings_memory_fact_detail

(* The reading Activity's [Enter] opens on an event row. One event's evidence
   scrolls under the cursor instead of the cursor moving rows, so it owns page
   and edge keys the feed row has none of. *)
let bindings_acting_evidence =
  [ b ~ko:"스크롤" Navigate "j/k" "scroll"
  ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
  ; b ~ko:"처음/끝" Navigate "g / G" "top/bottom"
      ~help:"jump to the first or last line of the event evidence"
  ; b ~ko:"이벤트 목록으로" Act "Left / Esc" "back to events"
      ~help:"close the snapshot and return to the live event feed"
  ]
  @ [ listing_next; listing_quit ]

let acting_evidence_hints ~lang = hints_of_bindings ~lang bindings_acting_evidence

(* One section per surface family; the strip's spelling names it. Keepers
   sub-modes collapse into the two sections an operator thinks in. *)
let help_surfaces : (string * surface) list =
  [ "Operations", Overview
  ; "Work", Planning
  ; "Keepers", Keepers Keeper_list
  ; "Operations / Usage", Metrics
  ; "Work / Board", Board
  ; "Workspace", Repositories
  ; "System", Config
  ; "Activity", Acting
  ; "Keeper detail", Keepers Keeper_detail
  ; "Chat", Keepers Keeper_message
  (* Three screens a Keeper detail drills into, each with keys of its own and
     no section until now: [?] there opened on Global and named no section for
     the screen the reader was standing on. Named the way their titles read
     ("Keepers > <keeper> > logs"), which is also how Schedules is named
     below. The runtime picker earns its own: [d] follows [runtime].default
     and [/] narrows the list, and neither is guessable. *)
  ; "Keepers / Logs", Keepers Keeper_logs
  ; "Keepers / Calls", Keepers Keeper_calls
  ; "Keepers / Runtime", Keepers Keeper_runtime_pick
  ; "Features & plugins", Lanes
  ; "Features & plugins / Clients", Clients
  ; "Approvals", Approvals
  ; "Work / Task Review", Verification
  ; "Work / Task Verdicts", Harness
  ; "Fusion", Fusion
  (* "Schedules", the name the title bar and the palette both use. It read
     "Keeper detail / Automation" -- a Keeper detail tab that has no keys of
     its own and no route to this screen -- so a reader who typed "go
     Schedules" and pressed [?] found this screen's keys under the name of a
     screen they were not on. The family is Keepers, which is where the strip
     puts the highlight while this surface is open. *)
  ; "Keepers / Schedules", Schedules
  ; "Memory", Memory
  ; "Workspace / Code", Code
  ; "Changes", Changes
  ; "System / Runtime", Runtime
  ; "Features & plugins / Resources", Resources
  ; "Features & plugins / Tools", Tools
  ; "System / Logs", System_logs
  (* Its keys are the least guessable on the product -- [B] opens the Browser
     Lane, [Ctrl-O] previews a tab, [b / u] bind and unbind a channel -- and
     the sheet built no section for them at all. *)
  ; "Connectors", Connectors
  ]

(* The paragraphs docs/guides/TUI-KEYS.md prints under a section's table, in
   the order they read there. A key whose behaviour outgrows its one-line
   help cell -- what an asynchronous save keeps, what a retained observation
   means -- is explained here because that document is generated from this
   module: a paragraph written into it by hand fails [test_tui_keys_doc], and
   regenerating deletes it. Each paragraph is Markdown, with the line breaks
   the document prints.

   Keyed by surface, the same key as the section, so a paragraph cannot land
   under a title that merely reads alike. Reference only: the [?] sheet lists
   keys and does not draw these. *)
let reference_notes : surface -> string list = function
  | Keepers Keeper_list ->
      (* The last paragraph also explains the Runtime catalogue, Overview and
         Board readers. It reads under Keepers because the reference has
         carried it there. *)
      [ "Keeper settings `e` opens TOML and `E` opens JSON in the external editor.\n\
         Both read a fresh snapshot asynchronously and use the same guarded save.\n\
         In TOML, remove an assignment and list `max_context_override` or\n\
         `remote_endpoint` in `reset_fields` to clear it; an omitted field is unchanged.\n\
         Navigation stays available while the receipt is pending. Repeated edit keys\n\
         share that save. A late receipt cannot refresh another Keeper."
      ; "After a refusal or unconfirmed result, `e` or `E` reads current settings and restores\n\
         only your changed values for review in the editor. Untouched fields use current\n\
         values. The old revision and context-shrink confirmation are not reused; saving\n\
         requires the new editor roundtrip. Original input and receipts stay with their\n\
         operation. Sandbox shortcuts use the same owned save operation: they read current\n\
         settings and the required revision before sending the selected profile. Repeated\n\
         keys share a pending same-Keeper save; selecting a new profile never rewrites it.\n\
         An already observed matching profile sends no POST. Failed shortcuts retain their\n\
         selection; an explicit next key rereads current before another save. Retained editor\n\
         changes survive shortcut operations. The external editor keeps its own terminal\n\
         interaction. Runtime and painted latency remain unmeasured."
      ; "Keeper Runtime picker assignments also retain an owned operation: original\n\
         Keeper, workspace, concrete Runtime or clear-to-default choice, current snapshot,\n\
         and assignment revision. Navigation stays available; a pending same-Keeper\n\
         Settings, Sandbox or assignment save prevents another dispatch without closing\n\
         the picker. Different Keepers retain independent operations. The existing config\n\
         read and assignment POST remain the two logical save requests. Local workspace\n\
         and read authority are checked again before POST; server assignment CAS remains\n\
         the write precondition. This adds no atomic server workspace precondition."
      ; "Progress, warnings, conflicts and uncertain outcomes stay with the original\n\
         operation for this TUI session. Cancellation before possible dispatch is not-sent;\n\
         after possible dispatch it is unconfirmed. HTTP 400 can include an IO failure,\n\
         so it does not prove that no write happened. Explicitly choosing again reads\n\
         current revision; the old request never resends itself. A committed receipt proves\n\
         configured assignment and the application results it reports, not which Runtime\n\
         is executing a current Keeper turn. Execution and painted latency remain unmeasured."
      ; "Runtime catalogue consumers share an in-flight catalogue read for the same\n\
         workspace. Explicit refresh and post-save demand wait for one fresh follow-up\n\
         after that read, rather than starting overlapping catalogue requests. Further\n\
         refreshes during the follow-up may require another read. Last observed rows stay\n\
         visible with refreshing/stale status and the latest refresh failure. A successful\n\
         empty response completes the read; it does not keep saying loading. Exact slot\n\
         replacement still waits for a fresh catalogue. Nested pickers and recent-context\n\
         catalogue demand resume after workspace reconfirmation. A different workspace\n\
         clears the old rows and demand. This sharing covers the catalogue launcher;\n\
         Overview and the Runtime operator surface retain their separate readers.\n\
         Catalogue rows, configured default route and Keeper assignments share one\n\
         validated observation. A missing usage-window observation stays an explicit\n\
         unknown alongside an otherwise usable catalogue.\n\
         Overview keeps catalogue and usage availability independent: valid usage remains\n\
         available after catalogue validation fails, and usage failure leaves healthy\n\
         catalogue rows usable. Both observations belong to the same response; a failed\n\
         usage read does not borrow a prior response's quota identity.\n\
         Full-refresh progress labels a composed read as partial when one returned result\n\
         failed, naming both failed and received components. This covers Runtime\n\
         catalogue/usage, Board posts/hearths and available Keeper roster/Candle results.\n\
         Partial is separate from full receipt; unfinished logical readers remain interrupted when\n\
         the refresh stops. These notices do not grant action authority or confirm Task completion.\n\
         Board also reports its posts/hearth readers before the pair returns. A completed\n\
         child remains visible when its parent fails or stops. A caught child cancellation\n\
         is interrupted; a started child without a terminal observation is unfinished.\n\
         Child intervals describe those observations, not proven worker exit or screen paint.\n\
         Board posts and hearth data also arrive independently under their original request.\n\
         Ready posts do not wait for the census; a pending or failed census retains its\n\
         last successful value. One dataset does not consume its sibling's result, and a\n\
         terminal bundle does not replay early data. Board remains pending while either\n\
         dataset is outstanding. These are UI-state rules; actual paint latency is unmeasured.\n\
         Census now distinguishes not read, initial reading, received (including empty),\n\
         unavailable and a retained observation after failure. Refreshing/stale values stay\n\
         available for hearth navigation; the census row and palette identify them as last\n\
         observed. Header/sidebar totals use only a received census without a pending census\n\
         read. A collector ending without a census result records unavailability. Workspace\n\
         withdrawal clears census values and candidates along with other Board data.\n\
         The post list has its own typed observation and pending slot. Initial loading,\n\
         not read, received empty and failed are distinct. Refresh/failure retains posts,\n\
         selected identity and compose input; list/sidebar and palette qualify retained\n\
         posts as last observed. A detail response enriches one matching row while keeping\n\
         the list's failure and pending ownership. Missing terminal results remain\n\
         unavailable, and workspace withdrawal clears list candidates. Changing sort/hearth\n\
         keeps the old listing with its original query until a new one succeeds, even if the\n\
         old result was empty. The listing/sidebar and palette qualify that observation;\n\
         its sort explanation, age column and census total use the observed query. Requested\n\
         controls stay separate, and detail enrichment does not relabel the list.\n\
         Admission diagnostics additionally keep the response's query, the controls at\n\
         application and the retained listing's query separate for success/failure. Missing\n\
         owned terminal data has no invented response query. These are request-linked log\n\
         fields; actual runtime logs and visible behavior remain separate evidence.\n\
         Full/navigation dispatch diagnostics also retain the original and current source\n\
         request through cold identity handoff. Planned Board conditions stay fixed even\n\
         if controls move; an originally non-Board read stays unrequested in that context.\n\
         Dispatch/rebind/cleanup observations are separate from actual HTTP starts, received\n\
         data and paint. A missing finish record remains an unfinished observation."
      ]
  | Config ->
      [ "Runtime model and account form saves keep input and its opening revision while\n\
         workspace checks, source reading, preview and guarded commit run outside the\n\
         key handler. Repeated submission shares the pending operation. During a pending\n\
         save, Esc leaves the form and keeps its operation; reopening Models with e/c or\n\
         runtime.toml with a restores the original input. A disconnected commit remains\n\
         unconfirmed and cannot be submitted again from that retained form. Ctrl-X closes\n\
         a retained terminal form and rereads configuration; the next open starts fresh.\n\
         The original receipt stays in session history. Confirmed account saves retain\n\
         their sign-in command in the session log. File commit, durability and runtime\n\
         application remain separate facts. Runtime and painted input latency are unmeasured."
      ; "The runtime.toml editor also returns to the input loop before its save finishes;\n\
         S retries a retained draft through the same owned asynchronous save. Its original\n\
         path, source revision and complete edited text are submitted together. Repeated\n\
         saves wait for the existing operation. Navigation keeps the draft; a late receipt\n\
         can complete only its original editing intent, including after ordinary source\n\
         refreshes, and cannot delete a later edit with the same text."
      ; "After an unconfirmed commit or durability result, older comparisons and already\n\
         in-flight reads cannot authorize retry. Read current with r, then explicitly use\n\
         u to keep your text and choose that revision, or U to replace the text. Choosing\n\
         a new base from a pre-outcome reading also cannot bypass revalidation. X discards\n\
         only the local draft; it does not claim that a pending server write was cancelled.\n\
         These changes do not make the external editor itself asynchronous or establish\n\
         measured key/paint latency."
      ; "Config source observations prepare whole-source tokenization, terminal sanitization\n\
         and the model table together from one immutable reading before UI admission.\n\
         Preparation uses the shared CPU path: the model table consumes already interpreted\n\
         server declarations instead of reparsing Runtime source or expanding local credential\n\
         homes. It reads no UI, environment, request ownership or palette state. The server\n\
         model envelope must match the reading's exact path and revision. Missing, unavailable\n\
         or malformed model evidence stays failed; source and other observations remain usable.\n\
         Source-only form parsing still retains Runtime's environment effects.\n\
         Account-group/model interpretation failure leaves the source available; email\n\
         observation failure stays independent. Model selection and source revision come\n\
         from that same reading."
      ; "Ordinary refreshes reuse an unchanged retained draft's existing tokenization and\n\
         the matching observation's current-file projection. Sharing tokenization does\n\
         not share editing ownership, adopt a revision or authorize retry. Existing\n\
         workspace/read authority, generation checks and queued follow-up policy still\n\
         control admission. Diagnostic clocks distinguish request start, prepared result\n\
         and UI admission decision; these are not painted-frame or key-latency evidence."
      ]
  | Approvals ->
      [ "When a selected question is too tall for the compact Approvals panel, it keeps\n\
         a short preview from the original question instead of disappearing behind a\n\
         hidden-question count. Where space permits, the preview points to `a` for the\n\
         complete Ask and its answers. The preview does not select or submit an answer;\n\
         the existing answer reader keeps the full prompt, choices and draft. With only\n\
         one content row, the selected preview takes that row; with none, no extra hidden\n\
         count is drawn beyond the available space."
      ]
  | Tools ->
      [ "Work Task detail and Tools original Task detail use source-bound history pages.\n\
         `H` extends the captured prefix; a failed page retains the same cursor for an\n\
         explicit retry. `r` requests a fresh latest prefix while keeping the prior\n\
         observation visible. The page demand follows terminal height, with no total\n\
         history cap. Exhaustion means the observed stored prefix ended; retained-away\n\
         history and Task completion are separate facts. Tools cadence does not reset a\n\
         paged history. A source change can refuse the cursor; use `r` to read anew."
      ; "Task body and history prepare independently. Their notices distinguish waiting\n\
         to start, arranging the text, waiting for the prepared result, and waiting for\n\
         the display state to update. An earlier display stays labelled while a newer\n\
         one is prepared. These stages describe display preparation, not Task progress\n\
         or completion."
      ]
  | Keepers (Keeper_detail | Keeper_message | Keeper_logs | Keeper_calls
            | Keeper_runtime_pick)
  | Overview | Acting | Metrics | Memory | Lanes | Clients | Board | Planning
  | Schedules | Verification | Harness | Fusion | Repositories | Code | Changes
  | Connectors | Runtime | Resources | System_logs -> []

let entries ~lang bindings =
  List.map
    (fun { key; label; label_ko; help; _ } ->
       ( key
       , match help, lang with
         | Some sentence, (Lang_ko | Lang_en) -> sentence
         | None, Lang_ko -> label_ko
         | None, Lang_en -> label ))
    bindings

(* The reader's own surface first, then the keys that work everywhere, then
   the rest as reference. A sheet that opens on Planning while the reader is
   on Overview is a list to search rather than an answer: the question [?]
   asks is "what can I do here", and twenty other surfaces are what sits
   underneath that answer.

   [current] is matched exactly rather than by ring position. The Keepers
   sub-modes are three sections here and one entry on the strip, and a reader
   in the chat is asking for the chat's keys, not the roster's. A surface with
   no section of its own simply matches nothing and the sheet reads as it did
   before this argument existed. *)
let here_marker = " \xc2\xb7 you are here"

(* The Keeper detail tabs. Until 2026-08-30 the renderer drew these as
   hand-written strings in its own [tab_hint] match, so the detail tabs were
   a second key list this module did not own -- the exact split the header
   above says cannot happen. [T] was missing from that string as well as
   from here, so toggling a provider was undocumented on every screen.

   The tabs' keys are conditional on the tab rather than the surface, which
   is why they are not in [for_surface]: listing them there would advertise
   them on the five tabs where they do nothing. *)
let keeper_detail_tab_bindings (tab : Masc_tui_types.keeper_detail_tab) =
  match tab with
  | Detail_items ->
      [ b ~ko:"미리 보기" Navigate "j/k" "preview"
      ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
      ; b ~ko:"처음/끝" Navigate "Home/End" "first/last"
      ; b ~ko:"보기" Navigate "v" "view" ~help:"all, owned, can buy, then face/neck/head/hand/base"
      ; b ~ko:"비교" Navigate "Space" "compare" ~help:"compare the try-on picture with the current outfit"
      ; b ~ko:"키퍼에게 부탁" Act "a" "ask Keeper" ~help:"prepare a price-bounded buy/equip chat draft; Enter sends it"
      ]
  | Detail_github ->
      [ b ~ko:"로그인" Act "L" "login" ~help:"start the gh device-flow login with the ticked scopes"
      ; b ~ko:"토큰" Act "P" "token" ~help:"set fine-grained PAT / token"
      ]
      (* One digit per scope the login can ask for, in the order the tab
         lists them, so a scope added to the server's list gets its key here
         without a second edit. *)
      @ List.mapi
          (fun index scope ->
            (* A scope is GitHub's own token, spelled the same in both
               languages. *)
            let scope = Masc.Keeper_github_identity.login_scope_to_string scope in
            b ~ko:scope Act (string_of_int (index + 1)) scope
              ~help:"tick or untick this scope for the next L login")
          Masc.Keeper_github_identity.all_login_scopes
  | Detail_sandbox ->
      [ b ~ko:"컨테이너 로그" Act "o" "actual logs"
      ; b ~ko:"백엔드" Act "d/m/s" "backend"
          ~help:"set the sandbox backend in place: docker / microvm / remote_ssh"
      ; b ~ko:"상세 페이지" Navigate "PgUp/PgDn" "detail page"
      ; b ~ko:"새로 조회" Meta "R" "refresh"
      ]
  | Detail_instructions ->
      [ b ~ko:"$EDITOR 로 TOML 고치기" Act "e" "edit TOML in $EDITOR"
          ~help:"multiline Keeper instructions; only changed fields are sent"
      ; b ~ko:"$EDITOR 로 JSON 고치기" Act "E" "edit JSON in $EDITOR"
          ~help:"the same settings and guarded save in JSON"
      ]
  | Detail_identity ->
      [ (* Arrows first: the digits only reach the first nine rows and the
           list is a declaration directory that can hold more. *)
        b ~ko:"연결" Navigate "arrows+enter" "connect"
      ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page" ~help:"move the cursor a page; Home/End go to the first and last service"
      ; b ~ko:"보기" Navigate "v" "view" ~help:"cycle all / attached only / not attached only"
      ; b ~ko:"정렬" Navigate "o" "order" ~help:"cycle attached first / declared order"
      ; b ~ko:"켜기/끄기" Act "T" "toggle" ~help:"turn the provider under the cursor on or off"
      ; b ~ko:"앱 등록" Act "A" "app"
          ~help:"open the app-registration form for it -- it asks for a Client ID"
      ; b ~ko:"연결 끊기" Act "D D" "disconnect"
          ~help:
            "twice: forget the stored token, drop the tools it attached, and ask \
             the provider to revoke what it still holds"
      ; b ~ko:"필터" Search "/" "filter"
      ; b ~ko:"새로 조회" Meta "R" "refresh"
      ]
  | Detail_channels ->
      [ b ~ko:"채널 종류" Navigate "j/k" "transport"
      ; b ~ko:"연결" Navigate "J/K" "binding"
      ; b ~ko:"상세 페이지" Navigate "PgUp/PgDn" "detail page"
      ; b ~ko:"연결 / 옮기기 / 끊기" Act "b / e / u u" "bind / reassign / remove"
          ~help:"bind a channel, reassign the selected row, or remove it twice-confirmed"
        (* Takes [U] from the runtime picker on this tab only, the way [u]
           is taken above: the picker stays on every other tab. *)
      ; b ~ko:"모두 끊기" Act "U U" "unbind all"
          ~help:"remove every channel binding of this Keeper on every \
                 transport, twice-confirmed; a channel rebound to another \
                 Keeper meanwhile is left as is"
      ]
  | Detail_info ->
      (* Lowercase [b] beside [B]: one partition, then all of them. It was
         [Q], but the global quit test takes [Q] as well as [q] and runs
         first, so the key armed the exit instead of the requeue. *)
      [ b ~ko:"게시판 다시 넣기" Act "b" "requeue board"
          ~help:
            "requeue the oldest blocked Board-attention partition; \
             its judgment call may run a second time"
      ; b ~ko:"게시판 모두 다시 넣기" Act "B" "requeue all board"
          ~help:
            "requeue every waiting Board-attention partition in order, with \
             a separate audited CAS for each; judgment calls may run again"
      ]
  | Detail_terminal ->
      (* [g] is the approval-gate toggle on every tab, so the Terminal does not
         borrow it for the top the way readers elsewhere do. *)
      [ b ~ko:"스크롤" Navigate "j/k" "scroll"
      ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
      ; b ~ko:"처음/따라가기" Navigate "Home/End" "oldest/follow"
          ~help:"Home goes to the oldest output kept; End goes back to the \
                 bottom and follows new output again"
      ]
  | Detail_automation ->
      [ b ~ko:"일정 쪽" Navigate "< / >" "schedule pages"
          ~help:"previous / next page for this Keeper; pages are separate observations" ]
  | Detail_secrets | Detail_runs -> []

(* The single keys a binding's key names, in this table's own notation:
   alternatives apart with "/" ("d/m/s", "Left / Esc"), a key pressed twice
   apart with a space ("u u"), and a chord with "+" ("arrows+enter"). *)
let key_atoms key =
  String.split_on_char '/' key
  |> List.concat_map (String.split_on_char ' ')
  |> List.concat_map (String.split_on_char '+')
  |> List.filter (fun atom -> not (String.equal atom ""))
  |> List.sort_uniq String.compare

(* The keys a detail tab's own arms answer before the Keeper controls do.
   Sandbox takes [s] for the remote_ssh backend and [o] for its container
   logs; Channels takes [j/k] and [e/E]; Settings takes [e/E]. *)
let keeper_detail_tab_taken_keys tab =
  List.concat_map
    (fun binding -> key_atoms binding.key)
    (keeper_detail_tab_bindings tab)

(* The keys the detail footer leads with. Same [key:label] spelling as the
   rest of the row, and the tab switch leads because it is on every tab. *)
let keeper_detail_tab_hint ~ko tab =
  let named binding =
    if ko then key_hint ~label:binding.label_ko binding else key_hint binding
  in
  String.concat "  "
    (("[ ]:" ^ if ko then "탭" else "tab")
     :: List.map named (keeper_detail_tab_bindings tab))

(* A surface's rows on the sheet. The shared tail -- r, Tab and q exactly as
   [listing_meta] spells them -- is said once, under Global. Repeated under
   every surface it took three of the dozen rows an 80x24 sheet shows of the
   reader's own section. A surface that names one of those keys its own way
   ([r] reload on Config) keeps that row: it says something Global does not.
   Footers keep the tail, since a footer is all a surface shows. *)
let sheet_bindings surface =
  List.filter
    (fun binding -> not (List.mem binding listing_meta))
    (for_surface surface)

(* Additional reading keys stay on the sheet, each naming its owner. The
   volume binding is also used by its catalog and child footers. *)
let tools_detail_bindings =
  [ tools_volume_gc_binding
  ; b ~ko:"요청 / Skill 근거 읽기" Act "Enter" "read request / Skill evidence"
      ~help:"in async runs, read the selected original request; \
             otherwise load retained evidence for the selected Skill"
  ; b ~ko:"원본 작업" Navigate "t / T" "source Task"
      ~help:"from async request detail, read its original source Task and history"
  ; b ~ko:"이전 기록" Navigate "H" "earlier history"
      ~help:"from original Task detail, read earlier stored history; retains \
             the observed prefix on failure"
  ; b ~ko:"정확히 찾기" Act "o / O" "exact lookup"
      ~help:"in async runs, edit the original submitter, request ID and \
             target Keeper for an exact lookup"
  ]

let work_task_detail_bindings =
  [ b ~ko:"이전 기록" Navigate "H" "earlier history"
      ~help:"in Task detail, extend the observed history with its known \
             earlier page"
  ]

(* Each section with the surface it answers for; Global and the mark legends
   answer for none. The sheet reads the sections, the key reference reads the
   surface as well, for the paragraphs under a table. *)
let located_sections ~lang ?current () =
  let sections =
    List.map
      (fun (title, surface) ->
         (* The Keeper detail tabs each own keys the surface list cannot
            hold, and the sheet is where a reader looks for them. Append
            them under the surface with the tab named, so [?] answers
            "what does T do" -- which nothing did before 2026-08-30. *)
         let tab_entries =
           match surface with
           | Keepers Keeper_detail ->
               List.concat_map
                 (fun tab ->
                    List.map
                      (fun (key, help) ->
                         ( key
                         , Printf.sprintf "on the %s tab: %s"
                             (Masc_tui_types.keeper_detail_tab_label tab)
                             help ))
                      (entries ~lang (keeper_detail_tab_bindings tab)))
                 Masc_tui_types.keeper_detail_tabs
           (* The fact browser and the reading its Enter opens have the same
              problem the tabs above have: keys the surface list cannot hold,
              on screens the reader is standing on. The Memory section is
              where they look, so both rows go there with the screen named. *)
           | Memory ->
               List.map
                 (fun (key, help) -> (key, "in the facts browser: " ^ help))
                 (entries ~lang bindings_memory_facts)
               @ List.map (fun (key, help) -> (key, "in the changes browser: " ^ help))
                   (entries ~lang bindings_memory_changes)
               @ List.map
                   (fun (key, help) -> (key, "in the fact detail: " ^ help))
                   (entries ~lang bindings_memory_fact_detail)
           | Lanes ->
               List.map
                 (fun (key, help) -> (key, "in a lane's run list: " ^ help))
                 (entries ~lang (lane_run_list_bindings ~has_runs:true ~has_older:true))
               @ List.map
                   (fun (key, help) -> (key, "in a run's detail: " ^ help))
                   (entries ~lang lane_run_detail_bindings)
               @ entries ~lang [preflight_detail_binding]
           | Planning -> entries ~lang work_task_detail_bindings
           | Tools -> entries ~lang (tools_diagnostics_bindings @ tools_detail_bindings)
           | Keepers (Keeper_list | (Keeper_logs | (Keeper_calls | (Keeper_message | Keeper_runtime_pick))))
           | Overview | Acting | Metrics | Clients | Board | Approvals | Schedules
           | Verification | Harness | Fusion | Repositories | Code | Changes | Connectors | Runtime
           | Config | Resources | System_logs -> []
         in
         (surface, (title, entries ~lang (sheet_bindings surface) @ tab_entries)))
      help_surfaces
  in
  let here, rest =
    match current with
    | None -> ([], sections)
    | Some current ->
        List.partition (fun (surface, _) -> surface = current) sections
  in
  List.map (fun (surface, (title, keys)) -> (Some surface, (title ^ here_marker, keys))) here
  @ (None, ("Global", entries ~lang global))
    :: (List.map (fun (surface, section) -> (Some surface, section)) rest
        (* The marks last, as reference, the way the slash commands read as
           reference. One reader of them has no words beside it: the Keepers
           rows draw each glyph with its status word and so does the chat
           header, but the roster pane beside the chat is 34 cells wide and
           draws the glyph alone (masc_tui_render_prim.ml: "Without it the pane
           says a keeper exists and nothing else"). Selecting keepers until
           every state has been seen was the only way that reader could learn
           the marks, and a rare one such as failing may never be selected.

           Masc_tui_keeper_mark carried this list for exactly this and nothing
           read it. Its shape is already the sheet's: a mark, and what it
           means. Last rather than beside Global because the section order up
           to there is asserted. *)
        @ List.map (fun section -> (None, section))
        [ ("Keeper marks", Masc_tui_keeper_mark.legend)
          (* The Keepers header words and the Mode S letters. They were two
             rows above every roster: an empty roster spent them on columns
             it had nothing in, a narrow one on columns it did not draw, and
             beside the Activity pane both rows were cut. *)
          ; ("Keeper columns", Masc_tui_keeper_mark.column_legend)
          (* The Board's first column is the only place these three appear, and
             the column has no room for a legend of its own: its header already
             spends three rows and the hearth row is cut at 150 columns. *)
          (* The Memory roster's ST column. The words were a literal row the
             surface drew above every roster -- including a roster that had
             failed to read, where the column it explained was not on screen.
             Same move as the Keeper columns above: the row goes, the sheet
             keeps the words, and the glyphs now come from the function the
             column draws with. *)
          ; ("Memory marks", Masc_tui_memory_mark.legend)
          ; ("Board marks", Masc_tui_board_kind_mark.legend)
          (* The Code tree's file marks. A folder takes the arrow and a file
             takes its kind's mark, and neither carries a word -- the name
             beside it says the extension the mark was read from, not what the
             mark means. Seven marks drew with nothing anywhere saying so. *)
          ; ("File marks", Masc_tui_file_icon.legend)
          (* Planning's own legend says the marks its list is drawing, which
             is what keeps that line inside a narrow frame -- so a mark no
             goal carries right now has nowhere else to be explained. Here. *)
          ; ("Judge marks", Masc_tui_planning_proof_mark.legend)
          (* The marks and phrases on a chat's tool and skill rows. Six
             outcome marks, eight skill phrases and two words of proof sat on
             every transcript with nothing anywhere saying what one meant;
             an operator reading them asked what "받아서 씀" received and
             wrote (2026-09-14). *)
          ; ("Chat marks", Masc_tui_keeper_chat_transcript.legend)
          (* The first column of Config's two list panes. The prompt registry
             draws three marks and the params list two, and the words for
             them were only in the detail pane below the list -- for the one
             row the cursor was on. A reader scanning twenty rows could tell
             a marked row from an unmarked one and not what the mark said. *)
          ; ("Prompt marks", Masc_tui_config_mark.prompt_legend)
          ; ("Param marks", Masc_tui_config_mark.param_legend)
          ])

let help_sections ~lang ?current () = List.map snd (located_sections ~lang ?current ())

type reference_section = {
  section_title : string;
  section_rows : (string * string) list;
  section_notes : string list;
}

(* The sheet's sections in the sheet's order, each with the paragraphs
   [reference_notes] keeps for its surface. The rows are the sheet's rows, so
   the document and [?] cannot list different keys. *)
let reference_sections () =
  List.map
    (fun (surface, (section_title, section_rows)) ->
       let section_notes =
         match surface with
         | Some surface -> reference_notes surface
         | None -> []
       in
       { section_title; section_rows; section_notes })
    (located_sections ~lang:Lang_en ())

let workspace_activity_bindings ~context =
  [ (if context then b ~ko:"스크롤" Navigate "j/k" "scroll"
     else b ~ko:"선택" Navigate "j/k" "select")
  ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
  ; b ~ko:"파일" Act "Enter / Right" "file" ~help:"open the selected recorded file in Code"
  ; b ~ko:"새로 조회" Act "r / R" "refresh"
  ; (if context then b ~ko:"목록" Navigate "Esc / Left" "list"
     else b ~ko:"저장소" Navigate "Esc / Left" "repositories")
  ; b ~ko:"도움말" Navigate "?" "help"
  ] @ (if context then [b ~ko:"처음/끝" Navigate "Home/End / g/G" "edges"]
       else [b ~ko:"맥락" Navigate "v / V" "context" ~help:"read the selected record's full path, Task and execution metadata"])

let exact_activity_bindings =
  [ b ~ko:"활동 초안 바꾸기" Act "Space" "change activity draft" ~help:"preserve configuration; no write until s"
  ; b ~ko:"저장" Act "s" "save" ~help:"preview and save against the original file revision"
  ; b ~ko:"지금 파일 읽기" Act "r" "read current" ~help:"keep edits; otherwise follow current file"
  ; b ~ko:"활동 다시 적용" Act "u" "reapply activity" ~help:"keep only the desired on/off change over the current file; s then saves"
  ; b ~ko:"초안 버리기" Act "x" "discard draft" ~help:"use the displayed current file; no write"
  ; b ~ko:"스크롤" Navigate "j/k" "scroll"
  ; b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
  ; b ~ko:"처음/끝" Navigate "Home/End" "top/bottom"
  ; b ~ko:"뒤로" Navigate "Esc / q" "back" ~help:"retain the activity draft for this workspace and lane"
  ]

let about_bindings =
  [ b ~ko:"Candle" Act "c" "candle"
  ; b ~ko:"닫기" Meta "Esc" "close"
  ; b ~ko:"도움말" Meta "?" "help" ]

let context_bindings ~cols (state : state) =
  let module Inspector = Masc_tui_context_inspector in
  let split = cols >= Masc_tui_roster_pane.threshold_cols in
  let tabs = [b ~ko:"전환" Navigate "1/2/3/4 or Tab" "switch"] in
  let turns = match state.context_inspector_target with
    | Inspector.Recent _ -> [b ~ko:"턴" Navigate "[ / ]" "turn"]
    | Inspector.Pinned _ -> [] in
  let refresh = [b ~ko:"새로 조회" Meta "r" "refresh"] in
  let help = [b ~ko:"도움말" Meta "?" "help"] in
  let scroll = b ~ko:"스크롤" Navigate "j/k" "scroll" in
  let close = b ~ko:"닫기" Meta "Esc" "close" in
  let scroll_plain_body = match state.context_inspector_reading with
    | Some (_, reading) ->
        Inspector.scroll_plain_body ~tab:state.context_inspector_tab
          ~target:state.context_inspector_target reading
    | None -> false in
  if Option.is_some state.search then
    [ b ~ko:"검색어" Search "type" "query"
    ; b ~ko:"검색 유지" Act "Enter" "keep search"
    ; b ~ko:"검색 취소" Meta "Esc" "cancel search" ]
  else match state.context_inspector_tab, state.context_inspector_exact with
  | Inspector.Response, _ ->
      tabs @ turns @ [scroll; b ~ko:"페이지" Navigate "PgUp/PgDn" "page";
        b ~ko:"처음/끝" Navigate "Home/End" "top/bottom"] @ refresh
      @ [b ~ko:"돌아가기" Meta "Esc" "return"] @ help
  | (Inspector.Composition | Inspector.Exact_input | Inspector.Input_map), Some _ ->
      [b ~ko:"응답" Navigate "4" "response"; scroll; b ~ko:"목록" Meta "Esc" "list"] @ help
  | (Inspector.Exact_input | Inspector.Input_map), None when scroll_plain_body ->
      tabs @ turns @ [scroll] @ refresh @ [close] @ help
  | (Inspector.Exact_input | Inspector.Input_map), None ->
      tabs @ turns
      @ (if state.context_inspector_tab = Inspector.Exact_input
            && Option.is_some state.context_inspector_reading
         then [b ~ko:"찾기" Search "/" "search"] else [])
      @ [ if split then b ~ko:"선택 / 스크롤" Navigate "j/k" "select or scroll"
          else b ~ko:"선택" Navigate "j/k" "select" ]
      @ (if split then [b ~ko:"창" Navigate "h/l" "pane"] else [])
      @ [b ~ko:"원문 열기" Act "Enter" "open exact"] @ refresh @ [close] @ help
  | Inspector.Composition, None ->
      tabs @ turns @ [scroll] @ refresh @ [close] @ help

let footer_hints_about ~lang = hints_of_bindings ~lang about_bindings
let footer_hints_context ~cols (state : state) =
  hints_of_bindings ~lang:state.ui_language (context_bindings ~cols state)

let queue_bindings state panel =
  let help = b ~ko:"도움말" Meta "?" "help" in
  let page = b ~ko:"페이지" Navigate "PgUp/PgDn" "page" in
  let edges = b ~ko:"처음/끝" Navigate "Home/End" "edges" in
  let close = [b ~ko:"뒤로" Meta "Esc" "back"; help] in
  if Option.is_some panel.qp_detail then
    [b ~ko:"스크롤" Navigate "j/k" "scroll"; page; edges;
     b ~ko:"목록" Meta "Enter / Esc" "list"; help]
  else
    let actions =
      if panel.qp_reading <> Queue_current || not (server_authority_ready state) then []
      else match queue_panel_priority state ~items:(queue_panel_items state panel) panel with
        | Queue_local_order ->
            [ b ~ko:"여기서만 맨 앞" Act "n" "first locally"
            ; b ~ko:"여기서만 맨 뒤" Act "l" "last locally" ]
        | Queue_server_order ->
            [b ~ko:"다음에 실행" Act "n" "run next"; b ~ko:"맨 뒤로" Act "l" "move last"]
        | Queue_event_urgency ->
            [ b ~ko:"최우선" Act "n" "immediate priority"
            ; b ~ko:"낮은 순위" Act "l" "low priority" ]
        | Queue_no_priority -> [] in
    actions
    @ [b ~ko:"선택" Navigate "↑/↓ / j/k" "select"; b ~ko:"읽기" Navigate "Enter" "read"]
    @ [ (match panel.qp_layout with
         | Masc_tui_queue_layout.Adaptive -> b ~ko:"전체 먼저" Navigate "f" "prefer full"
         | Expanded -> b ~ko:"맥락 함께" Navigate "f" "allow context")
      ; page; edges; b ~ko:"새로 조회" Act "r" "refresh" ] @ close

(* The selected action has higher priority than generic movement. The shared
   default group sort would put every navigation key ahead of it and cause
   next/last to disappear first as the footer gives up its tail. *)
let footer_hints_queue (state : state) panel =
  hints_in_order ~lang:state.ui_language (queue_bindings state panel)

let help_sections_for_state ~cols (state : state) =
  let lang = state.ui_language in
  let active =
    if state.about_open then Some ("About", about_bindings)
    else if state.context_inspector_open then Some ("Context", context_bindings ~cols state)
    else if Option.is_some state.queue_panel then
      Option.map (fun panel -> "Queue", queue_bindings state panel) state.queue_panel
    else if state.patch_modal_open then Some ("Patch review", patch_review_bindings)
    else if state.view = Lanes && Option.is_some state.exact_activity_open then
      Some ("Exact activity", exact_activity_bindings)
    else if state.view = Lanes && Option.is_some state.machine_activity_open then
      Some ("Machine activity", exact_activity_bindings)
    else if Option.is_some state.voice_agent_voices then
      let bindings =
        match state.voice_agent_voices with
        | Some session -> voice_agent_bindings_for_saving session.vas_saving
        | None -> voice_agent_bindings
      in
      Some ("Keeper voices", bindings)
    else if state.view = Runtime && Option.is_some state.runtime_detail_target then
      let routes = state.runtime_detail_target = Some Runtime_routes in
      Some ("Runtime detail", runtime_detail_bindings_for ~routes)
    else if state.view = Runtime && Option.is_some (runtime_parent state) then
      Option.map (fun parent ->
        "Runtime editor", runtime_parent_bindings parent)
        (runtime_parent state)
    else if state.view = Acting && Option.is_some state.acting_detail then
      Some ("Event evidence", bindings_acting_evidence)
    else if state.view = Code && state.code_focus_file = Right_pane
            && state.code_history_open && not state.repository_changes_open then
      Some ("Code history", code_history_bindings)
    else if state.view = Code && state.code_focus_file = Right_pane
            && state.code_notes_open && not state.repository_changes_open then
      Some ("Code memos", code_notes_bindings)
    else if state.view = Repositories && not state.repository_changes_open
            && Option.is_some state.workspace_activity_repo then
      let context = Option.is_some state.workspace_activity_context_scroll in
      Some ((if context then "Activity context" else "Workspace Activity"),
            workspace_activity_bindings ~context)
    else if state.view = Lanes then
      (match state.lanes_mode with
       | Lanes_run_list _ ->
           Some
             ( "Lane runs",
               lane_run_list_bindings
                 ~has_runs:
                   (match state.lane_runs with
                    | Some (_ :: _) -> true
                    | Some [] | None -> false)
                 ~has_older:(Option.is_some state.lane_runs_next) )
       | Lanes_run_detail (_, _) ->
           Some ("Lane run", lane_run_detail_bindings @ [preflight_detail_binding])
       | Lanes_overview | Lanes_measurement_detail _ | Lanes_inventory_detail _ -> None)
    else None
  in
  match active with
  | None -> help_sections ~lang ~current:state.view ()
  | Some (title, bindings) ->
      (title ^ here_marker, entries ~lang bindings) :: help_sections ~lang ()

let footer_hints_browser_lane ~lang =
  hints_of_bindings ~lang
    [ b ~ko:"브라우저 고르기" Navigate "b" "choose browser"
    ; b ~ko:"고급 브라우저" Navigate "A" "advanced browsers"
    ; b ~ko:"탭" Navigate "[ / ]" "tab"
    ; b ~ko:"본문" Navigate "j/k" "text"
    ; b ~ko:"화면 캡처" Act "Ctrl-O" "screenshot"
    ; b ~ko:"새로 조회" Act "r" "refresh"
    ; b ~ko:"레인 숨기기" Navigate "Ctrl-^ / Esc" "hide lane"
    ]

(* The rows the renderers used to spell by hand, each a string in English
   only. They are bindings like every other row now, so each key has both
   names. The order is the one the string had: these rows are short and lead
   with what the reader does first, so the group sort is not applied. *)
let scroll_binding = b ~ko:"스크롤" Navigate "j/k" "scroll"
let page_binding = b ~ko:"페이지" Navigate "PgUp/PgDn" "page"
let close_binding = b ~ko:"닫기" Act "Esc" "close"

let footer_hints_browser_lane_reading ~lang =
  footer_hints_browser_lane ~lang ^ "  "
  ^ hints_in_order ~lang
      [ b ~ko:"장면" Navigate "s" "scene"
      ; b ~ko:"영역" Navigate "v" "regions"
      ; b ~ko:"관측" Navigate "h" "observations"
      ]

let footer_hints_browser_picker ~lang =
  hints_in_order ~lang
    [ b ~ko:"고르기" Navigate "\xe2\x86\x91/\xe2\x86\x93" "choose"
    ; b ~ko:"이 브라우저 쓰기" Act "Enter" "use browser"
    ; b ~ko:"연결 다시 읽기" Act "r" "reload connections"
    ; b ~ko:"고급" Navigate "A" "advanced"
    ; b ~ko:"취소" Act "Esc" "cancel"
    ]

let browser_choose = b ~ko:"브라우저 고르기" Navigate "b" "choose browser"
let browser_main = b ~ko:"본문으로" Navigate "m" "main"
let browser_page_scroll = b ~ko:"페이지 스크롤" Navigate "J/K" "page scroll"
let browser_observations = b ~ko:"관측" Navigate "h" "observations"
let browser_image = b ~ko:"그림" Act "Ctrl-O" "image"

(* [enter] is what Enter does to the element under the cursor, and is absent
   where the cursor is on nothing that takes it. *)
let footer_hints_browser_scene ~lang ~(enter : Browser_lane_view.scene_action option) ~articles =
  hints_in_order ~lang
    ([ browser_choose ]
     @ (match enter with
        | Some Browser_lane_view.Read_region -> [ b ~ko:"영역 읽기" Act "Enter" "read region" ]
        | Some Browser_lane_view.Follow_link -> [ b ~ko:"링크 따라가기" Act "Enter" "follow link" ]
        | Some Browser_lane_view.Click_control -> [ b ~ko:"누르기" Act "Enter" "click" ]
        | None -> [])
     @ [ browser_main
       ; browser_page_scroll
       ; b ~ko:"동작" Navigate "Tab/Shift-Tab" "action"
       ]
     @ (if articles then [ b ~ko:"글" Navigate "N/P" "article" ] else [])
     @ [ b ~ko:"요소" Navigate "n/p" "element"
       ; b ~ko:"영역" Navigate "v" "regions"
       ; b ~ko:"본문" Navigate "s" "text"
       ; b ~ko:"복사" Act "y" "copy"
       ; browser_observations
       ; browser_image
       ])

let footer_hints_browser_scene_guard ~lang =
  hints_in_order ~lang
    [ browser_choose
    ; browser_main
    ; browser_page_scroll
    ; b ~ko:"따라간 곳 다시 확인" Act "r" "recheck followed destination"
    ; b ~ko:"본문 다시 확인" Act "s" "recheck text"
    ; browser_observations
    ; browser_image
    ]

let footer_hints_browser_observations ~lang =
  hints_in_order ~lang
    [ b ~ko:"관측" Navigate "[/]" "observation"
    ; scroll_binding
    ; b ~ko:"기록 복사" Act "y" "copy record"
    ; b ~ko:"목록 다시 읽기" Act "r" "reload list"
    ; b ~ko:"작업 공간 다시 확인" Act "R" "recheck workspace"
    ; b ~ko:"브라우저로" Navigate "h/Esc" "back to browser"
    ]

let footer_hints_client_detail ~lang =
  hints_in_order ~lang
    [ scroll_binding
    ; page_binding
    ; b ~ko:"처음/끝" Navigate "g/G" "first/last"
    ; b ~ko:"클라이언트" Navigate "Esc" "clients"
    ]

let footer_hints_lane_activity ~lang =
  hints_in_order ~lang
    [ b ~ko:"초안" Act "Space" "draft"
    ; b ~ko:"저장" Act "s" "save"
    ; b ~ko:"읽기" Act "r" "read"
    ; b ~ko:"다시 적용" Act "u" "reapply"
    ; b ~ko:"버리기" Act "x" "discard"
    ; b ~ko:"도움말" Meta "?" "help"
    ; b ~ko:"뒤로" Navigate "Esc" "back"
    ]

(* The model order editor of one exact-output Lane. The Lanes list's own
   keys do not act while it is open, so the footer names the editor's. *)
let footer_hints_exact_model_order ~lang =
  hints_in_order ~lang
    [ b ~ko:"교체" Act "r" "replace"
    ; b ~ko:"후보 추가" Act "a" "add fallback"
    ; b ~ko:"빼기" Act "x" "remove"
    ; b ~ko:"순서" Act "J/K" "reorder"
    ; b ~ko:"그룹 맨 앞" Act "1" "first in group"
    ; b ~ko:"설정" Navigate "Enter/d" "settings"
    ; b ~ko:"TOML" Navigate "e" "TOML"
    ; b ~ko:"선택" Navigate "j/k" "select"
    ; b ~ko:"도움말" Meta "?" "help"
    ; b ~ko:"뒤로" Navigate "Esc" "back"
    ]

let footer_hints_lane_inventory_detail ~lang =
  hints_in_order ~lang
    [ scroll_binding
    ; page_binding
    ; b ~ko:"처음/끝" Navigate "Home/End" "top/bottom"
    ; b ~ko:"새로 조회" Meta "r" "refresh"
    ; b ~ko:"목록" Navigate "Esc/Left" "inventory"
    ]

let footer_hints_link_preview_empty ~lang = hints_in_order ~lang [ close_binding ]

let footer_hints_play_invite ~lang =
  hints_in_order ~lang
    [ scroll_binding; b ~ko:"링크 복사" Act "y" "copy link"; close_binding ]

let footer_hints_answering ~lang =
  hints_in_order ~lang
    [ b ~ko:"선택" Navigate "j/k" "move"
    ; page_binding
    ; b ~ko:"처음/끝" Navigate "Home/End" "edges"
    ; b ~ko:"채팅" Act "Enter" "chat"
    ; close_binding
    ]

let footer_hints_changes_diff ~lang =
  hints_in_order ~lang
    [ b ~ko:"좌우 이동" Navigate "Shift-Left / Shift-Right" "pan"
    ; scroll_binding
    ; b ~ko:"뒤로" Act "Left / Esc" "back"
    ; b ~ko:"편집기에서 열기" Act "o" "open in editor"
    ; listing_quit
    ]

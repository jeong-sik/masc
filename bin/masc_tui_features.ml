(* The feature sheet's rows: what this TUI can do, one sentence each, with
   the door spelled the way you type it. [/features] draws this list; [?]
   answers "what does this key do here", and this answers "what is there to
   do at all" -- the question a fresh operator or a fresh Keeper has before
   any footer can help them.

   Every opener is checked against the machine that would answer it
   (test_tui_features): commands against the parser's spellings, keys against
   the key table's global row and its exported key constants, surfaces
   against the help sheet's own section list. A row without a real door is a
   build failure, and so is a door renamed under a sheet still advertising
   the old spelling. *)

type opener =
  | Command of string  (** the word after the slash; checked against the parser *)
  | Key of string  (** a key as the table spells it *)
  | Surface of string  (** a route, named the way the help sheet names it *)
  | Token of string  (** a wire name or a code-block fence, proven outside the TUI *)

type row = {
  opener : opener;
  description : string;  (** one sentence; long enough rows wrap, never cut *)
}

let opener_text = function
  | Command word -> "/" ^ word
  | Key key -> key
  | Surface route -> route
  | Token token -> token

(* Short openers share a sentence column. Longer paths retain two spaces
   and use their actual cell width for wrapping and continuation rows. *)
let opener_cells = 14

let sections =
  [ ( "Get anywhere"
    , [ { opener = Key ":"; description = "command palette: jump anywhere by name" }
      ; { opener = Key ";"
        ; description = "agenda: what is coming, who is waiting on you" }
      ; { opener = Key "@"
        ; description = "answering: who is mid-turn or just finished" }
      ; { opener = Key "Ctrl-L"
        ; description = "Activity pane: what every keeper is doing now" }
      ; { opener = Command "keeper"
        ; description = "switch this pane to another keeper: /keeper <name>" }
      ; { opener = Key "&"
        ; description = "Collab: watch MSX/DOS, manage play links" }
      ; { opener = Surface "Operations"
        ; description = "decisions and remembered conversations; Enter opens the selected destination" }
      ; { opener = Surface "Work"
        ; description = "Goals, Tasks and evidence; t switches lists, Enter reads details" }
      ; { opener = Surface "Keepers"
        ; description = "conversations, settings and history; c opens chat, l opens logs" }
      ; { opener = Surface "Operations / Usage"
        ; description = "f selects an account, v cycles Plan/Trend/Keepers/Calls, a restores all accounts" }
      ; { opener = Surface "Work / Board"
        ; description = "Enter reads a discussion; S follows its recorded successor, Esc returns" }
      ; { opener = Surface "Workspace"
        ; description = "Enter browses files; Ctrl-P in Code finds checkout files; v reads selected repository context" }
      ; { opener = Surface "Features & plugins"
        ; description = "observed capabilities and plugin workers; Enter reads evidence, d opens full details" }
      ; { opener = Surface "System"
        ; description = "p cycles settings panes; on Models, v reads complete account/model details" }
      ] )
  ; ( "Steer a turn"
    , [ { opener = Command "steer"
        ; description = "type over a running turn: /steer <message>" }
      ; { opener = Command "interrupt"
        ; description = "stop a streaming turn: /interrupt [keeper]" }
      ; { opener = Command "run-next"
        ; description = "promote your queued message and resume" }
      ; { opener = Command "priority"
        ; description = "auto-promote typed input: /priority on|off" }
      ; { opener = Command "queue"
        ; description = "inspect and manage waiting messages" }
      ; { opener = Command "find"
        ; description = "jump to the newest message holding text" }
      ; { opener = Command "copy"
        ; description = "latest completed reply to the clipboard" }
      ] )
  ; ( "See what happened"
    , [ { opener = Command "artifacts"
        ; description = "Markdown/HTML reports: f selects format, t filters today, Enter reads full width; {/} selects revisions" }
      ; { opener = Command "context"
        ; description = "inspect the last observed provider input" }
      ; { opener = Key "Ctrl-X"
        ; description = "context inspector over this chat's last turn" }
      ; { opener = Command "measurement"
        ; description = "read a published measurement: /measurement <sha256>" }
      ; { opener = Command "errors"
        ; description = "this chat's loading failures, in a scrollable log" }
      ; { opener = Command "diff"; description = "Git working-tree changes and diff" }
      ] )
  ; ( "Bring media in"
    , [ { opener = Command "image"
        ; description = "draw an image file on the terminal: /image <path>" }
      ; { opener = Command "images"
        ; description = "open a conversation image or diagram, newest first: /images [N]; Ctrl-O previews the newest" }
      ; { opener = Command "attach"
        ; description = "stage an image for the next message: /attach <path>" }
      ; { opener = Command "ref"
        ; description = "stage an image reference: /ref <url|file_id>" }
      ; { opener = Command "listen"
        ; description = "play the newest audio or MIDI attachment" }
      ; { opener = Command "embeds"
        ; description = "inline rich embed cards: /embeds on|compact|off" }
      ] )
  ; ( "Draw and call"
    , [ (* Both fences draw in the chat's code-block reader
           (bin/masc_tui_mermaid_grammar.ml, bin/masc_tui_alphatex.ml; the
           alphatex drawing and highlighting shipped as #42777 and #42779,
           both marked Experimental in CHANGELOG.md). *)
        { opener = Token "```mermaid"
        ; description = "this code block draws as a diagram" }
      ; { opener = Token "```alphatex"
        ; description = "guitar tablature from a code block (Experimental)" }
      ; { opener = Command "score"
        ; description = "full alphaTex notation and playback in this terminal: /score [N]" }
      ; { opener = Command "music"
        ; description = "phrases, arrangements and takes: /music or Dashboard s; plain terminal supported" }
      ; (* The in-tool help surface the tool schema descriptions point at:
           lib/tool_surface/tool_help_registry.ml registers it by this name. *)
        { opener = Token "masc_tool_help"
        ; description = "ask how and when to use any tool" }
      ; (* config/tools/masc_wiki_lint.toml names the tool; its description's
           first word is the Experimental mark. *)
        { opener = Token "masc_wiki_lint"
        ; description = "check the wiki, write nothing (Experimental)" }
      ; { opener = Surface "Features & plugins / Tools"
        ; description = "the tool catalog, receipts and usage" }
      ; { opener = Command "addons"
        ; description = "cross-lane observations and packaging: /addons" }
      ; { opener = Command "play"
        ; description = "shared DOS play links and QR invites: /play invites" }
      ] )
  ]

let sections_ko =
  [ ( "어디서나 이동"
    , [ { opener = Key ":"; description = "명령 팔레트: 이름으로 화면·동작 바로 이동" }
      ; { opener = Key ";"
        ; description = "일정·대기 요약: 예정 일정과 확인이 필요한 항목 보기" }
      ; { opener = Key "@"
        ; description = "응답 현황: 지금 턴을 돌거나 방금 끝낸 키퍼 보기" }
      ; { opener = Key "Ctrl-L"
        ; description = "활동 창: 모든 키퍼가 지금 하는 일 한눈에 보기" }
      ; { opener = Command "keeper"
        ; description = "대화 창을 다른 키퍼로 전환: /keeper <이름>" }
      ; { opener = Key "&"
        ; description = "협업: MSX/DOS 관전 및 플레이 초대 링크 관리" }
      ; { opener = Surface "Operations"
        ; description = "결정 사항과 기억된 대화 요약 · Enter로 선택한 대상 열기" }
      ; { opener = Surface "Work"
        ; description = "목표, 태스크, 검증 증거 · t로 목록 전환, Enter로 상세 보기" }
      ; { opener = Surface "Keepers"
        ; description = "대화, 설정, 이력 · c로 채팅 열기, l로 로그 보기" }
      ; { opener = Surface "Operations / Usage"
        ; description = "f로 계정 선택, v로 요금제/추이/키퍼/호출 전환, a로 전체 계정 복원" }
      ; { opener = Surface "Work / Board"
        ; description = "Enter로 게시글 읽기 · S로 후속 글 이동, Esc로 돌아가기" }
      ; { opener = Surface "Workspace"
        ; description = "Enter로 파일 탐색 · 코드 화면 Ctrl-P로 파일 검색, v로 저장소 상세 보기" }
      ; { opener = Surface "Features & plugins"
        ; description = "관측된 기능과 플러그인 워커 · Enter로 증거 읽기, d로 전체 상세 보기" }
      ; { opener = Surface "System"
        ; description = "p로 설정 탭 순환 · 모델 탭에서 v로 계정·모델 전체 상세 보기" }
      ] )
  ; ( "턴 제어"
    , [ { opener = Command "steer"
        ; description = "실행 중인 턴에 방향 지시 입력: /steer <메시지>" }
      ; { opener = Command "interrupt"
        ; description = "스트리밍 중인 턴 중단: /interrupt [키퍼]" }
      ; { opener = Command "run-next"
        ; description = "대기열 메시지를 다음 순서로 올리고 재개" }
      ; { opener = Command "priority"
        ; description = "입력한 메시지 자동 우선 실행 전환: /priority on|off" }
      ; { opener = Command "queue"
        ; description = "대기 중인 메시지 확인 및 관리" }
      ; { opener = Command "find"
        ; description = "텍스트가 포함된 가장 최근 메시지로 이동" }
      ; { opener = Command "copy"
        ; description = "가장 최근 완료된 응답을 클립보드에 복사" }
      ] )
  ; ( "기록·결과 확인"
    , [ { opener = Command "artifacts"
        ; description = "Markdown/HTML 보고서 · f로 형식 선택, t로 오늘 필터, Enter로 전체 읽기, {/}로 리비전 이동" }
      ; { opener = Command "context"
        ; description = "마지막으로 관측된 모델 입력 맥락 검사" }
      ; { opener = Key "Ctrl-X"
        ; description = "현재 대화의 마지막 턴 맥락 검사기 열기" }
      ; { opener = Command "measurement"
        ; description = "게시된 측정 기록 읽기: /measurement <sha256>" }
      ; { opener = Command "errors"
        ; description = "이 대화의 로딩 실패 기록을 스크롤 목록으로 보기" }
      ; { opener = Command "diff"; description = "Git 작업 트리 변경 사항 및 diff 보기" }
      ] )
  ; ( "미디어 가져오기"
    , [ { opener = Command "image"
        ; description = "터미널에 이미지 파일 그리기: /image <경로>" }
      ; { opener = Command "images"
        ; description = "대화 속 이미지·다이어그램 최신순 열기: /images [N] · Ctrl-O로 최신 항목 미리보기" }
      ; { opener = Command "attach"
        ; description = "다음 메시지에 보낼 이미지 첨부: /attach <경로>" }
      ; { opener = Command "ref"
        ; description = "이미지 참조 첨부: /ref <url|file_id>" }
      ; { opener = Command "listen"
        ; description = "가장 최근 오디오 또는 MIDI 첨부 재생" }
      ; { opener = Command "embeds"
        ; description = "인라인 리치 임베드 카드 설정: /embeds on|compact|off" }
      ] )
  ; ( "그리기·도구 호출"
    , [ { opener = Token "```mermaid"
        ; description = "코드 블록을 다이어그램으로 렌더링" }
      ; { opener = Token "```alphatex"
        ; description = "코드 블록으로 기타 타브 악보 그리기 (실험 기능)" }
      ; { opener = Command "score"
        ; description = "이 터미널에서 alphaTex 악보 보기 및 재생: /score [N]" }
      ; { opener = Command "music"
        ; description = "프레이즈, 편곡, 테이크 작업: /music 또는 대시보드 s · 일반 터미널 지원" }
      ; { opener = Token "masc_tool_help"
        ; description = "모든 도구의 사용법과 호출 시점 조회" }
      ; { opener = Token "masc_wiki_lint"
        ; description = "위키 문서 점검 · 쓰기 없음 (실험 기능)" }
      ; { opener = Surface "Features & plugins / Tools"
        ; description = "도구 카탈로그, 실행 영수증, 사용 현황" }
      ; { opener = Command "addons"
        ; description = "레인 간 관측 및 패키지 관리: /addons" }
      ; { opener = Command "play"
        ; description = "공유 DOS 플레이 링크 및 QR 초대: /play invites" }
      ] )
  ]

let all_rows = List.concat_map snd sections

let lines_for ~ko ~width =
  (* The rows draw plain, deliberately: [/features] answers as a chat notice,
     and a notice passes through [Keeper_chat.terminal_safe_text], which turns
     every control byte -- ESC with them -- into text the operator reads. A
     dimmed heading shipped as a visible "[2m"; the hierarchy lives in the
     diamond and the column instead of in colour, the way the [/help]
     catalog's plain rows do. *)
  (* The item marker also keeps a fence name at the start of a row from
     opening a Markdown block when this sheet is placed in a chat notice. *)
  let prefix = "  \xe2\x80\xa2 " in
  let row_lines row =
    let opener = opener_text row.opener in
    let pad =
      max 2 (opener_cells - Masc_tui_message_layout.display_width opener)
    in
    let lead = prefix ^ opener ^ String.make pad ' ' in
    let column = Masc_tui_message_layout.display_width lead in
    match
      Masc_tui_message_layout.wrap_words
        ~max_cells:(max 1 (width - column))
        row.description
    with
    | [] -> []
    | first :: rest ->
      (lead ^ first)
      :: List.map (fun piece -> String.make column ' ' ^ piece) rest
  in
  let section_lines (title, rows) =
    ("\xe2\x97\x86 " ^ title)
    :: List.concat_map row_lines rows
    @ [ "" ]
  in
  List.concat_map section_lines (if ko then sections_ko else sections)

let lines ~width = lines_for ~ko:false ~width

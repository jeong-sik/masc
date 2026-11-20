type t =
  | Say of string
  | Task_for_keeper of {
      title : string;
      body : string;
    }
  | Task_recover
  | Task_inspect
  | Task_missing_title
  | Help
  | Features
  | Show_load_errors
  | About
  | Lane_addons of string
  | Play_invites
  | Play_link of string option
  | Play_invite of { name : string; hours : int }
  | Play_revoke of string
  | Play_invalid of string
  | Open_score of int
  | Score_invalid_index
  | Open_images of int
  | List_images
  | Images_invalid_index
  | Open_artifacts
  | Open_music
  | Open_music_midi
  | Music_invalid_arguments
  | Listen
  | Open_metrics
  | Account_login of string
  | Open_settings
  | Open_diff
  | Open_usage
  | Open_link_preview of string option
  | Open_links_list
  | Copy_latest_reply
  | Set_embeds of [ `On | `Compact | `Off ]
  | Open_changes
  | Toggle_acting_pane
  | Show_acting_pane_tab of [ `Fleet | `Changes ]
  | Acting_pane_tab_unknown of string
  | Set_acting_pane_call_order of [ `Next | `Newest | `Oldest | `Longest | `By_tool ]
  | Acting_pane_call_order_unknown of string
  | Scroll_acting_pane of [ `Up | `Down | `Top | `By of int ]
  | Acting_pane_scroll_unknown of string
  | Switch_keeper of string
  | Switch_keeper_missing_name
  | Queue of string
  | Run_next
  | Reconcile_held
  | Priority of string option
  | Answer_tool_approval of bool
  | Interrupt_turn
  | Interrupt_keeper_turn of string
  | Steer_turn of string
  | Steer_missing_message
  | Set_thinking of [ `Cycle | `Hidden | `Folded | `Full ]
  | Open_calls
  | Set_tools of [ `Toggle | `Compact | `Results | `Full ]
  | Cycle_memory
  | Memory_status
  | Open_fleet_memory
  | Find_in_chat of string
  | Find_next
  | Open_measurement of string
  | Measurement_missing_sha
  | Inspect_context
  | View_image of string
  | View_image_missing_path
  | Attach_image of string
  | Attach_image_missing_path
  | Attach_image_ref of string
  | Attach_image_ref_missing_value
  | Preset_list
  | Preset_save of {
      name : string;
      description : string;
    }
  | Preset_save_missing_name
  | Preset_restore of string
  | Preset_restore_missing_name
  | Preset_show of string
  | Preset_show_missing_name
  | Preset_delete of string
  | Preset_delete_missing_name
  | Unknown of string

(* One list, drawn by /help and kept beside the parser so a new command
   cannot ship without its line. *)
type command_help = {
  word : string;
  aliases : string list;
  args : string;
  summary : string;
}

(* Named because its forms are printed in two more places than the catalog:
   the /queue usage error and the foot of the queue snapshot. Both read this
   entry, so a form added here is the form they show. *)
let queue_help =
  { word = "queue"
  ; aliases = []
  ; args = "[pause|resume|clear|cancel ID|last ID|edit ID message]"
  ; summary = "open the queue panel or manage waiting work"
  }

(* Every slash word this build knows, said once. [help_lines] and the
   composer hint are both drawn from here: a command described in two places
   is a command that will be described two ways, and the one an operator
   reads first is whichever list nobody updated. *)
let catalog =
  [ { word = "login"; aliases = []; args = "[client]"; summary = "sign in to an official client and verify a model connection" }
  ; { word = "task-inspect"; aliases = []; args = "";
      summary = "inspect this session's Task creations without repeating them" }
  ; { word = "task-recover"
    ; aliases = []
    ; args = ""
    ; summary = "restore a retained Task command for this Keeper; inspect Tasks before repeating an unconfirmed creation"
    }
  ; { word = "task"
    ; aliases = []
    ; args = "<title>"
    ; summary = "create a task for this keeper (lines below become the body)"
    }
  ; { word = "keeper"
    ; aliases = []
    ; args = "<name>"
    ; summary = "switch this pane to another keeper"
    }
  ; { word = "addons"
    ; aliases = []
    ; args = "[inspect|attach JSON|observe ID|detach ID|slice JSON|evidence JSON]"
    ; summary = "open optional cross-lane observations and package actions"
    }
  ; { word = "play"
    ; aliases = []
    ; args = "[invites|invite <name> <hours>|link [name]|revoke <name>]"
    ; summary = "list, issue or revoke shared DOS play links"
    }
  ; { word = "listen"
    ; aliases = []
    ; args = ""
    ; summary = "play the newest audio or MIDI attachment in this conversation"
    }
  ; { word = "artifacts"
    ; aliases = [ "reports" ]
    ; args = ""
    ; summary = "browse published Markdown and HTML reports in a full-width reader"
    }
  ; { word = "settings"
    ; aliases = []
    ; args = ""
    ; summary = "open type-aware runtime settings"
    }
  ; { word = "diff"
    ; aliases = []
    ; args = ""
    ; summary = "open git changes and diff for the workspace"
    }
  ; { word = "cost"
    ; aliases = []
    ; args = ""
    ; summary = "open Usage for provider quotas and Keeper usage"
    }
  ; { word = "changes"
    ; aliases = []
    ; args = ""
    ; summary = "open recorded file changes for this keeper"
    }
  ; queue_help
  ; { word = "run-next"
    ; aliases = []
    ; args = ""
    ; summary = "prioritize my queued message, stop the observed turn, and resume"
    }
  ; { word = "reconcile"
    ; aliases = []
    ; args = ""
    ; summary = "check this keeper's held request again when its outcome is unverified"
    }
  ; { word = "priority"
    ; aliases = [ "autonext" ]
    ; args = "[on|off]"
    ; summary = "toggle or set automatic next-turn promotion for user input"
    }
  ; { word = "approve"
    ; aliases = []
    ; args = ""
    ; summary = "allow this keeper's held tool call"
    }
  ; { word = "deny"
    ; aliases = []
    ; args = ""
    ; summary = "deny this keeper's held tool call"
    }
  ; { word = "interrupt"
    ; aliases = []
    ; args = "[keeper]"
    ; summary = "signal a streaming turn to stop: this pane's, or the named keeper's"
    }
  ; { word = "steer"
    ; aliases = []
    ; args = "<message>"
    ; summary = "submit this first, stop the observed turn, and resume"
    }
  ; { word = "thinking"
    ; aliases = []
    ; args = "[hidden|folded|full]"
    ; summary = "set or cycle reasoning visibility"
    }
  ; { word = "calls"
    ; aliases = []
    ; args = ""
    ; summary = "choose an original conversation execution and read its entire result"
    }
  ; { word = "tools"
    ; aliases = []
    ; args = "[compact|results|full]"
    ; summary = "cycle or set tool summary, short results, or full detail"
    }
  ; { word = "memory"
    ; aliases = []
    ; args = "[status]"
    ; summary = "cycle journal rows or read the last measured drain"
    }
  ; { word = "fleet-memory"
    ; aliases = []
    ; args = ""
    ; summary = "browse consolidated facts across the entire keeper fleet"
    }
  ; { word = "find"
    ; aliases = []
    ; args = "[text]"
    ; summary = "go to the newest message holding text; again for the next"
    }
  ; { word = "copy"
    ; aliases = []
    ; args = ""
    ; summary = "send this Keeper's latest completed reply to the terminal clipboard"
    }
  ; { word = "measurement"
    ; aliases = []
    ; args = "<sha256>"
    ; summary = "inspect a published meaning-preservation measurement"
    }
  ; { word = "context"
    ; aliases = []
    ; args = ""
    ; summary = "inspect the last observed provider input"
    }
  ; { word = "music"
    ; aliases = []
    ; args = "[midi]"
    ; summary = "open the music library, or edit the newest chat MIDI and choose its instrument"
    }
  ; { word = "score"
    ; aliases = []
    ; args = "[N]"
    ; summary = "open alphaTex notation and playback in this terminal; N is newest-first"
    }
  ; { word = "image"
    ; aliases = []
    ; args = "<path>"
    ; summary = "draw an image file on the terminal"
    }
  ; { word = "images"
    ; aliases = []
    ; args = "[N]"
    ; summary = "open a conversation image or diagram; N is newest-first"
    }
  ; { word = "attach"
    ; aliases = []
    ; args = "<path>"
    ; summary = "stage an image to send with the next keeper message"
    }
  ; { word = "ref"
    ; aliases = []
    ; args = "<url|file_id>"
    ; summary = "stage an image reference; the provider fetches it"
    }
  ; { word = "preset"
    ; aliases = []
    ; args = "[show <name> | save <name> [description] | restore <name> | delete <name>]"
    ; summary = "list prompt presets; show what one holds; save the live state; restore one \
         (autosaves first); delete one, readable or not"
    }
  ; { word = "errors"
    ; aliases = []
    ; args = ""
    ; summary = "read current history and memory loading errors in full"
    }
  ; { word = "help"
    ; aliases = []
    ; args = ""
    ; summary = "this list"
    }
  ; { word = "features"
    ; aliases = []
    ; args = ""
    ; summary = "what this TUI can do: features, one line each, with the way to open each"
    }
  ; { word = "about"
    ; aliases = [ "splash" ]
    ; args = ""
    ; summary = "the turning MASC imp, with the theme and the keeper count"
    }
  ; { word = "metrics"
    ; aliases = [ "telemetry" ]
    ; args = ""
    ; summary = "open Usage with provider quotas, Keeper reports, and telemetry"
    }
  ; { word = "activity"
    ; aliases = []
    ; args = "[fleet|changes|order [newest|oldest|longest|tool]|scroll up|down|top|+N|-N]"
    ; summary = "walk the Activity pane beside this surface narrow, wide, hidden, show one of its tabs, turn the order of its calls, or scroll it"
    }
  ; { word = "preview"
    ; aliases = []
    ; args = "[url]"
    ; summary = "open the OpenGraph preview for a web link"
    }
  ; { word = "links"
    ; aliases = []
    ; args = ""
    ; summary = "browse and inspect all web links mentioned in the current conversation"
    }
  ; { word = "embeds"
    ; aliases = []
    ; args = "[on|compact|off]"
    ; summary = "configure inline chat rich embed cards (on, compact, or off)"
    }
  ]

let usage entry =
  if String.equal entry.args "" then "/" ^ entry.word
  else "/" ^ entry.word ^ " " ^ entry.args

(* Where a help line's summary starts. Usages wider than this keep their two
   spaces rather than pushing every other summary right: one long argument
   list would otherwise indent the whole page past what a narrow pane holds.
   The value is the column the hand-written list already used. *)
let help_summary_column = 16

(* The usage column as both readers draw it. [help_lines] joins it to the
   summary and the cheat sheet colours the two halves separately, so the column
   and its width live here rather than once per reader. The other spellings
   ride in the column instead of claiming a row of their own: a row apiece said
   the same sentence twice and left a reader to guess whether the two words
   differed. *)
let help_usage entry =
  match entry.aliases with
  | [] -> usage entry
  | aliases ->
      usage entry
      ^ " ("
      ^ String.concat " " (List.map (fun word -> "/" ^ word) aliases)
      ^ ")"

let help_summary_padding text =
  String.make (max 2 (help_summary_column - String.length text)) ' '

let summary_ko = function
  | "login" -> "공식 클라이언트에 로그인하고 모델 연결을 확인합니다"
  | "task-inspect" -> "이 세션의 작업 생성 이력을 반복 생성 없이 확인합니다"
  | "task-recover" -> "보관된 키퍼 작업 명령을 복구합니다 (미확인 생성은 작업 목록 먼저 확인)"
  | "task" -> "이 키퍼에 작업을 만듭니다 (아래 줄은 본문으로 들어갑니다)"
  | "keeper" -> "이 대화 창을 다른 키퍼로 전환합니다"
  | "addons" -> "선택형 크로스레인 관측 및 패키지 동작을 엽니다"
  | "play" -> "공유 DOS 플레이 링크를 조회·발급·취소합니다"
  | "listen" -> "이 대화의 가장 최근 오디오 또는 MIDI 첨부를 재생합니다"
  | "artifacts" | "reports" -> "발행된 Markdown·HTML 보고서를 전체 폭 리더로 봅니다"
  | "settings" -> "타입별 런타임 설정 화면을 엽니다"
  | "diff" -> "워크스페이스 Git 변경 목록과 diff를 엽니다"
  | "cost" -> "제공자 할당량과 키퍼 사용량 화면을 엽니다"
  | "changes" -> "이 키퍼에 기록된 파일 변경 목록을 엽니다"
  | "queue" -> "대기열 패널을 열거나 대기 중인 작업을 관리합니다"
  | "run-next" -> "내 대기 메시지를 우선 올리고 현재 턴을 멈춘 뒤 이어서 실행합니다"
  | "reconcile" -> "결과가 확인되지 않은 이 키퍼의 보류 요청을 다시 확인합니다"
  | "priority" | "autonext" -> "사용자 입력의 다음 턴 자동 우선 승격을 켜거나 끕니다"
  | "approve" -> "이 키퍼의 보류 중인 도구 호출을 승인합니다"
  | "deny" -> "이 키퍼의 보류 중인 도구 호출을 거절합니다"
  | "interrupt" -> "진행 중인 턴에 중단 신호를 보냅니다 (현재 창 또는 지정 키퍼)"
  | "steer" -> "이 메시지를 먼저 올리고 현재 턴을 멈춘 뒤 이어서 실행합니다"
  | "thinking" -> "추론 과정 표시 방식을 설정하거나 순환합니다"
  | "calls" -> "대화의 원본 실행 기록을 골라 전체 결과를 봅니다"
  | "tools" -> "도구 요약·짧은 결과·전체 상세 표시를 설정하거나 순환합니다"
  | "memory" -> "기억 기록 표시를 순환하거나 최근 처리 상태를 조회하고 동기화를 요청합니다"
  | "fleet-memory" -> "전체 키퍼의 통합 기억 사실을 한꺼번에 탐색합니다"
  | "find" -> "텍스트가 들어 있는 최신 메시지로 이동합니다 (다시 입력하면 이전 일치)"
  | "copy" -> "이 키퍼의 가장 최근 완료 답변을 터미널 클립보드로 복사합니다"
  | "measurement" -> "발행된 의미 보존 측정 결과를 확인합니다"
  | "context" -> "최근 관측된 제공자 입력 구성을 검사합니다"
  | "music" -> "음악 라이브러리를 열거나 최신 채팅 MIDI 편집·악기 선택을 엽니다"
  | "score" -> "이 터미널에서 alphaTex 악보와 재생을 엽니다 (N은 최신순)"
  | "image" -> "이미지 파일을 터미널에 표시합니다"
  | "images" -> "대화 이미지나 다이어그램을 엽니다 (N은 최신순)"
  | "attach" -> "다음 키퍼 메시지에 보낼 이미지를 첨부합니다"
  | "ref" -> "제공자가 가져올 이미지 참조(URL/file_id)를 첨부합니다"
  | "preset" -> "프롬프트 프리셋을 조회·저장·복원(자동 백업)·삭제합니다"
  | "errors" -> "현재 대화·기억 불러오기 오류 전문을 읽습니다"
  | "help" -> "이 명령어 목록을 표시합니다"
  | "features" -> "이 TUI의 기능별 한 줄 설명과 여는 방법을 봅니다"
  | "about" | "splash" -> "회전하는 MASC 임프와 현재 테마·키퍼 수를 봅니다"
  | "metrics" | "telemetry" -> "제공자 할당량·키퍼 보고서·텔레메트리가 있는 사용량 화면을 엽니다"
  | "activity" -> "활동 패널을 좁게·넓게·숨김으로 전환하거나 탭·정렬·스크롤을 제어합니다"
  | "preview" -> "웹 링크의 OpenGraph 미리보기를 엽니다"
  | "links" -> "현재 대화에 언급된 모든 웹 링크를 탐색합니다"
  | "embeds" -> "채팅 인라인 리치 임베드 카드 표시를 설정합니다 (on/compact/off)"
  | _ -> ""

let summary_for ~ko entry =
  if not ko then entry.summary
  else
    match summary_ko entry.word with
    | "" -> entry.summary
    | ko_text -> ko_text

let help_lines_for ~ko =
  List.map
    (fun entry ->
       let text = help_usage entry in
       text ^ help_summary_padding text ^ summary_for ~ko entry)
    catalog

(* Every spelling the parser answers to, one entry each. An alias is not a
   second command: the parser folds the pair into a single arm
   ("metrics", _ | "telemetry", _ -> Open_metrics), so the catalog describes the
   command once and this projection spells it as many ways as the parser
   accepts. The composer reads this list, the help row reads [catalog] -- which
   is why a new alias cannot arrive with its summary copied beside it. *)
let spelled_catalog =
  List.concat_map
    (fun entry ->
       List.map
         (fun word -> { entry with word; aliases = [] })
         (entry.word :: entry.aliases))
    catalog

let spellings = List.map (fun entry -> entry.word) spelled_catalog

let slash = '/'

(* The first line and the rest, split once on the first newline. *)
let split_first_line text =
  match String.index_opt text '\n' with
  | None -> (text, "")
  | Some at ->
      (String.sub text 0 at, String.sub text (at + 1) (String.length text - at - 1))

(* The word after the slash and whatever follows it on the line. The word
   ends at the first blank; a line that is only the word has an empty rest. *)
let split_word_source line =
  let is_blank c = c = ' ' || c = '\t' in
  let length = String.length line in
  let rec word_end i = if i < length && not (is_blank line.[i]) then word_end (i + 1) else i in
  let stop = word_end 0 in
  (* The same whitespace grammar as [String.trim], retaining its source
     offsets before the argument is projected into a message. *)
  let is_space = function ' ' | '\012' | '\n' | '\r' | '\t' -> true | _ -> false in
  let rec leading i = if i < length && is_space line.[i] then leading (i + 1) else i in
  let offset = leading stop in
  let rec trailing i = if i >= offset && is_space line.[i] then trailing (i - 1) else i in
  let rest_length = trailing (length - 1) - offset + 1 in
  (String.sub line 0 stop, String.sub line offset rest_length,
   { Masc_tui_message_input.offset; length = rest_length })

let split_word line =
  let word, rest, _ = split_word_source line in
  word, rest

let parse_with_message_source text =
  let source = ref None in
  let payload ranges command = source := Some ranges; command in
  let command =
  if String.length text = 0 || text.[0] <> slash then
    payload [{ Masc_tui_message_input.offset = 0; length = String.length text }] (Say text)
  else
    let first, body = split_first_line text in
    let line = String.sub first 1 (String.length first - 1) in
    let word, rest, argument = split_word_source line in
    match word, rest with
    | "task-recover", "" -> Task_recover
    | "task-inspect", "" -> Task_inspect
    | "task", "" -> Task_missing_title
    | "task", title -> Task_for_keeper { title; body }
    | "errors", "" -> Show_load_errors
    | "help", _ -> Help
    | "features", _ -> Features
    | ("artifacts" | "reports"), "" when body = "" -> Open_artifacts
    | "about", _ | "splash", _ -> About
    | "addons", arg -> Lane_addons arg
    | "play", "" | "play", "invites" -> Play_invites
    | "play", "link" -> Play_link None
    | "play", arg -> (
        match split_word arg with
        | "link", rest -> (
            match split_word rest with
            | name, "" when name <> "" -> Play_link (Some name)
            | _ -> Play_invalid "use /play link [name]")
        | "invite", rest -> (
            let name, hours_and_tail = split_word rest in
            let raw_hours, tail = split_word hours_and_tail in
            match name, raw_hours, tail with
            | name, raw_hours, "" when name <> "" && raw_hours <> "" -> (
                match int_of_string_opt raw_hours with
                | Some hours -> Play_invite { name; hours }
                | None -> Play_invalid "hours must be an integer")
            | _ -> Play_invalid "use /play invite <name> <hours>")
        | "revoke", rest -> (
            match split_word rest with
            | name, "" when name <> "" -> Play_revoke name
            | _ -> Play_invalid "use /play revoke <name>")
        | _ -> Play_invalid "use /play invites, /play invite <name> <hours>, /play link [name], or /play revoke <name>")
    | "metrics", _ | "telemetry", _ -> Open_metrics
    | "listen", _ -> Listen
    | "music", "" when body = "" -> Open_music
    | "music", "midi" when body = "" -> Open_music_midi
    | "music", _ -> Music_invalid_arguments
    | "score", "" -> Open_score 1
    | "score", index ->
        (match int_of_string_opt index with
         | Some index when index > 0 -> Open_score index
         | Some _ | None -> Score_invalid_index)
    | "images", "" -> List_images
    | "images", index ->
        (match int_of_string_opt index with
         | Some index when index > 0 -> Open_images index
         | Some _ | None -> Images_invalid_index)
    | "login", client -> Account_login client
    | "settings", _ -> Open_settings
    | "diff", _ -> Open_diff
    | "cost", _ -> Open_usage
    | "preview", arg ->
        let trimmed = String.trim arg in
        if String.equal trimmed "" then Open_link_preview None
        else Open_link_preview (Some trimmed)
    | "links", _ -> Open_links_list
    | "embeds", arg ->
        let trimmed = String.trim arg |> String.lowercase_ascii in
        (match trimmed with
         | "off" | "none" -> Set_embeds `Off
         | "compact" -> Set_embeds `Compact
         | "on" | "rich" | "full" | _ -> Set_embeds `On)
    | "changes", _ -> Open_changes
    | "activity", "" -> Toggle_acting_pane
    | "activity", "fleet" -> Show_acting_pane_tab `Fleet
    | "activity", "changes" -> Show_acting_pane_tab `Changes
    (* The calls' order used to turn only under a mouse press on their
       heading, so a terminal that does not report the mouse could not reach
       it (#37672). The words are the heading's own: "by tool" is also
       taken as "tool". *)
    | "activity", arg when String.equal (fst (split_word arg)) "order" -> (
        match snd (split_word arg) with
        | "" -> Set_acting_pane_call_order `Next
        | "newest" -> Set_acting_pane_call_order `Newest
        | "oldest" -> Set_acting_pane_call_order `Oldest
        | "longest" -> Set_acting_pane_call_order `Longest
        | "tool" | "by tool" -> Set_acting_pane_call_order `By_tool
        | other -> Acting_pane_call_order_unknown other)
    (* The pane scrolled only under the wheel or a press on its "more" row
       (#37672). Up and down move one wheel notch; a signed number moves
       that many rows. *)
    | "activity", arg when String.equal (fst (split_word arg)) "scroll" -> (
        match snd (split_word arg) with
        | "up" -> Scroll_acting_pane `Up
        | "down" -> Scroll_acting_pane `Down
        | "top" -> Scroll_acting_pane `Top
        | word -> (
            let signed =
              String.length word > 1 && (word.[0] = '+' || word.[0] = '-')
            in
            match (if signed then int_of_string_opt word else None) with
            | Some rows -> Scroll_acting_pane (`By rows)
            | None -> Acting_pane_scroll_unknown word))
    | "activity", other -> Acting_pane_tab_unknown other
    | "keeper", "" -> Switch_keeper_missing_name
    | "keeper", name -> Switch_keeper name
    | "queue", args -> Queue (if body = "" then args else args ^ "\n" ^ body)
    | "run-next", "" -> Run_next
    | "reconcile", "" -> Reconcile_held
    | "priority", args | "autonext", args ->
        Priority (if String.equal args "" then None else Some args)
    | "approve", "" -> Answer_tool_approval true
    | "deny", "" -> Answer_tool_approval false
    | "interrupt", "" -> Interrupt_turn
    | "interrupt", name -> Interrupt_keeper_turn name
    | "steer", "" -> Steer_missing_message
    | "steer", message ->
        let ranges = { argument with offset = argument.offset + 1 }
          :: (if String.equal body "" then [] else
                [{ Masc_tui_message_input.offset = String.length first; length = String.length body + 1 }]) in
        payload ranges (Steer_turn
          (if String.equal body "" then message else message ^ "\n" ^ body))
    | "thinking", "" -> Set_thinking `Cycle
    | "thinking", "hidden" -> Set_thinking `Hidden
    | "thinking", "folded" -> Set_thinking `Folded
    | "thinking", "full" -> Set_thinking `Full
    | "calls", "" -> Open_calls
    | "tools", "" -> Set_tools `Toggle
    | "tools", "compact" -> Set_tools `Compact
    | "tools", "results" -> Set_tools `Results
    | "tools", "full" -> Set_tools `Full
    | "memory", "" -> Cycle_memory
    | "memory", "status" -> Memory_status
    | "memory", arguments -> Unknown ("memory " ^ arguments)
    | "fleet-memory", _ -> Open_fleet_memory
    | "find", "" -> Find_next
    | "find", text -> Find_in_chat text
    | "copy", "" -> Copy_latest_reply
    | "measurement", "" -> Measurement_missing_sha
    | "measurement", sha ->
        Open_measurement (if body = "" then sha else sha ^ "\n" ^ body)
    | "context", _ -> Inspect_context
    | "image", "" -> View_image_missing_path
    | "image", path -> View_image path
    | "attach", "" -> Attach_image_missing_path
    | "attach", path -> Attach_image path
    | "ref", "" -> Attach_image_ref_missing_value
    | "ref", value -> Attach_image_ref value
    | "preset", "" -> Preset_list
    | "preset", rest -> (
        match split_word rest with
        | "save", "" -> Preset_save_missing_name
        | "save", name_and_description ->
            (* The lines below the command are description, the way /task
               takes its body. Dropping them would lose text the operator
               typed on purpose. *)
            let name, first_line = split_word name_and_description in
            let description =
              match (first_line, body) with
              | "", body -> body
              | first_line, "" -> first_line
              | first_line, body -> first_line ^ "\n" ^ body
            in
            Preset_save { name; description }
        | "restore", "" -> Preset_restore_missing_name
        | "restore", name -> Preset_restore name
        | "show", "" -> Preset_show_missing_name
        | "show", name -> Preset_show name
        | "delete", "" -> Preset_delete_missing_name
        | "delete", name -> Preset_delete name
        | verb, _ -> Unknown ("preset " ^ verb))
    | word, _ -> Unknown word
  in
  command, !source

let parse text = fst (parse_with_message_source text)

type hint =
  | No_command
  | Candidates of {
      typed : string;
      entries : command_help list;
    }
  | Chosen of command_help
  | Unknown_command of string

(* One piece of a hint row, split where the colour changes. The module draws
   nothing itself -- it says which glyphs are the ones already typed and
   which are still ahead, and the renderer decides what that looks like. *)
type hint_span =
  | Typed of string  (** Glyphs the operator has already entered. *)
  | Untyped of string  (** What the word would still need. *)
  | Detail of string  (** Arguments, summaries, separators. *)
  | Wrong of string  (** A word that names no command. *)

(* What to show an operator who is part way through typing a command.

   The grammar has no prefix matching, so a half-typed word is not a command
   yet and is never reported as one: [/ta] lists what it could become,
   [/task] describes what it is. Showing the summary any earlier would say a
   line was ready to send when the parser would refuse it.

   A word that begins nothing is named as unknown while the operator can
   still fix it. Before this it took an Enter and a rejected line to find out
   the command did not exist. *)
let hint text =
  if String.length text = 0 || text.[0] <> slash then No_command
  else
    let first, _ = split_first_line text in
    let line = String.sub first 1 (String.length first - 1) in
    let word, _ = split_word line in
    match
      List.find_opt (fun entry -> String.equal entry.word word) spelled_catalog
    with
    | Some entry -> Chosen entry
    | None -> (
        match
          List.filter
            (fun entry -> String.starts_with ~prefix:word entry.word)
            spelled_catalog
        with
        | [] -> Unknown_command word
        | entries -> Candidates { typed = word; entries })

let detail_sep = " \xc2\xb7 "

(* The typed run always starts with the slash, so the highlight covers what
   the operator pressed rather than the word minus its first key. *)
let word_spans ~typed entry =
  let remaining =
    String.sub entry.word (String.length typed)
      (String.length entry.word - String.length typed)
  in
  [ Typed ("/" ^ typed); Untyped remaining ]

(* The bare slash is the row an operator types knowing nothing, so it is the
   one that must not run off the pane.

   It used to draw every command word, and it fit until it did not: the list
   was compacted once when /settings joined the catalog and ran over again at
   /find. A row sized by how many commands happen to exist is a row that
   breaks on the next one, so this one carries what fits and says how many it
   could not, pointing at the list that is complete by definition.

   Command words are ASCII by construction -- they are spelled in [catalog]
   above -- so bytes and cells are the same count here. *)
let bare_slash_hint_cells = 80

let bare_slash_spans ~ko entries =
  let total = List.length entries in
  let rendered kept_count =
    let words =
      entries
      |> List.filteri (fun index _ -> index < kept_count)
      |> List.map (fun entry -> entry.word)
      |> String.concat " "
    in
    let dropped = total - kept_count in
    let tail, tail_cells =
      if dropped <= 0 then "", 0
      else if ko then
        let text = Printf.sprintf " 외 %d개 (/help)" dropped in
        (* Each of the two Hangul syllables is 3 UTF-8 bytes and 2 display cells. *)
        text, String.length text - 2
      else
        let text = Printf.sprintf " +%d more (/help)" dropped in
        text, String.length text
    in
    (words, tail, 1 + String.length words + tail_cells)
  in
  (* At most one row of candidates and a dozen words, so the fit is found by
     trying rather than by solving for a marker whose own width depends on how
     many words were dropped. *)
  let rec choose kept_count =
    if kept_count <= 0 then rendered 0
    else
      let (_, _, width) as attempt = rendered kept_count in
      if width <= bare_slash_hint_cells then attempt else choose (kept_count - 1)
  in
  let words, tail, _ = choose total in
  [ Typed "/"; Untyped words ]
  @ (if String.equal tail "" then [] else [ Detail tail ])

let hint_spans_for ~ko = function
  | No_command -> []
  | Chosen entry ->
      Typed ("/" ^ entry.word)
      :: (if String.equal entry.args "" then []
          else [ Detail (" " ^ entry.args) ])
      @ [ Detail (detail_sep ^ summary_for ~ko entry) ]
  | Candidates { typed; entries = [ entry ] } ->
      (* Down to one word, so there is room to say how it ends even though the
         word itself is not typed out yet. *)
      word_spans ~typed entry
      @ (if String.equal entry.args "" then []
         else [ Detail (" " ^ entry.args) ])
  | Candidates { typed = ""; entries } -> bare_slash_spans ~ko entries
  | Candidates { typed; entries } ->
      (* Names only. Every usage spelled out runs past a 120-column pane on
         the bare slash, and the commands that fell off the end were the ones
         an operator who typed [/] had not thought of yet.

         One space between them, not two.  The bare slash has its own compact
         branch above; once a prefix is typed, the shorter candidate list can
         afford to repeat each slash. *)
      List.concat
        (List.mapi
           (fun index entry ->
              (if index = 0 then [] else [ Detail " " ])
              @ word_spans ~typed entry)
           entries)
  | Unknown_command word ->
      [ Wrong ("/" ^ word)
      ; Detail
          (if ko then " · 없는 명령" ^ detail_sep ^ "/help로 목록 보기"
           else " is not a command" ^ detail_sep ^ "/help lists them")
      ]

(* How [/keeper <name>] finds its keeper. The command grammar stays closed —
   no prefix matching on command words — but a keeper NAME is an argument,
   and an operator mid-thought types the least of it that still names one
   keeper. Exact match wins outright so a keeper whose full name prefixes
   another's is still reachable; otherwise a prefix must be unique, and an
   ambiguous one reports its candidates instead of guessing. *)
type keeper_match =
  | Keeper_found of string
  | Keeper_ambiguous of string list
  | Keeper_unknown

let resolve_keeper_name ~names typed =
  if List.exists (String.equal typed) names then Keeper_found typed
  else
    match
      List.filter (fun name -> String.starts_with ~prefix:typed name) names
    with
    | [ name ] -> Keeper_found name
    | [] -> Keeper_unknown
    | candidates -> Keeper_ambiguous candidates

let task_message ~task_id ~title ~body =
  if String.equal (String.trim body) "" then Printf.sprintf "[%s] %s" task_id title
  else Printf.sprintf "[%s] %s\n%s" task_id title body

let rec make_valid_utf_8 s =
  if String.equal s "" || String.is_valid_utf_8 s then s
  else make_valid_utf_8 (String.sub s 0 (String.length s - 1))

let longest_common_prefix = function
  | [] -> ""
  | [ s ] -> s
  | s :: rest ->
      let common_prefix a b =
        let max_len = min (String.length a) (String.length b) in
        let rec loop i =
          if i < max_len && a.[i] = b.[i] then loop (i + 1) else i
        in
        make_valid_utf_8 (String.sub a 0 (loop 0))
      in
      List.fold_left common_prefix s rest

type direction = Next | Prev

let cycle_next ~items current =
  match items with
  | [] -> None
  | [ single ] -> Some single
  | _ -> (
      match List.find_index (fun s -> String.equal s current) items with
      | Some idx ->
          let next_idx = (idx + 1) mod List.length items in
          Some (List.nth items next_idx)
      | None -> Some (List.hd items))

let cycle_prev ~items current =
  match items with
  | [] -> None
  | [ single ] -> Some single
  | _ -> (
      match List.find_index (fun s -> String.equal s current) items with
      | Some idx ->
          let len = List.length items in
          let prev_idx = (idx - 1 + len) mod len in
          Some (List.nth items prev_idx)
      | None ->
          let len = List.length items in
          Some (List.nth items (len - 1)))

let cycle_step ~direction ~items current =
  match direction with
  | Next -> cycle_next ~items current
  | Prev -> cycle_prev ~items current

let known_sub_arguments ~keeper_names word =
  match word with
  | "thinking" -> [ "hidden"; "folded"; "full" ]
  | "tools" -> [ "compact"; "results"; "full" ]
  | "memory" -> [ "status" ]
  (* [show] goes last: [save] is the older word and shares its first
     letter, so leading with [show] would move where "/preset s" lands. *)
  | "preset" -> [ "save"; "restore"; "show" ]
  | "play" -> [ "invites"; "invite"; "link"; "revoke" ]
  | "keeper" -> keeper_names
  | _ -> []

let with_body body text =
  if String.equal body "" then text else text ^ "\n" ^ body

type menu_state = Menu_idle | Menu_dismissed of string | Menu_selected of { draft : string; index : int }
type menu_item = { completion : string; label : string; description : string }
type menu = { items : menu_item list; selected : int }

let menu ~ko ~keeper_names ~state text =
  let dismissed = match state with
    | Menu_dismissed draft -> String.equal draft text
    | Menu_idle | Menu_selected _ -> false in
  if dismissed || String.equal text "" || text.[0] <> slash then None
  else
    let first, body = split_first_line text in
    let line = String.sub first 1 (String.length first - 1) in
    let word, argument = split_word line in
    let items =
      if not (String.contains line ' ') then
        if List.exists (fun entry -> String.equal entry.word word) spelled_catalog then []
        else List.filter_map (fun entry ->
          if String.starts_with ~prefix:word entry.word then
            let suffix = if String.equal entry.args "" then "" else " " in
            Some {completion = with_body body ("/" ^ entry.word ^ suffix);
                  label = "/" ^ entry.word; description = summary_for ~ko entry}
          else None) spelled_catalog
      else if not (String.equal argument "") && String.ends_with ~suffix:" " line then []
      else match List.find_opt (fun entry -> String.equal entry.word word) spelled_catalog with
      | None -> []
      | Some entry ->
        let options = known_sub_arguments ~keeper_names word in
        if List.exists (String.equal argument) options then []
        else List.filter_map (fun option ->
          if String.starts_with ~prefix:argument option then
            let label = "/" ^ word ^ " " ^ option in
            Some {completion = with_body body label; label;
                  description = summary_for ~ko entry}
          else None) options in
    match items with
    | [] -> None
    | _ ->
      let selected = match state with
        | Menu_selected {draft; index} when String.equal draft text ->
          max 0 (min (List.length items - 1) index)
        | Menu_idle | Menu_dismissed _ | Menu_selected _ -> 0 in
      Some {items; selected}

let menu_step ~direction ~draft menu =
  let length = List.length menu.items in
  let delta = match direction with Next -> 1 | Prev -> length - 1 in
  Menu_selected {draft; index = (menu.selected + delta) mod length}

let menu_accept menu = (List.nth menu.items menu.selected).completion

let menu_window ~max_rows menu =
  let count = min (List.length menu.items) (max 0 max_rows) in
  let first = max 0 (min (menu.selected - count / 2) (List.length menu.items - count)) in
  menu.items |> List.mapi (fun index item -> index, item)
  |> List.filter_map (fun (index, item) ->
    if index >= first && index < first + count then Some (index = menu.selected, item) else None)

let autocomplete ?(direction = Next) ?(keeper_names = []) text =
  if String.length text = 0 || text.[0] <> slash then None
  else
    let first, body = split_first_line text in
    let line = String.sub first 1 (String.length first - 1) in
    if not (String.contains line ' ') then begin
      (* Command word completion *)
      let candidates =
        match List.find_opt (fun entry -> String.equal entry.word line) spelled_catalog with
        | Some entry -> [ entry ]
        | None ->
            List.filter
              (fun entry -> String.starts_with ~prefix:line entry.word)
              spelled_catalog
      in
      match candidates with
      | [] -> None
      | [ single ] ->
          let suffix = if String.equal single.args "" then "" else " " in
          if String.equal line single.word then
            if String.equal suffix "" then None
            else Some (with_body body ("/" ^ single.word ^ suffix))
          else
            Some (with_body body ("/" ^ single.word ^ suffix))
      | entries ->
          let words = List.map (fun e -> e.word) entries in
          let lcp = longest_common_prefix words in
          if direction = Next && String.length lcp > String.length line then
            Some (with_body body ("/" ^ lcp))
          else
            (match cycle_step ~direction ~items:words line with
             | Some next_word ->
                 let next_entry =
                   List.find (fun e -> String.equal e.word next_word) entries
                 in
                 let suffix = if String.equal next_entry.args "" then "" else " " in
                 Some (with_body body ("/" ^ next_word ^ suffix))
             | None -> None)
    end else begin
      (* Sub-argument completion on first line *)
      let word_len = String.index line ' ' in
      let word = String.sub line 0 word_len in
      let after_space =
        String.sub line (word_len + 1) (String.length line - word_len - 1)
      in
      let options = known_sub_arguments ~keeper_names word in
      if options = [] then None
      else if String.equal (String.trim after_space) "" then
        let chosen =
          match direction with
          | Next -> List.hd options
          | Prev -> List.nth options (List.length options - 1)
        in
        Some (with_body body ("/" ^ word ^ " " ^ chosen))
      else if String.ends_with ~suffix:" " after_space then
        None
      else
        let rest = String.trim after_space in
        let matches =
          List.filter
            (fun opt -> String.starts_with ~prefix:rest opt)
            options
        in
        match matches with
        | [] -> None
        | [ single ] when not (String.equal rest single) ->
            Some (with_body body ("/" ^ word ^ " " ^ single))
        | [ single ] ->
            (match cycle_step ~direction ~items:options single with
             | Some next_opt -> Some (with_body body ("/" ^ word ^ " " ^ next_opt))
             | None -> None)
        | many ->
            let lcp = longest_common_prefix many in
            if direction = Next && String.length lcp > String.length rest then
              Some (with_body body ("/" ^ word ^ " " ^ lcp))
            else
              (match cycle_step ~direction ~items:many rest with
               | Some next_opt -> Some (with_body body ("/" ^ word ^ " " ^ next_opt))
               | None -> None)
    end

let is_slash_navigable ?(keeper_names = []) text =
  if String.length text = 0 || text.[0] <> slash then false
  else
    let first, _ = split_first_line text in
    let line = String.sub first 1 (String.length first - 1) in
    if not (String.contains line ' ') then
      let candidates =
        if String.equal line "" then spelled_catalog
        else
          List.filter
            (fun entry -> String.starts_with ~prefix:line entry.word)
            spelled_catalog
      in
      match candidates with
      | [] -> false
      | [ single ] ->
          if not (String.equal line single.word) then true
          else not (String.equal single.args "")
      | _ :: _ -> true
    else
      let word_len = String.index line ' ' in
      let word = String.sub line 0 word_len in
      let after_space =
        String.sub line (word_len + 1) (String.length line - word_len - 1)
      in
      let options = known_sub_arguments ~keeper_names word in
      if options = [] then false
      else if String.equal (String.trim after_space) "" then true
      else if String.ends_with ~suffix:" " after_space then false
      else
        let rest = String.trim after_space in
        List.exists (fun opt -> String.starts_with ~prefix:rest opt) options

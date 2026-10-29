module Terminal_text = Masc_tui_ansi.Terminal_text
module Standing = Masc.Keeper_memory_recall_standing
module Reading = Masc.Tui_decode_memory_recall

type mode =
  | Off
  | Listed
  | All

type presence =
  | Running
  | Stopped
  | Unknown

type roster_entry =
  { name : string
  ; presence : presence
  }

type server =
  | Server_unread
  | Server_unavailable of string
  | Server_read of Reading.memory_recall_reading

(* A row of the Keeper list. [known] is false for a name the file lists that
   the TUI's roster does not have: a misspelt or retired name reaches nobody
   (boot reports it through [Typesafeai_config.unknown_memory_recall_keepers]),
   so the form keeps it in the list, marked, where it can be dropped. *)
type entry =
  { keeper : roster_entry
  ; known : bool
  ; excluded : bool
  }

(* [text] is the file the form was opened on, so {!text_on} is a function of
   the form alone. [declared] is what its three keys say, switch and scope
   apart; [initial] is what they come to for a keeper: off, or on for a scope.
   [picked] keeps the file's order and appends new picks, so a save that
   changes one Keeper moves one line of the array. It starts as the list the
   file holds even when the switch is off, and it is kept while the mode is
   not [Listed]: switching back shows the same picks. *)
type t =
  { source_revision : string option
  ; text : string
  ; declared : Runtime_toml.memory_recall_declaration
  ; initial : Runtime_schema.memory_recall
  ; mode : mode
  ; entries : entry list
  ; picked : string list
  ; cursor : int
  ; error : string option
  ; server : server
  }

type outcome =
  | Editing of t
  | Cancelled
  | Submitted of t

type detail =
  { before : mode
  ; after : mode
  ; added : string list
  ; dropped : string list
  ; list_kept : int
  ; list_removed : int
  }

type change =
  | Unchanged
  | Nobody_picked
  | Changed of detail

(* The table and keys [Runtime_toml.parse_typesafeai_memory_recall] reads. The
   edited text is read back with that parser before it is returned, so a
   spelling that drifts from it is refused here and not written. *)
let table = Runtime_toml_namespace.(key Typesafeai)
let switch_key = "memory_recall"
let scope_key = "memory_recall_scope"
let keepers_key = "memory_recall_keepers"
let scope_all = "all"
let scope_listed = "listed"
let source_revision t = t.source_revision

let describe_errors (errors : Runtime_toml.parse_error list) =
  match errors with
  | [] -> "읽는 쪽이 이유를 주지 않았어요"
  | first :: rest ->
    let head =
      Printf.sprintf "%s: %s" first.Runtime_toml.path first.Runtime_toml.message
    in
    (match rest with
     | [] -> head
     | _ :: _ -> Printf.sprintf "%s (외 %d건)" head (List.length rest))
;;

let without_repeats names =
  List.fold_left
    (fun kept name -> if List.mem name kept then kept else kept @ [ name ])
    []
    names
;;

(* The Keepers a list names, in the order written, or none when the scope is
   not a list. Whatever the switch says. *)
let held_names (declared : Runtime_toml.memory_recall_declaration) =
  match declared.Runtime_toml.scope with
  | Some (Runtime_schema.Listed_keepers (first, rest)) -> without_repeats (first :: rest)
  | Some Runtime_schema.All_keepers | None -> []
;;

(* What the three keys come to. [Runtime_toml.parse_string] refuses a switch
   that is on without a scope, so the last case is not met after it succeeded;
   it is an answer rather than a guess. *)
let effective (declared : Runtime_toml.memory_recall_declaration) =
  match declared.Runtime_toml.switch, declared.Runtime_toml.scope with
  | false, (Some _ | None) -> Ok Runtime_schema.Memory_recall_off
  | true, Some scope -> Ok (Runtime_schema.Memory_recall_on scope)
  | true, None -> Error "memory_recall = true 인데 memory_recall_scope 가 없어요"
;;

let mode_of_recall = function
  | Runtime_schema.Memory_recall_off -> Off
  | Runtime_schema.Memory_recall_on Runtime_schema.All_keepers -> All
  | Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers _) -> Listed
;;

let open_on ?source_revision ~keepers text =
  let cannot_open errors =
    Error ("runtime.toml 을 읽지 못해서 폼을 열 수 없어요 · " ^ describe_errors errors)
  in
  match Runtime_toml.parse_string text with
  | Error errors -> cannot_open errors
  | Ok config ->
    (match Runtime_toml.memory_recall_declaration_of_string text with
     | Error errors -> cannot_open errors
     | Ok declared ->
       (match effective declared with
        | Error reason -> Error ("runtime.toml 을 읽지 못해서 폼을 열 수 없어요 · " ^ reason)
        | Ok initial ->
          let excluded_keepers =
            config.Runtime_schema.typesafeai.Runtime_schema.excluded_keepers
          in
          let picked = held_names declared in
          let roster =
            List.sort_uniq
              (fun (left : roster_entry) (right : roster_entry) ->
                 String.compare left.name right.name)
              keepers
          in
          let unknown =
            List.filter
              (fun name ->
                 not
                   (List.exists
                      (fun (keeper : roster_entry) -> String.equal keeper.name name)
                      roster))
              picked
          in
          let entry ~known (keeper : roster_entry) =
            { keeper; known; excluded = List.mem keeper.name excluded_keepers }
          in
          Ok
            { source_revision
            ; text
            ; declared
            ; initial
            ; mode = mode_of_recall initial
            ; entries =
                List.map (entry ~known:true) roster
                @ List.map
                    (fun name -> entry ~known:false { name; presence = Unknown })
                    unknown
            ; picked
            ; cursor = 0
            ; error = None
            ; server = Server_unread
            }))
;;

let with_server t server = { t with server }

let next_mode = function
  | Off -> Listed
  | Listed -> All
  | All -> Off
;;

let previous_mode = function
  | Off -> All
  | Listed -> Off
  | All -> Listed
;;

(* The range row, then one row per Keeper while the mode is [Listed]. *)
let row_count t =
  match t.mode with
  | Listed -> 1 + List.length t.entries
  | Off | All -> 1
;;

let move t delta =
  { t with cursor = max 0 (min (row_count t - 1) (t.cursor + delta)) }
;;

(* The mode changes only from the range row, so the cursor is already on a row
   every mode has. *)
let choose t mode = { t with mode; error = None }

let toggle t =
  if t.cursor = 0
  then t
  else (
    match List.nth_opt t.entries (t.cursor - 1) with
    | None -> t
    | Some entry ->
      let name = entry.keeper.name in
      let picked =
        if List.mem name t.picked
        then List.filter (fun picked -> not (String.equal picked name)) t.picked
        else t.picked @ [ name ]
      in
      { t with picked; error = None })
;;

let key t key =
  match key with
  | "esc" -> Cancelled
  | "\r" | "\n" | "enter" -> Submitted t
  | "up" | "k" | "shift-tab" -> Editing (move t (-1))
  | "down" | "j" | "tab" | "\t" -> Editing (move t 1)
  | "left" when t.cursor = 0 -> Editing (choose t (previous_mode t.mode))
  | "right" | " " | "space" when t.cursor = 0 -> Editing (choose t (next_mode t.mode))
  | " " | "space" -> Editing (toggle t)
  | _ -> Editing t
;;

let refused t reason = { t with error = Some reason }

let nobody_picked = "고른 키퍼가 없어요. 한 명 이상 고르거나 범위를 바꿔 주세요."

let unchangeable =
  "[typesafeai] 가 폼으로 고칠 수 있는 모양이 아니에요. e 로 파일을 직접 고쳐 주세요."
;;

(* What the form stands for, or [None] for [Listed] with nobody picked, which
   is no choice to write. *)
let chosen t =
  match t.mode with
  | Off -> Some Runtime_schema.Memory_recall_off
  | All -> Some (Runtime_schema.Memory_recall_on Runtime_schema.All_keepers)
  | Listed ->
    (match t.picked with
     | [] -> None
     | first :: rest ->
       Some
         (Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers (first, rest))))
;;

(* Which keepers a list names does not depend on the order it is written in
   (the gate asks [List.mem]), so two lists name the same keepers when they
   hold the same names. Picking a keeper off and on again moves it to the end
   of [picked]; that is no change to the file. *)
let same_names left right =
  List.equal
    String.equal
    (List.sort_uniq String.compare left)
    (List.sort_uniq String.compare right)
;;

let same_choice left right =
  match left, right with
  | ( Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers (left_first, left_rest))
    , Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers (right_first, right_rest))
    ) -> same_names (left_first :: left_rest) (right_first :: right_rest)
  | ( ( Runtime_schema.Memory_recall_off
      | Runtime_schema.Memory_recall_on Runtime_schema.All_keepers
      | Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers _) )
    , _ ) -> Runtime_schema.equal_memory_recall left right
;;

let change t =
  match chosen t with
  | None -> Nobody_picked
  | Some chosen when same_choice chosen t.initial -> Unchanged
  | Some _ ->
    let held = held_names t.declared in
    let picked = without_repeats t.picked in
    let after = t.mode in
    let listed_after = match after with Listed -> true | Off | All -> false in
    Changed
      { before = mode_of_recall t.initial
      ; after
      ; added =
          (if listed_after
           then List.filter (fun name -> not (List.mem name held)) picked
           else [])
      ; dropped =
          (if listed_after
           then List.filter (fun name -> not (List.mem name picked)) held
           else [])
      ; list_kept = (match after with Off -> List.length held | Listed | All -> 0)
      ; list_removed = (match after with All -> List.length held | Listed | Off -> 0)
      }
;;

(* Rewriting a key drops the comment on its line, so a key that already holds
   what the choice needs is left alone: the switch when the file has it on,
   the scope when it already names the same kind, the list when it already
   names the same keepers. A file that switched recall off by hand and kept
   its list therefore gets the switch alone when recall is switched back on
   over that list. Off writes the switch alone, so a list the file keeps stays
   for the next time. [All] drops the list because the file refuses one next
   to scope "all". A list that does change is written whole, and the comments
   inside it go. *)
let write ~(declared : Runtime_toml.memory_recall_declaration) chosen text =
  let set_switch value text =
    Toml_line_editor.edit_table_bool text ~path:table ~key:switch_key ~value
  in
  let set_scope scope text =
    Toml_line_editor.edit_table_scalar text ~path:table ~key:scope_key ~value:(Some scope)
  in
  let set_keepers names text =
    match names with
    | [] ->
      Toml_line_editor.edit_table_scalar text ~path:table ~key:keepers_key ~value:None
    | names ->
      Toml_line_editor.edit_table_multiline_array
        text
        ~path:table
        ~key:keepers_key
        ~values:names
  in
  let turn_on text = if declared.Runtime_toml.switch then text else set_switch true text in
  let held = held_names declared in
  let scope_is_all, scope_is_listed =
    match declared.Runtime_toml.scope with
    | Some Runtime_schema.All_keepers -> true, false
    | Some (Runtime_schema.Listed_keepers _) -> false, true
    | None -> false, false
  in
  match chosen with
  | Runtime_schema.Memory_recall_off -> set_switch false text
  | Runtime_schema.Memory_recall_on Runtime_schema.All_keepers ->
    let text = turn_on text in
    let text = if scope_is_all then text else set_scope scope_all text in
    if scope_is_listed then set_keepers [] text else text
  | Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers (first, rest)) ->
    let names = first :: rest in
    let text = turn_on text in
    let text = if scope_is_listed then text else set_scope scope_listed text in
    if scope_is_listed && same_names held names then text else set_keepers names text
;;

(* The read-back asks [same_choice], as the decision above does: a list the
   file keeps may name the choice's keepers in another order, or twice, and
   the gate reads that as the same list. *)
let text_on t =
  let refuse reason = Error { t with error = Some reason } in
  match chosen t with
  | None -> refuse nobody_picked
  | Some chosen when same_choice chosen t.initial -> Ok t.text
  | Some chosen ->
    let edited = write ~declared:t.declared chosen t.text in
    (match Runtime_toml.parse_string edited with
     | Ok config
       when same_choice
              config.Runtime_schema.typesafeai.Runtime_schema.memory_recall
              chosen -> Ok edited
     | Ok _ -> refuse unchangeable
     | Error errors ->
       refuse ("고친 결과를 읽지 못했어요 · " ^ describe_errors errors))
;;

let intro = "기억 판정 · 켜진 키퍼는 사실 전체와 지침, 이번 턴 입력을 Jev 로 보내요"
let range_label = "범위"
let all_warning = "모든 키퍼가 대상이에요. excluded_keepers 에 있는 키퍼만 빠져요."
let no_roster = "(키퍼 목록이 비어 있어요)"

let applies_note =
  "저장하면 서버가 바로 읽고 다음 모델 요청부터 바뀌어요. 서버에 Jev 키가 없으면 켜도 보내지 않아요."
;;

let mode_label = function
  | Off -> "꺼짐"
  | Listed -> "고른 키퍼만"
  | All -> "모든 키퍼"
;;

let hint_lead = "  "
let refusal_lead = "  ! "

(* [text] after [lead], on as many rows of [width] cells as it takes. The pane
   cuts a row at its edge, so a sentence longer than the pane is wrapped here
   and its continuation rows step in as far as [lead]. *)
let wrapped ~width ~lead text =
  let lead_cells = Masc_tui_message_layout.display_width lead in
  let indent = String.make lead_cells ' ' in
  match
    Masc_tui_message_layout.wrap_words
      ~max_cells:(max 1 (width - lead_cells))
      (Terminal_text.single_line text)
  with
  | [] -> [ lead ]
  | first :: rest -> (lead ^ first) :: List.map (fun row -> indent ^ row) rest
;;

(* Exhaustive on purpose: a seventh reason stops the build here. *)
let reason_label = function
  | Standing.Environment_switch_off -> "환경 스위치가 꺼져 있어요"
  | Standing.Recall_not_switched_on -> "스위치가 꺼져 있거나 범위 밖이에요"
  | Standing.Keeper_excluded -> "제외 목록에 있어요"
  | Standing.Lane_disabled -> "Jev 길이 꺼져 있어요"
  | Standing.No_armed_destination -> "Jev 키가 없어요"
  | Standing.Refused_by_another_gate -> "다른 게이트의 이유로 닫혀 있어요"
;;

let judged_now (_, standing) =
  match standing with
  | Standing.Judged -> true
  | Standing.Not_judged _ -> false
;;

let environment_switch_is_off (reading : Reading.memory_recall_reading) =
  List.exists
    (fun (_, standing) ->
       match standing with
       | Standing.Not_judged Standing.Environment_switch_off -> true
       | Standing.Judged
       | Standing.Not_judged
           ( Standing.Recall_not_switched_on | Standing.Keeper_excluded
           | Standing.Lane_disabled | Standing.No_armed_destination
           | Standing.Refused_by_another_gate ) -> false)
    reading.Reading.mrr_keepers
;;

(* The reason an answer could not be read comes from the loader and may be a
   server's error body. It takes a few rows at most, so it cannot push the
   range row and the Keeper list off the pane. *)
let server_rows_limit = 3

let capped ~limit rows =
  if List.length rows <= limit
  then rows
  else
    List.filteri (fun index _ -> index < limit) rows
    |> List.mapi (fun index row -> if index = limit - 1 then row ^ " …" else row)
;;

(* What the server says about the gate as a whole. The environment switch is
   asked before the gate, so one Keeper that names it names it for all. *)
let server_line = function
  | Server_unread -> "서버 · 지금 상태를 읽는 중이에요"
  | Server_unavailable detail -> "서버 · 지금 상태를 읽지 못했어요 · " ^ detail
  | Server_read reading ->
    if environment_switch_is_off reading
    then "서버 · 환경 스위치(MASC_KEEPER_MEMORY_OS_RECALL)가 꺼져 있어서 판정 대상이 없어요"
    else (
      match reading.Reading.mrr_lane with
      | Error reason -> "서버 · " ^ reason_label reason
      | Ok () ->
        Printf.sprintf
          "서버 · Jev 키 있음 · 지금 판정 대상 %d명"
          (List.length (List.filter judged_now reading.Reading.mrr_keepers)))
;;

(* A Keeper the server judges says so. One that is picked and not judged says
   why not: the file lists it and the server does not reach it, which is what
   a file the server has not loaded looks like. A Keeper that is neither
   picked nor judged is the usual case and says nothing. *)
let standing_suffix t entry =
  match t.server with
  | Server_unread | Server_unavailable _ -> ""
  | Server_read reading ->
    (match List.assoc_opt entry.keeper.name reading.Reading.mrr_keepers with
     | None -> ""
     | Some Standing.Judged -> "  (지금 판정 대상)"
     | Some (Standing.Not_judged reason) ->
       if List.mem entry.keeper.name t.picked
       then "  (지금은 아니에요 · " ^ reason_label reason ^ ")"
       else "")
;;

let entry_suffix entry =
  (if entry.known then "" else "  (키퍼 목록에 없어요)")
  ^ (match entry.keeper.presence with
     | Stopped -> "  (멈춰 있어요)"
     | Running | Unknown -> "")
  ^ if entry.excluded then "  (제외됨 · 보내지 않아요)" else ""
;;

(* The first few names, then how many more: a list of forty keepers is not a
   row. *)
let shown_names_limit = 4

let names_text names =
  let shown = List.filteri (fun index _ -> index < shown_names_limit) names in
  let more = List.length names - List.length shown in
  String.concat ", " (List.map Terminal_text.single_line shown)
  ^ if more > 0 then Printf.sprintf " 외 %d명" more else ""
;;

let summary_text t =
  match change t with
  | Unchanged -> "바뀌는 것이 없어요"
  | Nobody_picked -> "고른 키퍼가 없어요"
  | Changed detail ->
    let head =
      if detail.before = detail.after
      then mode_label detail.after
      else mode_label detail.before ^ " → " ^ mode_label detail.after
    in
    let names sign = function
      | [] -> []
      | names -> [ sign ^ names_text names ]
    in
    let counted text = function
      | 0 -> []
      | count -> [ Printf.sprintf text count ]
    in
    String.concat
      " · "
      (head
       :: (names "+" detail.added
           @ names "-" detail.dropped
           @ counted "파일의 목록 %d명은 남겨요" detail.list_kept
           @ counted "파일의 목록 %d명은 지워요" detail.list_removed))
;;

(* The slice of [rows] around [cursor] that fits [room], with how many rows
   fall above and below it. *)
let window ~room ~cursor rows =
  let total = List.length rows in
  if total <= room
  then rows, 0, 0
  else (
    let shown = max 1 (room - 1) in
    let start = max 0 (min (total - shown) (cursor - (shown / 2))) in
    let visible = List.filteri (fun index _ -> index >= start && index < start + shown) rows in
    visible, start, total - start - shown)
;;

let rows ~width ~height t =
  let mark index = if t.cursor = index then ">" else " " in
  let intro_rows = wrapped ~width ~lead:hint_lead intro in
  let server_rows =
    capped ~limit:server_rows_limit (wrapped ~width ~lead:hint_lead (server_line t.server))
  in
  let range_row = Printf.sprintf "  %s %s  \xe2\x80\xb9 %s \xe2\x80\xba" (mark 0) range_label (mode_label t.mode) in
  let summary_rows = wrapped ~width ~lead:hint_lead ("저장하면 · " ^ summary_text t) in
  let note_rows =
    (match t.mode, t.entries with
     | All, _ -> wrapped ~width ~lead:hint_lead all_warning
     | Listed, [] -> wrapped ~width ~lead:hint_lead no_roster
     | Listed, _ :: _ | Off, _ -> [])
    @ wrapped ~width ~lead:hint_lead applies_note
  in
  let error_rows =
    match t.error with
    | None -> []
    | Some reason -> wrapped ~width ~lead:refusal_lead reason
  in
  let keeper_rows =
    match t.mode with
    | Off | All -> []
    | Listed ->
      let drawn =
        List.mapi
          (fun index entry ->
             Printf.sprintf
               "    %s [%s] %s%s%s"
               (mark (index + 1))
               (if List.mem entry.keeper.name t.picked then "x" else " ")
               (Terminal_text.single_line entry.keeper.name)
               (entry_suffix entry)
               (standing_suffix t entry))
          t.entries
      in
      let fixed =
        List.length intro_rows
        + List.length server_rows
        + 1
        + List.length summary_rows
        + List.length note_rows
        + List.length error_rows
        + 1
      in
      let visible, above, below =
        window ~room:(max 1 (height - fixed)) ~cursor:(max 0 (t.cursor - 1)) drawn
      in
      if above = 0 && below = 0
      then visible
      else
        visible
        @ [ Printf.sprintf "      … 위 %d명 · 아래 %d명 (↑/↓ 로 움직여요)" above below ]
  in
  intro_rows @ server_rows @ [ range_row ] @ keeper_rows @ summary_rows @ note_rows @ error_rows @ [ "" ]
;;

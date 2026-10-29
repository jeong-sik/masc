module Terminal_text = Masc_tui_ansi.Terminal_text

type mode =
  | Off
  | Listed
  | All

(* A row of the Keeper list. [known] is false for a name the file lists that
   the TUI's roster does not have: a misspelt or retired name reaches nobody
   (boot reports it through [Typesafeai_config.unknown_memory_recall_keepers]),
   so the form keeps it in the list, marked, where it can be dropped. *)
type entry =
  { name : string
  ; known : bool
  ; excluded : bool
  }

(* [text] is the file the form was opened on and [initial] what
   [Runtime_toml] read from it, so {!text_on} is a function of the form alone.
   [picked] keeps the file's order and appends new picks, so a save that
   changes one Keeper moves one line of the array. It is kept while the mode is
   not [Listed]: switching back shows the same picks. *)
type t =
  { source_revision : string option
  ; text : string
  ; initial : Runtime_schema.memory_recall
  ; mode : mode
  ; entries : entry list
  ; picked : string list
  ; cursor : int
  ; error : string option
  }

type outcome =
  | Editing of t
  | Cancelled
  | Submitted of t

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

let open_on ?source_revision ~keepers text =
  match Runtime_toml.parse_string text with
  | Error errors ->
    Error ("runtime.toml 을 읽지 못해서 폼을 열 수 없어요 · " ^ describe_errors errors)
  | Ok config ->
    let typesafeai = config.Runtime_schema.typesafeai in
    let initial = typesafeai.Runtime_schema.memory_recall in
    let mode, picked =
      match initial with
      | Runtime_schema.Memory_recall_off -> Off, []
      | Runtime_schema.Memory_recall_on Runtime_schema.All_keepers -> All, []
      | Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers (first, rest)) ->
        Listed, without_repeats (first :: rest)
    in
    let roster = List.sort_uniq String.compare keepers in
    let entry ~known name =
      { name
      ; known
      ; excluded = List.mem name typesafeai.Runtime_schema.excluded_keepers
      }
    in
    let unknown = List.filter (fun name -> not (List.mem name roster)) picked in
    Ok
      { source_revision
      ; text
      ; initial
      ; mode
      ; entries = List.map (entry ~known:true) roster @ List.map (entry ~known:false) unknown
      ; picked
      ; cursor = 0
      ; error = None
      }
;;

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
      let picked =
        if List.mem entry.name t.picked
        then List.filter (fun name -> not (String.equal name entry.name)) t.picked
        else t.picked @ [ entry.name ]
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

let chosen t =
  match t.mode with
  | Off -> Ok Runtime_schema.Memory_recall_off
  | All -> Ok (Runtime_schema.Memory_recall_on Runtime_schema.All_keepers)
  | Listed ->
    (match t.picked with
     | [] -> Error nobody_picked
     | first :: rest ->
       Ok
         (Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers (first, rest))))
;;

(* Which keepers a list names does not depend on the order it is written in
   (the gate asks [List.mem]), so two lists are the same choice when they name
   the same keepers. Picking a keeper off and on again moves it to the end of
   [picked]; that is no change to the file. *)
let same_choice left right =
  match left, right with
  | ( Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers (left_first, left_rest))
    , Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers (right_first, right_rest))
    ) ->
    List.equal
      String.equal
      (List.sort_uniq String.compare (left_first :: left_rest))
      (List.sort_uniq String.compare (right_first :: right_rest))
  | ( ( Runtime_schema.Memory_recall_off
      | Runtime_schema.Memory_recall_on Runtime_schema.All_keepers
      | Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers _) )
    , _ ) -> Runtime_schema.equal_memory_recall left right
;;

(* Rewriting a key drops the comment on its line, so a key that already holds
   what the choice needs is left alone: the switch when the file has it on, the
   scope when it already names the same kind. Off writes the switch alone, so a
   list the file keeps stays for the next time recall is switched on by hand.
   [All] drops the list because the file refuses one next to scope "all". A
   list that does change is written whole, and the comments inside it go. *)
let write ~initial chosen text =
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
  let switch_on_in_file, scope_in_file =
    match initial with
    | Runtime_schema.Memory_recall_off -> false, None
    | Runtime_schema.Memory_recall_on Runtime_schema.All_keepers -> true, Some scope_all
    | Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers _) ->
      true, Some scope_listed
  in
  let turn_on text = if switch_on_in_file then text else set_switch true text in
  let scope_is scope text =
    if Option.equal String.equal scope_in_file (Some scope) then text else set_scope scope text
  in
  match chosen with
  | Runtime_schema.Memory_recall_off -> set_switch false text
  | Runtime_schema.Memory_recall_on Runtime_schema.All_keepers ->
    text |> turn_on |> scope_is scope_all |> set_keepers []
  | Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers (first, rest)) ->
    text |> turn_on |> scope_is scope_listed |> set_keepers (first :: rest)
;;

let text_on t =
  let refuse reason = Error { t with error = Some reason } in
  match chosen t with
  | Error reason -> refuse reason
  | Ok chosen when same_choice chosen t.initial -> Ok t.text
  | Ok chosen ->
    let edited = write ~initial:t.initial chosen t.text in
    (match Runtime_toml.parse_string edited with
     | Ok config
       when Runtime_schema.equal_memory_recall
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

let entry_suffix entry =
  (if entry.known then "" else "  (키퍼 목록에 없어요)")
  ^ if entry.excluded then "  (제외됨 · 보내지 않아요)" else ""
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
  let range_row = Printf.sprintf "  %s %s  \xe2\x80\xb9 %s \xe2\x80\xba" (mark 0) range_label (mode_label t.mode) in
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
               "    %s [%s] %s%s"
               (mark (index + 1))
               (if List.mem entry.name t.picked then "x" else " ")
               (Terminal_text.single_line entry.name)
               (entry_suffix entry))
          t.entries
      in
      let fixed =
        List.length intro_rows + 1 + List.length note_rows + List.length error_rows + 1
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
  intro_rows @ [ range_row ] @ keeper_rows @ note_rows @ error_rows @ [ "" ]
;;

module Terminal_text = Masc_tui_ansi.Terminal_text

type presence =
  | Running
  | Stopped
  | Unknown

type roster_entry =
  { name : string
  ; presence : presence
  }

(* A row of the list. [known] is false for a name the file excludes that the
   TUI's roster does not have: such a name excludes nobody, and boot only
   warns about it, so the form keeps it in the list, marked, where it can be
   dropped. *)
type entry =
  { keeper : roster_entry
  ; known : bool
  }

(* [text] is the file the form was opened on, so {!text_on} is a function of
   the form alone. [held] is the list the file holds, without repeats, in the
   order written. [picked] starts as that list and appends new picks, so a
   save that adds one Keeper moves one line of the array. [destinations] are
   the endpoints the excluded Keepers are kept from, as the file names them. *)
type t =
  { source_revision : string option
  ; text : string
  ; destinations : string list
  ; held : string list
  ; picked : string list
  ; entries : entry list
  ; cursor : int
  ; error : string option
  }

type outcome =
  | Editing of t
  | Cancelled
  | Submitted of t

type detail =
  { added : string list
  ; dropped : string list
  }

type change =
  | Unchanged
  | Changed of detail

(* The table and key [Runtime_toml.parse_string] reads the list from. The
   edited text is read back with that parser before it is returned, so a
   spelling that drifts from it is refused here and not written. *)
let table = Runtime_toml_namespace.(key Typesafeai)
let excluded_key = "excluded_keepers"
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
    let held = without_repeats typesafeai.Runtime_schema.excluded_keepers in
    let first, rest = typesafeai.Runtime_schema.destinations in
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
             (List.exists (fun (keeper : roster_entry) -> String.equal keeper.name name) roster))
        held
    in
    Ok
      { source_revision
      ; text
      ; destinations =
          List.map
            (fun (destination : Runtime_schema.typesafeai_destination) ->
               destination.Runtime_schema.endpoint)
            (first :: rest)
      ; held
      ; picked = held
      ; entries =
          List.map (fun keeper -> { keeper; known = true }) roster
          @ List.map
              (fun name -> { keeper = { name; presence = Unknown }; known = false })
              unknown
      ; cursor = 0
      ; error = None
      }
;;

let move t delta =
  { t with cursor = max 0 (min (List.length t.entries - 1) (t.cursor + delta)) }
;;

let toggle t =
  match List.nth_opt t.entries t.cursor with
  | None -> t
  | Some entry ->
    let name = entry.keeper.name in
    let picked =
      if List.mem name t.picked
      then List.filter (fun picked -> not (String.equal picked name)) t.picked
      else t.picked @ [ name ]
    in
    { t with picked; error = None }
;;

let key t key =
  match key with
  | "esc" -> Cancelled
  | "\r" | "\n" | "enter" -> Submitted t
  | "up" | "k" | "shift-tab" -> Editing (move t (-1))
  | "down" | "j" | "tab" | "\t" -> Editing (move t 1)
  | " " | "space" -> Editing (toggle t)
  | _ -> Editing t
;;

let refused t reason = { t with error = Some reason }

(* Which Keepers a list excludes does not depend on the order it is written in
   (the gates ask [List.mem]), so two lists exclude the same Keepers when they
   hold the same names. Dropping a Keeper and picking it again moves it to the
   end of [picked]; that is no change to the file. *)
let same_names left right =
  List.equal
    String.equal
    (List.sort_uniq String.compare left)
    (List.sort_uniq String.compare right)
;;

let change t =
  if same_names t.picked t.held
  then Unchanged
  else (
    let picked = without_repeats t.picked in
    Changed
      { added = List.filter (fun name -> not (List.mem name t.held)) picked
      ; dropped = List.filter (fun name -> not (List.mem name picked)) t.held
      })
;;

let unchangeable =
  "[typesafeai] 가 폼으로 고칠 수 있는 모양이 아니에요. e 로 파일을 직접 고쳐 주세요."
;;

(* Nobody picked removes the key: a file without it excludes nobody, which is
   what the reader gives it, and an empty array would only add a line. A list
   that changes is written whole, and the comments inside it go. *)
let write names text =
  match names with
  | [] -> Toml_line_editor.edit_table_scalar text ~path:table ~key:excluded_key ~value:None
  | names ->
    Toml_line_editor.edit_table_multiline_array
      text
      ~path:table
      ~key:excluded_key
      ~values:names
;;

(* The read-back asks [same_names], as the decision above does: the file may
   hold the chosen names in another order, and the gates read that as the same
   list. *)
let text_on t =
  match change t with
  | Unchanged -> Ok t.text
  | Changed _ ->
    let refuse reason = Error { t with error = Some reason } in
    let picked = without_repeats t.picked in
    let edited = write picked t.text in
    (match Runtime_toml.parse_string edited with
     | Ok config
       when same_names config.Runtime_schema.typesafeai.Runtime_schema.excluded_keepers picked
       -> Ok edited
     | Ok _ -> refuse unchangeable
     | Error errors -> refuse ("고친 결과를 읽지 못했어요 · " ^ describe_errors errors))
;;

let intro = "판정 서버 제외 · 고른 키퍼의 글·기억·맥락은 판정 서버에 보내지 않아요"

(* An excluded Keeper is not asked about at any [typesafeai] gate, but its
   Board candidates are still judged: the exact lane takes them
   ([Keeper_board_attention_exact_flow]), and whatever model its slots name
   receives the post. The form says so, because "excluded" reads as "stays
   here". *)
let board_note =
  "제외해도 Board 판정은 board_attention_exact 슬롯이 해요. 글은 그 슬롯의 모델로 가요."
;;

let applies_note = "저장하면 서버가 바로 읽어요."
let no_roster = "(키퍼 목록이 비어 있어요)"
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

let destinations_text t = "판정 서버 · " ^ String.concat " · " t.destinations

(* An unknown name that is still picked is the one to act on: it excludes
   nobody and stays in the file until it is dropped. *)
let entry_suffix t entry =
  (if entry.known
   then ""
   else if List.mem entry.keeper.name t.picked
   then "  (키퍼 목록에 없어요 · Space 로 빼요)"
   else "  (키퍼 목록에 없어요)")
  ^
  match entry.keeper.presence with
  | Stopped -> "  (멈춰 있어요)"
  | Running | Unknown -> ""
;;

(* The first few names, then how many more: a list of forty Keepers is not a
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
  | Changed { added; dropped } ->
    let names sign = function
      | [] -> []
      | names -> [ sign ^ names_text names ]
    in
    String.concat " · " (names "+" added @ names "-" dropped)
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
  let destination_rows = wrapped ~width ~lead:hint_lead (destinations_text t) in
  let summary_rows = wrapped ~width ~lead:hint_lead ("저장하면 · " ^ summary_text t) in
  let note_rows =
    wrapped ~width ~lead:hint_lead board_note @ wrapped ~width ~lead:hint_lead applies_note
  in
  let error_rows =
    match t.error with
    | None -> []
    | Some reason -> wrapped ~width ~lead:refusal_lead reason
  in
  let keeper_rows =
    match t.entries with
    | [] -> wrapped ~width ~lead:hint_lead no_roster
    | entries ->
      let drawn =
        List.mapi
          (fun index entry ->
             Printf.sprintf
               "    %s [%s] %s%s"
               (mark index)
               (if List.mem entry.keeper.name t.picked then "x" else " ")
               (Terminal_text.single_line entry.keeper.name)
               (entry_suffix t entry))
          entries
      in
      let fixed =
        List.length intro_rows
        + List.length destination_rows
        + List.length summary_rows
        + List.length note_rows
        + List.length error_rows
        + 1
      in
      let visible, above, below = window ~room:(max 1 (height - fixed)) ~cursor:t.cursor drawn in
      if above = 0 && below = 0
      then visible
      else
        visible
        @ [ Printf.sprintf "      … 위 %d명 · 아래 %d명 (↑/↓ 로 움직여요)" above below ]
  in
  intro_rows
  @ destination_rows
  @ keeper_rows
  @ summary_rows
  @ note_rows
  @ error_rows
  @ [ "" ]
;;

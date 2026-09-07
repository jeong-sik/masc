module Acting = Masc_tui_acting
module Layout = Masc_tui_message_layout
module Reading = Masc.Tui_decode

(* ── Width ───────────────────────────────────────────────────────────────

   The pane is a column of fleet rows. A row is a border cell, the health
   mark and its gap, a name, a gap, and the reading. Sixteen name cells keep
   the configured names whole that the roster's window keeps whole. The
   reading's budget holds the event clock and its count authority:
   [~ network_read · 3 seen · evt 12.4s] and
   [■ 5 total · 38.2k tok · evt 41.0s] fit without widening the pane. *)
let border_cells = 1
let mark_cells = 2
let name_cells = 16
let gap_cells = 1
let reading_cells = 36
let pane_cols = border_cells + mark_cells + name_cells + gap_cells + reading_cells

(* What the roster pane leaves a surface is the least a surface lays out
   against anywhere in the TUI. Sharing that floor means a screen wide
   enough for both panes gives the surface no less than the roster alone. *)
let surface_floor_cols =
  Masc_tui_roster_pane.threshold_cols - Masc_tui_roster_pane.pane_cols

let threshold_cols = pane_cols + surface_floor_cols
let shown ~hidden ~cols = (not hidden) && cols >= threshold_cols

let toggle_hidden ~hidden ~cols =
  if cols < threshold_cols then None else Some (not hidden)

let content_cols ~hidden ~cols =
  if shown ~hidden ~cols then cols - pane_cols else cols

(* ── Input ─────────────────────────────────────────────────────────────── *)

type tab =
  | Tab_fleet
  | Tab_changes

let tab_label = function
  | Tab_fleet -> "Recent"
  | Tab_changes -> "Changes"

let next_tab = function
  | Tab_fleet -> Tab_changes
  | Tab_changes -> Tab_fleet

type feed =
  | Feed_off
  | Feed_opening
  | Feed_live of int
  | Feed_closed of string

type keeper = {
  name : string;
  mark : string;
  mark_tone : tone;
  health : Reading.keeper_health_reading option;
}

and tone =
  | Plain
  | Dim
  | Accent
  | Ok
  | Warn
  | Bad
  | Info

type approval = {
  approval_keeper : string;
  approval_tool : string;
}

type file_kind =
  | File_edited
  | File_written

type file_row = {
  file_path : string;
  file_kind : file_kind;
  file_succeeded : bool;
  file_at : float;
  file_where : string option;
}

type changes =
  | Changes_absent
  | Changes_loading
  | Changes_failed of string
  | Changes_ready of {
      keeper : string;
      files : file_row list;
      fetched_at : float;
      window_hours : float;
      calls : int;
      over_budget : int;
      malformed : int;
    }

type input = {
  now : float;
  tab : tab;
  feed : feed;
  keepers : keeper list;
  selected : string option;
  approvals : approval list;
  chunks : Acting.chunk list;
  changes : changes;
}

type span = {
  text : string;
  tone : tone;
}

type line = span list

type row_target =
  | Target_none
  | Target_next_tab
  | Target_keeper of string
  | Target_more
  | Target_file of int

type rendering = {
  rows : line list;
  targets : row_target list;
  scroll_max : int;
}

(* ── Text ──────────────────────────────────────────────────────────────── *)

let middle_dot = " \xc2\xb7 "
let open_record_glyph = "~"
let settled_glyph = Acting.glyph_text Acting.Turn_settled
let attention_glyph = Acting.glyph_text Acting.Attention
let quiet_glyph = Acting.glyph_text Acting.Quiet
let rule_glyph = "\xe2\x94\x80"
let ellipsis = "\xe2\x80\xa6"
let up_arrow = "\xe2\x86\x91"
let down_arrow = "\xe2\x86\x93"

(* The change kinds are one ASCII cell each: the Changes tab draws in a
   column beside a surface that may already hold wide glyphs, and an
   ambiguous-width mark there would shift every row after it on a terminal
   that draws such marks two cells wide. *)
let edited_glyph = "~"
let written_glyph = "+"
let failed_glyph = "!"

let age_text ~now at = Acting.elapsed_text (Float.max 0. (now -. at) *. 1000.)
let event_age_text ~now at = "evt " ^ age_text ~now at

let compact_count n =
  let thousand = 1_000 and million = 1_000_000 in
  if n >= million then Printf.sprintf "%.1fM" (float_of_int n /. float_of_int million)
  else if n >= thousand then
    Printf.sprintf "%.1fk" (float_of_int n /. float_of_int thousand)
  else string_of_int n

let tokens_text = function
  | None, None -> ""
  | Some i, Some o -> compact_count (i + o) ^ " tok"
  | Some n, None | None, Some n -> compact_count n ^ " tok"

let plural n word = Printf.sprintf "%d %s%s" n word (if n = 1 then "" else "s")
let calls_text n = plural n "call"
let files_text n = plural n "file"
let more_text n = Printf.sprintf "%d more" n
let window_text hours = Printf.sprintf "%gh" hours

let cost_text = function
  | Some usd -> Printf.sprintf "$%.4f" usd
  | None -> ""

let join parts = String.concat middle_dot (List.filter (fun s -> s <> "") parts)

(* The most recently observed tool, not a statement that it is still running. *)
let latest_tool (chunk : Acting.chunk) =
  match List.rev (Acting.chunk_tools chunk) with
  | tool :: _ -> Some tool.Acting.ct_tool
  | [] -> None

(* A settle reports the whole turn's count. An open record only knows the
   calls this feed observed, which may start mid-turn or have lost rows. *)
let chunk_calls_text (chunk : Acting.chunk) =
  if chunk.Acting.ck_settled then
    match chunk.Acting.ck_calls with
    | Some count -> Printf.sprintf "%d total" count
    | None -> "total ?"
  else Printf.sprintf "%d seen" (List.length (Acting.chunk_tools chunk))

type record_state = Record_open | Record_unfinished | Record_settled

(* Window logical rows before formatting text or measuring display cells. These
   descriptors live for one frame; presentation still uses that frame's input. *)
type direction = Above | Below

type logical_row =
  | Fleet_row of keeper * Acting.chunk option
  | Focus_header of string * Acting.chunk option * Reading.keeper_health_reading option
  | Approval_row of string
  | Tool_row of Acting.chunk * Acting.chunk_tool * record_state
  | Earlier_turn of Acting.chunk * Reading.keeper_health_reading option
  | Rule
  | More of int
  | Indicator of direction * int
  | File_row of int * file_row
  | Formatted_status of line * row_target

let record_state ~health (chunk : Acting.chunk) =
  if chunk.Acting.ck_settled then Record_settled
  else
    match health with
    | Some Reading.Health_offline | Some Reading.Health_zombie -> Record_unfinished
    | Some (Reading.Health_running | Reading.Health_idle | Reading.Health_stale
           | Reading.Health_degraded) | None -> Record_open

let record_label = function
  | Record_open -> ("open/gap", Dim)
  | Record_unfinished -> ("unfinished", Warn)
  | Record_settled -> ("settled", Dim)

let unfinished_glyph = "!"

let keeper_state_text ~now ~health ~approval (chunk : Acting.chunk option) =
  match approval, chunk with
  | Some tool, _ ->
      [ { text = attention_glyph ^ " "; tone = Warn }
      ; { text = join [ "approval"; tool ]; tone = Warn }
      ]
  | None, Some chunk ->
      let state = record_state ~health chunk in
      let glyph, detail, tone =
        match state with
        | Record_open ->
          (open_record_glyph,
           join [ Option.value ~default:"open/gap" (latest_tool chunk); chunk_calls_text chunk ], Dim)
        | Record_unfinished ->
          (unfinished_glyph, join [ "unfinished"; chunk_calls_text chunk ], Warn)
        | Record_settled ->
          (settled_glyph, join [ chunk_calls_text chunk; tokens_text chunk.Acting.ck_tokens ], Dim)
      in
      [ { text = glyph ^ " "; tone }
      ; { text = detail; tone = (if state = Record_unfinished then Warn else Plain) }
      ; { text = middle_dot ^ event_age_text ~now chunk.Acting.ck_at; tone = Dim }
      ]
  | None, None -> [ { text = quiet_glyph ^ " no events"; tone = Dim } ]

(* ── Lines ─────────────────────────────────────────────────────────────── *)

(* Exactly [cols] cells: cut the spans that overflow, pad what falls short.
   Retained spans keep their measured cells; only a clipped span is remeasured. *)
let fit_line ~cols spans =
  let rec cut used acc = function
    | [] -> List.rev acc, used
    | span :: rest ->
        let cells = Layout.display_width span.text in
        if used + cells <= cols then cut (used + cells) (span :: acc) rest
        else
          let room = cols - used in
          if room <= 0 then List.rev acc, used
          else
            let text = Layout.take_cells span.text room in
            List.rev ({ span with text } :: acc), used + Layout.display_width text
  in
  let spans, used = cut 0 [] spans in
  let short = cols - used in
  if short > 0 then spans @ [ { text = String.make short ' '; tone = Plain } ]
  else spans

let blank_line ~cols = fit_line ~cols []
let border = { text = "\xe2\x94\x82"; tone = Dim }
let with_border spans = border :: spans

let rule_line ~cols =
  let cells = max 0 (cols - border_cells) in
  fit_line ~cols
    [ border
    ; { text = String.concat "" (List.init cells (fun _ -> rule_glyph)); tone = Dim }
    ]

(* The tab that is up wears brackets and the accent; the other recedes so
   the header still reads as one line. *)
let tab_pill ~active tab =
  if active then { text = "[" ^ tab_label tab ^ "]"; tone = Accent }
  else { text = tab_label tab; tone = Dim }

let header_line ~cols input =
  let keepers = List.length input.keepers in
  let feed =
    match input.feed with
    | Feed_off -> { text = "no feed"; tone = Dim }
    | Feed_opening -> { text = "feed opening"; tone = Dim }
    | Feed_live _ -> { text = "feed live"; tone = Ok }
    | Feed_closed reason -> { text = "feed closed: " ^ reason; tone = Bad }
  in
  fit_line ~cols
    (with_border
       [ tab_pill ~active:(input.tab = Tab_fleet) Tab_fleet
       ; { text = " "; tone = Plain }
       ; tab_pill ~active:(input.tab = Tab_changes) Tab_changes
       ; { text = Printf.sprintf "%s%s%s" middle_dot (plural keepers "keeper") middle_dot
         ; tone = Dim
         }
       ; feed
       ])

(* Newest chunk per keeper: the fold returns chunks newest-activity first,
   so the first one met for a keeper is its latest observed record. *)
let newest_chunk_by_keeper chunks =
  let table = Hashtbl.create 16 in
  List.iter
    (fun (chunk : Acting.chunk) ->
      if not (Hashtbl.mem table chunk.Acting.ck_keeper) then
        Hashtbl.replace table chunk.Acting.ck_keeper chunk)
    chunks;
  table

let approval_for approvals name =
  List.find_map
    (fun approval ->
      if String.equal approval.approval_keeper name then Some approval.approval_tool
      else None)
    approvals

(* Pending approvals rank first, then unclosed records before settled ones,
   each by receipt time. The order does not assert current owner-turn state.
   Keepers without observed activity retain the roster's own order. *)
let fleet_order input newest =
  let rank keeper =
    match approval_for input.approvals keeper.name, Hashtbl.find_opt newest keeper.name with
    | Some _, _ -> (0, 0.)
    | None, Some (chunk : Acting.chunk) when not chunk.Acting.ck_settled -> (1, -. chunk.Acting.ck_at)
    | None, Some chunk -> (2, -. chunk.Acting.ck_at)
    | None, None -> (3, 0.)
  in
  List.stable_sort (fun a b -> compare (rank a) (rank b)) input.keepers

let fleet_row ~cols input keeper chunk =
  let approval = approval_for input.approvals keeper.name in
  let selected =
    match input.selected with
    | Some name -> String.equal name keeper.name
    | None -> false
  in
  ( fit_line ~cols
      (with_border
         ([ { text = Layout.fit_width keeper.mark mark_cells; tone = keeper.mark_tone }
          ; { text = Layout.fit_middle name_cells keeper.name
            ; tone = (if selected then Accent else Plain)
            }
          ; { text = String.make gap_cells ' '; tone = Plain }
          ]
          @ keeper_state_text ~now:input.now ~health:keeper.health ~approval chunk))
  , Target_keeper keeper.name )

let more_line ~cols n =
  ( fit_line ~cols
      (with_border [ { text = ellipsis ^ " " ^ more_text n; tone = Dim } ])
  , Target_more )

let indicator_line ~cols arrow n =
  ( fit_line ~cols (with_border [ { text = arrow ^ " " ^ more_text n; tone = Dim } ])
  , Target_none )

(* The focus block: the selected keeper's newest feed record, call by call,
   then the records before it. *)
let focus_keeper input newest =
  match input.selected with
  | Some name -> Some name
  | None ->
      (* No cursor: the keeper that acted last. *)
      Hashtbl.fold
        (fun name (chunk : Acting.chunk) acc ->
          match acc with
          | Some (_, at) when at >= chunk.Acting.ck_at -> acc
          | Some _ | None -> Some (name, chunk.Acting.ck_at))
        newest None
      |> Option.map fst

let health_of input name =
  match List.find_opt (fun keeper -> String.equal keeper.name name) input.keepers with
  | Some keeper -> keeper.health
  | None -> None

let tool_line ~cols ~state (chunk : Acting.chunk) (tool : Acting.chunk_tool) =
  let duration =
    match tool.Acting.ct_duration_ms with
    | Some ms -> { text = Acting.elapsed_text ms; tone = Dim }
    (* The feed does not carry a receipt clock for each folded tool. Its
       unknown duration stays blank; the record header owns the event age. *)
    | None -> { text = ""; tone = Dim }
  in
  let glyph =
    if (not chunk.Acting.ck_settled) && Option.is_none tool.Acting.ct_duration_ms
    then
      (match state with
       | Record_unfinished -> { text = unfinished_glyph ^ " "; tone = Warn }
       | Record_open | Record_settled -> { text = open_record_glyph ^ " "; tone = Dim })
    else { text = settled_glyph ^ " "; tone = Dim }
  in
  let inner = cols - border_cells - mark_cells in
  let right = Layout.display_width duration.text in
  let name_room = max 0 (inner - right - (if right > 0 then gap_cells else 0)) in
  fit_line ~cols
    (with_border
       [ glyph
       ; { text = Layout.fit_width tool.Acting.ct_tool name_room; tone = Plain }
       ; { text = (if right > 0 then String.make gap_cells ' ' else ""); tone = Plain }
       ; duration
       ])

(* The turn number a settle confirmed is the keeper's own count. An
   unsettled chunk still carries the agent session's numbering, which the
   viewer does not trust: a session restart renumbers from zero, so the
   same turn once drew as 1740 on the header and 3084 on the summary
   (live capture 2026-09-06). A settle that carried no number settles the
   chunk without naming it, and [turn_text] would draw that as [turn ?] --
   a question the row cannot answer and the reader cannot act on (live
   capture 2026-09-06). Only a number the settle confirmed becomes a
   name. *)
let turn_name (chunk : Acting.chunk) =
  match chunk.Acting.ck_turn with
  | Some _ when chunk.Acting.ck_settled -> Some (Acting.turn_text chunk.Acting.ck_turn)
  | _ -> None

let turn_summary_line ~cols ~now ~health (chunk : Acting.chunk) =
  let named =
    match turn_name chunk with
    | Some text -> [ { text; tone = Plain } ]
    | None -> []
  in
  let prefix =
    match record_state ~health chunk with
    | Record_settled -> { text = settled_glyph ^ " "; tone = Dim }
    | Record_open -> { text = open_record_glyph ^ " open/gap"; tone = Dim }
    | Record_unfinished -> { text = unfinished_glyph ^ " unfinished"; tone = Warn }
  in
  fit_line ~cols
    (with_border
       ( [ prefix ]
       @ named
       @ [ { text =
               middle_dot
               ^ join
                   [ chunk_calls_text chunk
                   ; tokens_text chunk.Acting.ck_tokens
                   ; cost_text chunk.Acting.ck_cost_usd
                   ]
           ; tone = Dim
           }
         ; { text = middle_dot ^ event_age_text ~now chunk.Acting.ck_at; tone = Dim }
         ] ))

let focus_header_line ~cols ~now ~health name current =
  match current with
  | Some (current : Acting.chunk) ->
      let state_word, state_tone = record_label (record_state ~health current) in
      let named =
        match turn_name current with
        | Some text -> [ { text = middle_dot ^ text; tone = Plain } ]
        | None -> []
      in
      fit_line ~cols
        (with_border
           ( { text = name; tone = Accent }
           :: named
           @ [ { text = middle_dot ^ state_word; tone = state_tone }
             ; { text = middle_dot ^ event_age_text ~now current.Acting.ck_at; tone = Dim }
             ] ))
  | None ->
      fit_line ~cols
        (with_border
           [ { text = name; tone = Accent }
           ; { text = middle_dot ^ "no events on this feed yet"; tone = Dim }
           ])

let approval_line ~cols tool =
  fit_line ~cols
    (with_border
       [ { text = attention_glyph ^ " "; tone = Warn }
       ; { text = "waiting on approval" ^ middle_dot ^ tool; tone = Warn }
       ])

(* Every logical focus row, oldest call first, then the earlier turns. No
   text is formatted until the caller selects the visible window. *)
let focus_rows input chunks name =
  let own =
    List.filter (fun (c : Acting.chunk) -> String.equal c.Acting.ck_keeper name) chunks
  in
  let health = health_of input name in
  let current = match own with current :: _ -> Some current | [] -> None in
  let approval =
    match approval_for input.approvals name with
    | Some tool -> [ Approval_row tool ]
    | None -> []
  in
  let body =
    match own with
    | [] -> []
    | current :: earlier ->
        let state = record_state ~health current in
        let calls =
          List.map (fun tool -> Tool_row (current, tool, state)) (Acting.chunk_tools current)
        in
        (* A call-less record draws no body row: the header already states
           the observation state and its receipt age. *)
        calls @ List.map (fun chunk -> Earlier_turn (chunk, health)) earlier
  in
  Focus_header (name, current, health) :: approval @ body

(* The least each block needs before the two share the rows: the fleet one
   keeper and its fold line, the focus its rule and one row. Below that the
   fleet keeps every row it can use and the focus block waits for a taller
   terminal. *)
let fleet_min_rows = 2
let focus_min_rows = 2

(* The overview: the fleet folded to at most half the rows, the focus block
   after a rule. What the fleet tab opens on. *)
let overview_rows ~below fleet_rows focus focus_rows =
  let fleet_count = List.length fleet_rows in
  let fleet_budget =
    match focus with
    | Some _ when below >= fleet_min_rows + focus_min_rows ->
        min fleet_count (below / 2)
    | Some _ | None -> min fleet_count below
  in
  let fleet =
    if fleet_count > fleet_budget && fleet_budget >= 2 then
      List.filteri (fun index _ -> index < fleet_budget - 1) fleet_rows
      @ [ More (fleet_count - (fleet_budget - 1)) ]
    else
      List.filteri (fun index _ -> index < fleet_budget) fleet_rows
  in
  let after_fleet = below - List.length fleet in
  let focus_block =
    match focus with
    | Some _ when after_fleet >= focus_min_rows ->
        Rule
        :: List.filteri (fun index _ -> index < after_fleet - 1) focus_rows
    | Some _ | None -> []
  in
  fleet @ focus_block

(* The full list from [scroll], one row of it given to each indicator. The
   top indicator always draws once scrolled: it is how the reader knows the
   header is not the first row. The bottom one draws only when content is
   still hidden, and the row it takes counts as hidden too. *)
let scrolled_rows ~below ~scroll body =
  let total = List.length body in
  let room = below - 1 in
  let slice = List.filteri (fun index _ -> index >= scroll && index < scroll + room) body in
  let hidden_below = total - (scroll + room) in
  let slice =
    if hidden_below > 0 && room >= 2 then
      List.filteri (fun index _ -> index < room - 1) slice
      @ [ Indicator (Below, hidden_below + 1) ]
    else slice
  in
  Indicator (Above, scroll) :: slice

(* The top of a list that overflows, the last row given to the bottom
   indicator. What the changes tab opens on: its rows are all alike, so
   there is nothing to fold. *)
let folded_rows ~below body =
  let total = List.length body in
  let room = max 0 (below - 1) in
  List.filteri (fun index _ -> index < room) body
  @ [ Indicator (Below, total - room) ]

(* [body] windowed to [below] rows: whole when it fits, [overview] at the
   top, the scrolled slice anywhere else. At the largest scroll the last row
   is on screen under the top indicator alone; one row of the window belongs
   to that indicator. *)
let window ~below ~scroll ~overview body =
  let total = List.length body in
  if below <= 0 then ([], 0)
  else if below = 1 then
    (* A one-row window must still show actionable content. Indicators would
       consume its only row and make scrolling unable to reach any target. *)
    let scroll_max = max 0 (total - 1) in
    let scroll = max 0 (min scroll scroll_max) in
    (List.filteri (fun index _ -> index = scroll) body, scroll_max)
  else
    let scroll_max = if total <= below then 0 else max 0 (total - (below - 1)) in
    let scroll = max 0 (min scroll scroll_max) in
    let drawn =
      if total <= below then body
      else if scroll = 0 then overview ()
      else scrolled_rows ~below ~scroll body
    in
    (drawn, scroll_max)

let fleet_lines ~below ~scroll input =
  let chunks = input.chunks in
  let newest = newest_chunk_by_keeper chunks in
  let focus = focus_keeper input newest in
  let ordered = fleet_order input newest in
  let focus_rows =
    match focus with
    | Some name -> focus_rows input chunks name
    | None -> []
  in
  (* The full list: every fleet row, then the rule and the focus block when
     there is one. Scrolling walks this; the overview folds it. *)
  let fleet_rows =
    List.map (fun keeper -> Fleet_row (keeper, Hashtbl.find_opt newest keeper.name)) ordered
  in
  let body =
    fleet_rows
    @ (match focus_rows with
       | [] -> []
       | _ :: _ -> Rule :: focus_rows)
  in
  window ~below ~scroll body ~overview:(fun () ->
    overview_rows ~below fleet_rows focus focus_rows)

(* ── Changes tab ───────────────────────────────────────────────────────── *)

let file_glyph file =
  if not file.file_succeeded then { text = failed_glyph ^ " "; tone = Bad }
  else
    match file.file_kind with
    | File_edited -> { text = edited_glyph ^ " "; tone = Info }
    | File_written -> { text = written_glyph ^ " "; tone = Ok }

(* One file: its kind, the address cut in the middle so the file name and
   the repository both stay readable, the range when known, the age. *)
let file_line ~cols ~now index file =
  let age = { text = age_text ~now file.file_at ^ " ago"; tone = Dim } in
  let where = Option.value ~default:"" file.file_where in
  let inner = cols - border_cells - mark_cells in
  let right = Layout.display_width age.text in
  let where_cells = Layout.display_width where in
  let path_room =
    max 0
      (inner - right - gap_cells
       - (if where_cells > 0 then where_cells + gap_cells else 0))
  in
  ( fit_line ~cols
      (with_border
         [ file_glyph file
         ; { text = Layout.fit_middle path_room file.file_path
           ; tone = (if file.file_succeeded then Plain else Bad)
           }
         ; { text = (if where_cells > 0 then String.make gap_cells ' ' ^ where else "")
           ; tone = Dim
           }
         ; { text = String.make gap_cells ' '; tone = Plain }
         ; age
         ])
  , Target_file index )

let changes_status_lines ~cols input =
  let one spans = [ (fit_line ~cols (with_border spans), Target_none) ] in
  let named name spans = one ({ text = name; tone = Accent } :: spans) in
  match input.selected, input.changes with
  | None, _ -> one [ { text = "no keeper selected"; tone = Dim } ]
  | Some name, Changes_absent ->
      named name [ { text = middle_dot ^ "changes not fetched"; tone = Dim } ]
  | Some name, Changes_loading -> named name [ { text = middle_dot ^ "loading"; tone = Dim } ]
  | Some name, Changes_failed why ->
      named name [ { text = middle_dot ^ "failed" ^ middle_dot ^ why; tone = Bad } ]
  | Some _, Changes_ready r ->
      let files = List.length r.files in
      let head =
        named r.keeper
          [ { text =
                middle_dot
                ^ join
                    [ files_text files
                    ; window_text r.window_hours
                    ; age_text ~now:input.now r.fetched_at ^ " ago"
                    ]
            ; tone = Dim
            }
          ]
      in
      let dropped =
        if r.over_budget + r.malformed > 0 then
          one
            [ { text =
                  join
                    [ (if r.over_budget > 0 then
                         Printf.sprintf "%d without text" r.over_budget
                       else "")
                    ; (if r.malformed > 0 then Printf.sprintf "%d malformed" r.malformed
                       else "")
                    ]
              ; tone = Warn
              }
            ]
        else []
      in
      let empty =
        if files = 0 then
          one [ { text = "no writes in " ^ calls_text r.calls; tone = Dim } ]
        else []
      in
      head @ dropped @ empty

let changes_lines ~cols ~below ~scroll input =
  let files =
    match input.changes with
    | Changes_ready r -> List.mapi (fun index file -> File_row (index, file)) r.files
    | Changes_absent | Changes_loading | Changes_failed _ -> []
  in
  let status =
    List.map (fun (line, target) -> Formatted_status (line, target))
      (changes_status_lines ~cols input)
  in
  let body = status @ files in
  window ~below ~scroll body ~overview:(fun () -> folded_rows ~below body)

let materialize_row ~cols input = function
  | Fleet_row (keeper, chunk) -> fleet_row ~cols input keeper chunk
  | Focus_header (name, current, health) ->
      focus_header_line ~cols ~now:input.now ~health name current, Target_none
  | Approval_row tool -> approval_line ~cols tool, Target_none
  | Tool_row (chunk, tool, state) -> tool_line ~cols ~state chunk tool, Target_none
  | Earlier_turn (chunk, health) ->
      turn_summary_line ~cols ~now:input.now ~health chunk, Target_none
  | Rule -> rule_line ~cols, Target_none
  | More n -> more_line ~cols n
  | Indicator (direction, n) ->
      let arrow = match direction with Above -> up_arrow | Below -> down_arrow in
      indicator_line ~cols arrow n
  | File_row (index, file) -> file_line ~cols ~now:input.now index file
  | Formatted_status (line, target) -> line, target

let lines ~rows ~cols ~scroll input =
  let rows = max 0 rows in
  if rows = 0 then { rows = []; targets = []; scroll_max = 0 }
  else
    let header = (header_line ~cols input, Target_next_tab) in
    let headers =
      match input.tab with
      | Tab_fleet when rows >= 2 ->
        [ header
        ; (fit_line ~cols
             (with_border [ { text = "evt=since receipt · seen/total=tool calls"; tone = Dim } ]),
           Target_none)
        ]
      | Tab_fleet | Tab_changes -> [ header ]
    in
    let below = rows - List.length headers in
    let visible, scroll_max =
      if below <= 0 then [], 0
      else
        match input.tab with
        | Tab_fleet -> fleet_lines ~below ~scroll input
        | Tab_changes -> changes_lines ~cols ~below ~scroll input
    in
    let drawn = headers @ List.map (materialize_row ~cols input) visible in
    let padding =
      List.init (max 0 (rows - List.length drawn)) (fun _ -> (blank_line ~cols, Target_none))
    in
    let drawn = List.filteri (fun index _ -> index < rows) (drawn @ padding) in
    { rows = List.map fst drawn; targets = List.map snd drawn; scroll_max }

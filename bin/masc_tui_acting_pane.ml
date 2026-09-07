module Acting = Masc_tui_acting
module Layout = Masc_tui_message_layout
module Reading = Masc.Tui_decode

(* ── Width ───────────────────────────────────────────────────────────────

   The pane is a column of fleet rows. A row is a border cell, the health
   mark and its gap, a name, a gap, and the reading. Sixteen name cells keep
   the configured names whole that the roster's window keeps whole. The
   reading's budget is set by the longest reading a row states in full:
   [▶ network_read · 3 calls · 12.4s ago] is 36 cells, and a settled
   [■ 5 calls · 38.2k tok · 41.0s ago] or a waiting [? approval ·
   tool_execute] fits inside it. A budget of 24 cut the tool name off every
   waiting row and the age off every settled one, and a budget of 32 cut
   the [ago] off the settled rows (2026-09-06). *)
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
  | Tab_fleet -> "Fleet"
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
  trace_id : string;
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
  entries : Acting.entry list;
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
let running_glyph = Acting.glyph_text Acting.Call_started
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

(* The tool a running turn is on: the newest call, from the ledger when it
   reported, else the wire. *)
let current_tool (chunk : Acting.chunk) =
  match List.rev (Acting.chunk_tools chunk) with
  | tool :: _ -> Some tool.Acting.ct_tool
  | [] -> None

(* A settled turn's count is the one its settle confirmed -- the server's
   own count of the whole turn, where the list is only what this feed saw,
   and the feed can open mid-turn or drop the oldest rows.

   This started as a workaround for something else: ledger rows carried no
   turn number, landed on whatever chunk was newest, and a settled row read
   2449 calls for a turn of one call (live capture 2026-09-06). Reading the
   settle's number hid that. The rows now state their turn and are keyed on
   it ([Acting.ck_session_turn]), so the list is no longer a running total
   and this is a preference between two honest counts rather than a way
   around a wrong one.

   Before a settle there is no confirmed count, so the open turn counts its
   list. *)
let chunk_call_count (chunk : Acting.chunk) =
  if chunk.Acting.ck_settled then Option.value ~default:0 chunk.Acting.ck_calls
  else
    match Acting.chunk_tools chunk with
    | [] -> Option.value ~default:0 chunk.Acting.ck_calls
    | tools -> List.length tools

(* An unsettled chunk means the feed never saw the turn end. A keeper whose
   process is gone can never send that end, so for [Health_offline] and
   [Health_zombie] the row states what is known — the turn is unfinished —
   instead of an in-flight word that reads as progress beside the gone mark.
   No health reading ([None]) keeps the turn's own claim. *)
let keeper_can_finish = function
  | Some Reading.Health_offline | Some Reading.Health_zombie -> false
  | Some _ | None -> true

let unfinished_glyph = "!"

(* Vocabulary: the word "running" names the keeper's process phase and
   nothing else. An in-flight turn is "in turn" on the fleet row and on the
   focus header — one word per fact, and once per block: the calls under
   the header name what they were doing and since when, not the state the
   header above them already states. *)
let keeper_state_text ~now ~health ~approval (chunk : Acting.chunk option) =
  match approval, chunk with
  | Some tool, _ ->
      [ { text = attention_glyph ^ " "; tone = Warn }
      ; { text = join [ "approval"; tool ]; tone = Warn }
      ]
  | None, Some chunk when not chunk.Acting.ck_settled && keeper_can_finish health ->
      let calls = chunk_call_count chunk in
      let on =
        match current_tool chunk with
        | Some tool -> tool
        | None -> "in turn"
      in
      [ { text = running_glyph ^ " "; tone = Ok }
      ; { text = join [ on; (if calls > 0 then calls_text calls else "") ]; tone = Plain }
      ; { text = middle_dot ^ age_text ~now chunk.Acting.ck_at ^ " ago"; tone = Dim }
      ]
  | None, Some chunk when not chunk.Acting.ck_settled ->
      [ { text = unfinished_glyph ^ " "; tone = Warn }
      ; { text = "unfinished"; tone = Warn }
      ; { text = middle_dot ^ age_text ~now chunk.Acting.ck_at ^ " ago"; tone = Dim }
      ]
  | None, Some chunk ->
      [ { text = settled_glyph ^ " "; tone = Dim }
      ; { text =
            join
              [ calls_text (chunk_call_count chunk)
              ; tokens_text chunk.Acting.ck_tokens
              ]
        ; tone = Plain
        }
      ; { text = middle_dot ^ age_text ~now chunk.Acting.ck_at ^ " ago"; tone = Dim }
      ]
  | None, None -> [ { text = quiet_glyph ^ " quiet"; tone = Dim } ]

(* ── Lines ─────────────────────────────────────────────────────────────── *)

let width spans =
  List.fold_left (fun acc span -> acc + Layout.display_width span.text) 0 spans

(* Exactly [cols] cells: cut the spans that overflow, pad what falls short.
   A span cut to nothing is dropped so a tone does not open on empty text. *)
let fit_line ~cols spans =
  let rec cut used acc = function
    | [] -> List.rev acc
    | span :: rest ->
        let cells = Layout.display_width span.text in
        if used + cells <= cols then cut (used + cells) (span :: acc) rest
        else
          let room = cols - used in
          if room <= 0 then List.rev acc
          else List.rev ({ span with text = Layout.take_cells span.text room } :: acc)
  in
  let spans = cut 0 [] spans in
  let short = cols - width spans in
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
    | Feed_live events ->
        { text = Printf.sprintf "live%s%s events" middle_dot (compact_count events); tone = Ok }
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
   so the first one met for a keeper is its current or latest turn. *)
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

(* Who acted last comes first. A keeper waiting on an approval outranks a
   working one: it is the row the reader can do something about. Keepers the
   feed has not shown acting sit at the bottom in the roster's own order. *)
let fleet_order input newest =
  let rank keeper =
    match approval_for input.approvals keeper.name, Hashtbl.find_opt newest keeper.name with
    | Some _, _ -> (0, 0.)
    | None, Some (chunk : Acting.chunk) when not chunk.Acting.ck_settled -> (1, -. chunk.Acting.ck_at)
    | None, Some chunk -> (2, -. chunk.Acting.ck_at)
    | None, None -> (3, 0.)
  in
  List.stable_sort (fun a b -> compare (rank a) (rank b)) input.keepers

let fleet_row ~cols input newest keeper =
  let chunk = Hashtbl.find_opt newest keeper.name in
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

(* The focus block: the selected keeper's current turn, call by call, then
   the turns before it. *)
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

let tool_line ~cols ~now ~can_finish (chunk : Acting.chunk) (tool : Acting.chunk_tool) ~is_last =
  let duration =
    match tool.Acting.ct_duration_ms with
    | Some ms -> { text = Acting.elapsed_text ms; tone = Dim }
    (* The header states the turn's state; the call's line states what it
       was doing and since when, so the state word does not repeat under
       its own header. The age is elapsed, so it says [ago]. *)
    | None when is_last && not chunk.Acting.ck_settled ->
        { text = age_text ~now chunk.Acting.ck_at ^ " ago"; tone = Dim }
    | None -> { text = ""; tone = Dim }
  in
  let glyph =
    if is_last && (not chunk.Acting.ck_settled) && Option.is_none tool.Acting.ct_duration_ms
    then
      if can_finish then { text = running_glyph ^ " "; tone = Ok }
      else { text = unfinished_glyph ^ " "; tone = Warn }
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

let turn_summary_line ~cols ~now (chunk : Acting.chunk) =
  let named =
    match turn_name chunk with
    | Some text -> [ { text; tone = Plain } ]
    | None -> []
  in
  fit_line ~cols
    (with_border
       ( [ { text = settled_glyph ^ " "; tone = Dim } ]
       @ named
       @ [ { text =
               middle_dot
               ^ join
                   [ calls_text (chunk_call_count chunk)
                   ; tokens_text chunk.Acting.ck_tokens
                   ; cost_text chunk.Acting.ck_cost_usd
                   ]
           ; tone = Dim
           }
         ; { text = middle_dot ^ age_text ~now chunk.Acting.ck_at ^ " ago"; tone = Dim }
         ] ))

(* Every focus row, oldest call first, then the earlier turns. The caller
   cuts to its budget. *)
let focus_lines ~cols input chunks name =
  let own =
    List.filter (fun (c : Acting.chunk) -> String.equal c.Acting.ck_keeper name) chunks
  in
  let approval = approval_for input.approvals name in
  let can_finish = keeper_can_finish (health_of input name) in
  let header =
    match own with
    | (current : Acting.chunk) :: _ ->
        let state_word, state_tone =
          if current.Acting.ck_settled then ("settled", Dim)
          else if can_finish then ("in turn", Ok)
          else ("unfinished", Warn)
        in
        let named =
          match turn_name current with
          | Some text -> [ { text = middle_dot ^ text; tone = Plain } ]
          | None -> []
        in
        fit_line ~cols
          (with_border
             ( { text = name; tone = Accent }
             :: named
             @ [ { text = middle_dot ^ state_word; tone = state_tone } ] ))
    | [] ->
        fit_line ~cols
          (with_border
             [ { text = name; tone = Accent }
             ; { text = middle_dot ^ "no turn on this feed yet"; tone = Dim }
             ])
  in
  let approval_line =
    match approval with
    | Some tool ->
        [ fit_line ~cols
            (with_border
               [ { text = attention_glyph ^ " "; tone = Warn }
               ; { text = "waiting on approval" ^ middle_dot ^ tool; tone = Warn }
               ])
        ]
    | None -> []
  in
  let body =
    match own with
    | [] -> []
    | current :: earlier ->
        let tools = Acting.chunk_tools current in
        let count = List.length tools in
        let calls =
          List.mapi
            (fun index tool ->
              tool_line ~cols ~now:input.now ~can_finish current tool ~is_last:(index = count - 1))
            tools
        in
        (* A call-less open turn draws no body row: the header already
           states the state and the age, and a row under it would repeat
           both. *)
        calls @ List.map (turn_summary_line ~cols ~now:input.now) earlier
  in
  List.map (fun line -> (line, Target_none)) ((header :: approval_line) @ body)

(* The least each block needs before the two share the rows: the fleet one
   keeper and its fold line, the focus its rule and one row. Below that the
   fleet keeps every row it can use and the focus block waits for a taller
   terminal. *)
let fleet_min_rows = 2
let focus_min_rows = 2

(* The overview: the fleet folded to at most half the rows, the focus block
   after a rule. What the fleet tab opens on. *)
let overview_rows ~cols ~below input newest ordered focus focus_rows =
  let fleet_budget =
    match focus with
    | Some _ when below >= fleet_min_rows + focus_min_rows ->
        min (List.length ordered) (below / 2)
    | Some _ | None -> min (List.length ordered) below
  in
  let fleet =
    if List.length ordered > fleet_budget && fleet_budget >= 2 then
      let shown = List.filteri (fun index _ -> index < fleet_budget - 1) ordered in
      List.map (fleet_row ~cols input newest) shown
      @ [ more_line ~cols (List.length ordered - (fleet_budget - 1)) ]
    else
      List.filteri (fun index _ -> index < fleet_budget) ordered
      |> List.map (fleet_row ~cols input newest)
  in
  let after_fleet = below - List.length fleet in
  let focus_block =
    match focus with
    | Some _ when after_fleet >= focus_min_rows ->
        (rule_line ~cols, Target_none)
        :: List.filteri (fun index _ -> index < after_fleet - 1) focus_rows
    | Some _ | None -> []
  in
  fleet @ focus_block

(* The full list from [scroll], one row of it given to each indicator. The
   top indicator always draws once scrolled: it is how the reader knows the
   header is not the first row. The bottom one draws only when content is
   still hidden, and the row it takes counts as hidden too. *)
let scrolled_rows ~cols ~below ~scroll body =
  let total = List.length body in
  let room = below - 1 in
  let slice = List.filteri (fun index _ -> index >= scroll && index < scroll + room) body in
  let hidden_below = total - (scroll + room) in
  let slice =
    if hidden_below > 0 && room >= 1 then
      List.filteri (fun index _ -> index < room - 1) slice
      @ [ indicator_line ~cols down_arrow (hidden_below + 1) ]
    else slice
  in
  indicator_line ~cols up_arrow scroll :: slice

(* The top of a list that overflows, the last row given to the bottom
   indicator. What the changes tab opens on: its rows are all alike, so
   there is nothing to fold. *)
let folded_rows ~cols ~below body =
  let total = List.length body in
  let room = max 0 (below - 1) in
  List.filteri (fun index _ -> index < room) body
  @ [ indicator_line ~cols down_arrow (total - room) ]

(* [body] windowed to [below] rows: whole when it fits, [overview] at the
   top, the scrolled slice anywhere else. At the largest scroll the last row
   is on screen under the top indicator alone; one row of the window belongs
   to that indicator. *)
let window ~cols ~below ~scroll ~overview body =
  let total = List.length body in
  let scroll_max = if total <= below then 0 else max 0 (total - (below - 1)) in
  let scroll = max 0 (min scroll scroll_max) in
  let drawn =
    if total <= below then body
    else if scroll = 0 then overview ()
    else scrolled_rows ~cols ~below ~scroll body
  in
  (drawn, scroll_max)

let fleet_lines ~cols ~below ~scroll input =
  let traces = List.map (fun keeper -> (keeper.name, keeper.trace_id)) input.keepers in
  let chunks = Acting.chunks ~traces input.entries in
  let newest = newest_chunk_by_keeper chunks in
  let focus = focus_keeper input newest in
  let ordered = fleet_order input newest in
  let focus_rows =
    match focus with
    | Some name -> focus_lines ~cols input chunks name
    | None -> []
  in
  (* The full list: every fleet row, then the rule and the focus block when
     there is one. Scrolling walks this; the overview folds it. *)
  let body =
    List.map (fleet_row ~cols input newest) ordered
    @ (match focus_rows with
       | [] -> []
       | _ :: _ -> (rule_line ~cols, Target_none) :: focus_rows)
  in
  window ~cols ~below ~scroll body ~overview:(fun () ->
    overview_rows ~cols ~below input newest ordered focus focus_rows)

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
    | Changes_ready r -> List.mapi (file_line ~cols ~now:input.now) r.files
    | Changes_absent | Changes_loading | Changes_failed _ -> []
  in
  let body = changes_status_lines ~cols input @ files in
  window ~cols ~below ~scroll body ~overview:(fun () -> folded_rows ~cols ~below body)

let lines ~rows ~cols ~scroll input =
  let rows = max 0 rows in
  if rows = 0 then { rows = []; targets = []; scroll_max = 0 }
  else
    let header = (header_line ~cols input, Target_next_tab) in
    let below = rows - 1 in
    let drawn, scroll_max =
      match input.tab with
      | Tab_fleet -> fleet_lines ~cols ~below ~scroll input
      | Tab_changes -> changes_lines ~cols ~below ~scroll input
    in
    let drawn = header :: drawn in
    let padding =
      List.init (max 0 (rows - List.length drawn)) (fun _ -> (blank_line ~cols, Target_none))
    in
    let drawn = List.filteri (fun index _ -> index < rows) (drawn @ padding) in
    { rows = List.map fst drawn; targets = List.map snd drawn; scroll_max }

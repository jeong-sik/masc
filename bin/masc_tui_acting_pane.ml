module Acting = Masc_tui_acting
module Layout = Masc_tui_message_layout
module Reading = Masc.Tui_decode

(* ── Width ───────────────────────────────────────────────────────────────

   The pane is a column of fleet rows. A row is a border cell, the health
   mark and its gap, a name, a gap, and the reading. Sixteen name cells keep
   the configured names whole that the roster's window keeps whole. The
   reading's budget holds the record glyph, the newest tool or the count,
   and both token parts: [~ network_read · 3+ calls] and
   [■ 123 calls · in 999.9k · out 999.9k] at exactly 36. No slack: labelling
   the parts spent the five cells the old [999.9k+999.9k tok] left over, and
   anything added to a settled reading now has to take width from somewhere
   else. [test_widest_settled_reading_fits_whole] is what says so. The age of the newest
   event is one fact and sits on the focus header, not here. *)
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

(* The wide pane spends its extra cells where the narrow one cuts: the
   keeper's name in a fleet row, and a call's age at the end of a call row.
   Eighteen more name cells hold the longest name on the live roster whole
   (kidsnote-slack-context-collector, 32 of 34); the calls' own column is
   the call row's remaining width, so the tool names gain the rest.

   What it costs: every reader needs a 150-column terminal for the wide
   pane, and fourteen of the eighteen are for that one name -- the next
   longest, kidsnote-spec-mania, is 19, and a longer name still reads,
   folded in the middle by [Layout.fit_middle]. The floor is seven: the age
   and its gap take seven cells of any extra, and fewer would leave the
   tool names narrower than the narrow pane's. The operator chose 74 over
   a width sized to the second name (2026-09-22). A roster name longer
   than 34 folds rather than raising this. *)
let wide_extra_cols = 18
let wide_pane_cols = pane_cols + wide_extra_cols
let wide_threshold_cols = wide_pane_cols + surface_floor_cols

type layout =
  | Narrow
  | Wide
  | Hidden

(* What a width the pane was handed can hold. The renderer hands it the
   columns {!drawn_cols} reserved, so this is the layout the reader chose
   whenever the terminal fits it. *)
let is_wide ~cols = cols >= wide_pane_cols

let drawn_cols ~layout ~cols =
  match layout with
  | Hidden -> 0
  | Wide when cols >= wide_threshold_cols -> wide_pane_cols
  | Wide | Narrow -> if cols >= threshold_cols then pane_cols else 0

(* Narrow, wide, hidden is the operator's order (2026-09-22): hiding from
   narrow takes two presses. Narrow, hidden, wide would make hiding one
   press and widening two; the order is this match and nothing else. *)
let next_layout ~layout ~cols =
  if cols < threshold_cols then None
  else
    Some
      (match layout with
       | Narrow -> if cols >= wide_threshold_cols then Wide else Hidden
       | Wide -> Hidden
       | Hidden -> Narrow)

let layout_label = function
  | Narrow -> "narrow"
  | Wide -> "wide"
  | Hidden -> "hidden"

let content_cols ~layout ~cols = cols - drawn_cols ~layout ~cols

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

type scope =
  | Whole_fleet
  | Selected_only

(* How the focus block orders the record's calls: receipt order either way,
   or the two readings that are not an order in time. The heading over the
   calls names which is up, and a press on it moves to the next. The TUI
   opens on newest first, so the first press turns time around and the two
   sorts come after. *)
type call_order =
  | Oldest_first
  | Newest_first
  | Longest_first
  | By_tool

let call_order_label = function
  | Oldest_first -> "oldest first"
  | Newest_first -> "newest first"
  | Longest_first -> "longest first"
  | By_tool -> "by tool"

let next_call_order = function
  | Newest_first -> Oldest_first
  | Oldest_first -> Longest_first
  | Longest_first -> By_tool
  | By_tool -> Newest_first

type input = {
  now : float;
  tab : tab;
  scope : scope;
  feed : feed;
  keepers : keeper list option;
  keepers_error : string option;
  selected : string option;
  approvals : approval list;
  chunks : Acting.chunk list;
  changes : changes;
  call_order : call_order;
  expanded : (string * Acting.call_key) list;
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
  | Target_calls of string
  | Target_call of string * Acting.call_key
  | Target_call_order

type rendering = {
  rows : line list;
  targets : row_target list;
  scroll_max : int;
}

(* ── Text ──────────────────────────────────────────────────────────────── *)

let middle_dot = " \xc2\xb7 "
let open_record_glyph = "~"
let done_glyph = Acting.glyph_text Acting.Turn_done
let attention_glyph = Acting.glyph_text Acting.Attention
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
let unfinished_glyph = "!"

(* Two cells after a call's record glyph say how it was dispatched. The
   first is [&] when the call ran in a batch with others -- the runtime's
   concurrent batch, its size above one; the second is [>] when the call
   returned a deferral, the ledger's [deferred]: the work goes on after the
   call. A serial call, or a batch of one, that completed draws neither:
   that is the ordinary case, and a mark on every row would say nothing.
   ASCII for the reason the change kinds are. The detail rows under an
   opened call spell both facts out. *)
let batch_glyph = "&"
let deferred_glyph = ">"
let dispatch_cells = 2
let failed_call_glyph = Acting.glyph_text Acting.Failure

(* An opened call's detail rows sit under its name, past the record glyph
   and the dispatch marks, and each names what it holds in a fixed label
   so the two previews line up. *)
let detail_indent_cells = mark_cells + dispatch_cells + gap_cells
let detail_label_cells = 4

let age_text ~now at = Acting.elapsed_text (Float.max 0. (now -. at) *. 1000.)
let last_event_text ~now at = "last event " ^ age_text ~now at

let compact_count n =
  let thousand = 1_000 and million = 1_000_000 in
  if n >= million then Printf.sprintf "%.1fM" (float_of_int n /. float_of_int million)
  else if n >= thousand then
    Printf.sprintf "%.1fk" (float_of_int n /. float_of_int thousand)
  else string_of_int n

(* Input and output as two parts, for the focus block. The input part is what
   a turn re-sends on every call, so it is what makes a twelve-call turn read
   in the millions; a reader who sees a large input beside a small output can
   tell that from one long answer. *)
(* Labelled, not joined by "+". The two figures are input and output, and a
   plus sign between them reads as arithmetic -- the more so because
   [tokens_sum_text] right below produces exactly that sum in the same shape.
   One operator asked what 73.9k+358 added up to. *)
let tokens_text = function
  | None, None -> ""
  | Some i, Some o ->
    "in " ^ compact_count i ^ " · out " ^ compact_count o
  | Some n, None | None, Some n -> compact_count n ^ " tok"

let tokens_sum_text = function
  | None, None -> ""
  | Some i, Some o -> compact_count (i + o) ^ " tok"
  | Some n, None | None, Some n -> compact_count n ^ " tok"

(* The same sum without its unit, for the fleet row's column: the heading
   above it already says what the figure counts, and repeating "tok" on every
   row cost four of the nine cells the column has. *)
let tokens_sum_figure = function
  | None, None -> ""
  | Some i, Some o -> compact_count (i + o)
  | Some n, None | None, Some n -> compact_count n

let calls_text n = Masc_tui_message_layout.count_noun n "call"
let files_text n = Masc_tui_message_layout.count_noun n "file"
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

(* One word for the count. The end event reports the whole turn: [12 calls]. An
   open record only knows what this feed observed, which may have
   started mid-turn or lost rows, so it says at least that many: [4+ calls],
   and [no calls yet] when it saw none. *)
let chunk_calls_text (chunk : Acting.chunk) =
  if chunk.Acting.ck_settled then
    match chunk.Acting.ck_calls with
    | Some count -> calls_text count
    | None -> "calls ?"
  else
    match List.length (Acting.chunk_tools chunk) with
    | 0 -> "no calls yet"
    | seen -> Printf.sprintf "%d+ calls" seen

(* The same count as a figure alone, for the fleet row's four-cell column.
   The word "calls" moves to the column header, which says it once for every
   row instead of once per row. "?" is an end event that named no count, and "-"
   is a record with no call yet: they are different facts and neither is 0. *)
let calls_figure (chunk : Acting.chunk) =
  if chunk.Acting.ck_settled then
    match chunk.Acting.ck_calls with Some count -> string_of_int count | None -> "?"
  else
    match List.length (Acting.chunk_tools chunk) with
    | 0 -> "-"
    | seen -> string_of_int seen ^ "+"

type record_state = Record_open | Record_unfinished | Record_done

(* Window logical rows before formatting text or measuring display cells. These
   descriptors live for one frame; presentation still uses that frame's input. *)
type direction = Above | Below

type detail_part =
  | Detail_facts
  | Detail_input
  | Detail_output

(* Where a call sits in the model response it came from. When the focus
   block splits the record into responses, the call row draws it in the
   border cell: a bracket per response, [\xe2\x94\x8c] over the first call,
   [\xe2\x94\x82] beside the ones between, [\xe2\x94\x94] at the last, and
   [\xe2\x94\x80] beside a response of one call. The bracket costs no row.
   Measured on the September ledger, a record keyed by (keeper,
   keeper_turn_id) -- [keeper_turn_id] counts per keeper, and alone it
   merges different keepers' turns: 21,273 records hold more than one
   response, a response holds 1.38 calls on average, 80.7% hold one. A line
   of its own over each response would have been close to half the list.

   A lone call carries no mark. A dim tick beside each one put a glyph on
   58.7% of the call rows, and on the live screen the fleet read as a wall
   of hooks (operator, 2026-09-22). What the tick said -- this record is
   split, and this call stood alone -- the heading says once instead: it
   counts the responses whenever the record splits. 45.2% of split records
   are all lone calls; they draw no bracket, and the count is what tells
   them from a record that is one response or whose responses are unknown
   (a CLI lane, a sort, an unnumbered call). *)
type response_place =
  | Ungrouped
  | Alone
  | Opens
  | Inside
  | Closes

type logical_row =
  | Fleet_row of keeper * Acting.chunk option
  | Focus_header of string * Acting.chunk option * Reading.keeper_health_reading option
  | Approval_row of string
  | Calls_heading of int option
  | Tool_row of Acting.chunk * Acting.chunk_tool * record_state * response_place
  | Call_detail of Acting.chunk * Acting.chunk_tool * detail_part
  | Earlier_turn of Acting.chunk * Reading.keeper_health_reading option
  | Rule
  | More of int
  | Indicator of direction * int
  | File_row of int * file_row
  | Formatted_status of line * row_target

let record_state ~health (chunk : Acting.chunk) =
  if chunk.Acting.ck_settled then Record_done
  else
    match health with
    | Some Reading.Health_offline -> Record_unfinished
    (* A failing keeper's process is still there, so "process gone" would be
       false for it. *)
    | Some (Reading.Health_running | Reading.Health_idle | Reading.Health_failing)
    | None -> Record_open

(* The record's state in words, for the fleet row's state column, the
   focus header and the earlier-turn rows. "open" is a turn no end event has
   closed; it does not say the keeper is at work, and no row has evidence
   for that. When the process is gone no end will come, and the long form
   says so.

   These read "settled" and "unsettled" until an operator asked what the
   words meant (2026-09-22). One of them covered two states -- an open record
   and a gone one parted by tone alone -- while a second copy of this
   function for the narrow column called the gone one something else again.
   The word also names three other facts in this repository: a tool dispatch
   that returned a result, a ledger row whose outcome is unknown, an owner
   not yet chosen. And it reads first as "calm", which two comments here had
   to deny. The feed event is [Keeper_turn_complete]; the screen now says
   the same thing, from one place. *)
let record_word = function
  | Record_open -> ("open", Dim)
  | Record_unfinished -> ("no end", Warn)
  | Record_done -> ("done", Dim)

let record_word_long = function
  | Record_unfinished -> ("no end, process gone", Warn)
  | (Record_open | Record_done) as state -> record_word state

let record_glyph = function
  | Record_open -> open_record_glyph
  | Record_unfinished -> unfinished_glyph
  | Record_done -> done_glyph

(* Fixed columns, so the eye can run down one and compare rows instead of
   reading each as a sentence. Every row spends the same cells on the same
   fact whether or not it has that fact, and a column with nothing to say is
   left blank rather than letting the next one slide left. Joined by "·" in
   whatever order a row happened to have them, the same cell held a tool name
   on one line and a call count on the next.

   The four add up to [reading_cells] exactly. Widest members measured:
   "no events" 9 in a 10-cell state column, whose last cell is the gap to
   the next -- without it the state word and a tool name ran together;
   "tool_execute" 12; "999+" 4 under a 5-cell "calls" heading;
   "999.9k" 6 under a 9-cell "tok/turn". Widening one has to narrow another,
   and [test_widest_settled_reading_fits_whole] fails when the sum drifts. *)
let state_cells = 10
let tool_cells = 12
let calls_cells = 5
let tokens_cells = 9

(* Figures read down a column when their last digits line up, so counts and
   tokens are right-aligned; names read from their first letter. *)
let pad_right width text =
  let text = Layout.take_cells text width in
  text ^ String.make (max 0 (width - Layout.display_width text)) ' '

let pad_left width text =
  let text = Layout.take_cells text width in
  String.make (max 0 (width - Layout.display_width text)) ' ' ^ text

(* The state word, then the newest tool and the count, or the count and
   the tokens once done. No clock here: the age
   of the newest event is one fact, and it sits on the focus header. *)
let keeper_state_text ~health ~approval (chunk : Acting.chunk option) =
  let blank width = { text = String.make width ' '; tone = Plain } in
  match approval, chunk with
  | Some tool, _ ->
    (* An approval outranks whatever the record says, and it can arrive before
       any chunk does -- reading the chunk first drew a keeper waiting on an
       operator as one with nothing to report. *)
    [ { text = pad_right state_cells "approval"; tone = Warn }
    ; { text = pad_right tool_cells tool; tone = Warn }
    ; blank (calls_cells + tokens_cells)
    ]
  | None, None ->
    (* No record at all. The state column carries the reason and the rest of
       the row stays blank, so an empty tool column reads as "nothing named"
       rather than as a row that failed to draw. *)
    [ { text = pad_right state_cells "no events"; tone = Dim }
    ; blank (tool_cells + calls_cells + tokens_cells)
    ]
  | None, Some chunk ->
    let state = record_state ~health chunk in
    let word, word_tone = record_word state in
    (* Which columns a row fills is the record's shape, not a choice. A turn
       still open names the tool it is in and has no token count; a done one
       carries the counts and names no tool, because a turn that is over is
       not in one. Each fact keeps its own column either way. *)
    let tool, tokens =
      match state with
      | Record_done -> ("", tokens_sum_figure chunk.Acting.ck_tokens)
      | Record_open | Record_unfinished ->
        ((match latest_tool chunk with Some tool -> tool | None -> ""), "")
    in
    let detail_tone = if state = Record_unfinished then Warn else Plain in
    [ { text = pad_right state_cells word; tone = word_tone }
    ; { text = pad_right tool_cells tool; tone = detail_tone }
    ; { text = pad_left calls_cells (calls_figure chunk); tone = detail_tone }
    ; { text = pad_left tokens_cells tokens; tone = detail_tone }
    ]

(* ── Lines ─────────────────────────────────────────────────────────────── *)

let spans_width spans =
  List.fold_left (fun acc span -> acc + Layout.display_width span.text) 0 spans

(* The first candidate that fits, else the last: a row states less before
   it clips a figure mid-number. *)
let rec first_fitting ~room = function
  | [] -> []
  | [ last ] -> last
  | candidate :: rest ->
      if spans_width candidate <= room then candidate else first_fitting ~room rest

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

(* The pane answers "what is every keeper doing right now", and a keeper with no
   agent present is doing nothing. Offline rows are dropped so the ones that are
   working are not read past.

   Only Health_offline. An idle keeper is one that has not turned yet, which is
   a keeper an operator may still be waiting on, so it stays in the pane.
   A failing keeper is still turning, and its turns are the ones an operator
   most needs to read, so it stays too.
   A keeper whose health did not read at all stays: no reading is not a reading
   of "offline", and dropping those empties the pane whenever the roster fails. *)
let is_offline keeper =
  match keeper.health with
  | Some Reading.Health_offline -> true
  | Some (Reading.Health_running | Reading.Health_idle | Reading.Health_failing)
  | None -> false

(* A roster that was never read has no rows to draw, so the rows read it as
   empty; only the header, which counts them, has to tell the two apart. *)
let roster input = Option.value input.keepers ~default:[]

let working_keepers input = List.filter (fun k -> not (is_offline k)) (roster input)
let offline_count input = List.length (List.filter is_offline (roster input))

let header_line ~cols input =
  (* Beside the roster the count is the roster's own title; the header then
     says only what the roster cannot, the feed's state. *)
  let count =
    match input.scope with
    | Whole_fleet ->
      (* Counted over what the pane draws, and the hidden ones said out loud.
         A count of the whole fleet beside a shorter list reads as a drawing
         bug, and a count of the drawn rows alone hides that anything was
         dropped. *)
      (match input.keepers_error, input.keepers with
       | Some _, _ -> "keepers unavailable"
       | None, None -> "keepers not loaded"
       | None, Some _ ->
         let hidden = offline_count input in
         Masc_tui_message_layout.count_noun (List.length (working_keepers input)) "keeper"
         ^ (if hidden = 0 then "" else Printf.sprintf " (%d offline)" hidden))
      ^ middle_dot
    | Selected_only -> ""
  in
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
       ; { text = middle_dot ^ count; tone = Dim }
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

(* Pending approvals rank first, then open records before done ones,
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
  List.stable_sort (fun a b -> compare (rank a) (rank b)) (working_keepers input)

(* The fleet row's name column: the wide pane's extra cells, all of them. *)
let name_cells_for ~cols =
  if is_wide ~cols then name_cells + wide_extra_cols else name_cells

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
          ; { text = Layout.fit_middle (name_cells_for ~cols) keeper.name
            ; tone = (if selected then Accent else Plain)
            }
          ; { text = String.make gap_cells ' '; tone = Plain }
          ]
          @ keeper_state_text ~health:keeper.health ~approval chunk))
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
  match List.find_opt (fun keeper -> String.equal keeper.name name) (roster input) with
  | Some keeper -> keeper.health
  | None -> None

(* The batch a call ran in, when the ledger said and the runtime ran more
   than one call in it at once. *)
let ran_in_a_batch (tool : Acting.chunk_tool) =
  match tool.Acting.ct_schedule with
  | Some (Ok schedule) -> schedule.Agent_core.Tool_contract.batch_size > 1
  | Some (Error _) | None -> false

let dispatch_marks (tool : Acting.chunk_tool) =
  let batch =
    { text = (if ran_in_a_batch tool then batch_glyph else " "); tone = Info }
  in
  let deferred =
    match tool.Acting.ct_disposition with
    | Some (Ok Reading.Keeper_call_deferred) -> { text = deferred_glyph; tone = Info }
    | Some (Ok (Reading.Keeper_call_completed | Reading.Keeper_call_failed))
    | Some (Error _) | None -> { text = " "; tone = Plain }
  in
  [ batch; deferred; { text = String.make gap_cells ' '; tone = Plain } ]

(* The border cell of a call row. Out of a bracket it is the pane's edge
   like every other row, a lone call's included; in one it is the bracket,
   drawn plain so it reads over the dim edge, the calls between included. *)
let rail_span = function
  | Ungrouped | Alone -> border
  | Opens -> { text = "\xe2\x94\x8c"; tone = Plain }
  | Inside -> { border with tone = Plain }
  | Closes -> { text = "\xe2\x94\x94"; tone = Plain }

(* A call's age in the wide pane, at the row's end, in the pane's own age
   wording ({!age_text}): the facts row under an opened call and the focus
   header spell ages that way, and a row and its own detail must not say
   one age two ways. Padded to six cells, so the ages and the durations
   before them line up down the list through ninety-nine minutes; an older
   age widens its own row rather than losing digits to a cut. *)
let age_min_cells = 6

let tool_line ~cols ~now ~state ~place (chunk : Acting.chunk) (tool : Acting.chunk_tool) =
  let duration =
    match tool.Acting.ct_duration_ms with
    | Some ms -> { text = Acting.elapsed_text ms; tone = Dim }
    (* The feed does not carry a receipt clock for each folded tool. Its
       unknown duration stays blank; the record header owns the event age. *)
    | None -> { text = ""; tone = Dim }
  in
  let glyph =
    match tool.Acting.ct_disposition with
    | Some (Ok Reading.Keeper_call_failed) -> { text = failed_call_glyph ^ " "; tone = Bad }
    | Some (Ok (Reading.Keeper_call_completed | Reading.Keeper_call_deferred))
    | Some (Error _) | None ->
        if (not chunk.Acting.ck_settled) && Option.is_none tool.Acting.ct_duration_ms
        then
          (match state with
           | Record_unfinished -> { text = unfinished_glyph ^ " "; tone = Warn }
           | Record_open | Record_done -> { text = open_record_glyph ^ " "; tone = Dim })
        else { text = done_glyph ^ " "; tone = Dim }
  in
  let age =
    if is_wide ~cols then
      let text = age_text ~now tool.Acting.ct_at in
      [ { text = String.make gap_cells ' '; tone = Plain }
      ; { text = String.make (max 0 (age_min_cells - Layout.display_width text)) ' ' ^ text
        ; tone = Dim
        }
      ]
    else []
  in
  let inner = cols - border_cells - mark_cells - dispatch_cells - gap_cells in
  let right =
    Layout.display_width duration.text
    + List.fold_left (fun cells span -> cells + Layout.display_width span.text) 0 age
  in
  let name_room = max 0 (inner - right - (if right > 0 then gap_cells else 0)) in
  fit_line ~cols
    (rail_span place
     :: (glyph :: dispatch_marks tool)
     @ [ { text = Layout.fit_width tool.Acting.ct_tool name_room; tone = Plain }
       ; { text = (if right > 0 then String.make gap_cells ' ' else ""); tone = Plain }
       ; duration
       ]
     @ age)

(* The heading over the calls: which order they are in, and how many
   model responses the record splits into when it splits. Beside it the
   order is a press away, so the heading is the control as well as the
   label. No count is a record that is one response or whose responses the
   pane cannot tell apart; the count never says "1". *)
let calls_heading_line ~cols order responses =
  let count =
    match responses with
    | Some n -> middle_dot ^ string_of_int n ^ " responses"
    | None -> ""
  in
  fit_line ~cols
    (with_border
       [ { text = String.make mark_cells ' '; tone = Plain }
       ; { text = "calls" ^ middle_dot ^ call_order_label order ^ count; tone = Dim }
       ])

(* Text cut to [room] cells, the cut shown: a preview that ends mid-word
   with no mark reads as the whole. *)
let clip_cells text room =
  if Layout.display_width text <= room then text
  else Layout.take_cells text (max 0 (room - 1)) ^ ellipsis

(* The mode and, in a batch, how many ran at once. Not the planned step:
   the list already shows the calls in receipt order, and the facts row has
   fifty cells after its indent -- with "step 12" on it the widest row
   ("completed \xc2\xb7 12m05s ago \xc2\xb7 step 12 \xc2\xb7 concurrent, 12 at
   once", 57) lost its last word to the cut; without it that row is 47. *)
let schedule_text (tool : Acting.chunk_tool) =
  match tool.Acting.ct_schedule with
  | None -> ""
  | Some (Error _) -> "schedule ?"
  | Some (Ok schedule) ->
      let mode =
        match schedule.Agent_core.Tool_contract.execution_mode with
        | Agent_core.Tool_contract.Concurrent -> "concurrent"
        | Agent_core.Tool_contract.Serial -> "serial"
      in
      if schedule.Agent_core.Tool_contract.batch_size > 1 then
        Printf.sprintf "%s, %d at once" mode schedule.Agent_core.Tool_contract.batch_size
      else mode

let disposition_span (tool : Acting.chunk_tool) =
  match tool.Acting.ct_disposition with
  | None -> None
  | Some (Error _) -> Some { text = "disposition ?"; tone = Warn }
  | Some (Ok disposition) ->
      let tone =
        match disposition with
        | Reading.Keeper_call_completed -> Dim
        | Reading.Keeper_call_deferred -> Info
        | Reading.Keeper_call_failed -> Bad
      in
      Some { text = Reading.keeper_call_disposition_to_string disposition; tone }

(* One of an opened call's three rows. The facts row is the disposition,
   the receipt age and the schedule -- the words behind the marks on the
   call's own row, the disposition first because it is the one that carries
   a tone and the one the cut must never take. The two previews are what
   the producer redacted and sent, one row each, cut to the pane; "not
   carried" is the wire plane, which sends none. *)
let call_detail_line ~cols ~now (tool : Acting.chunk_tool) part =
  let indent = { text = String.make detail_indent_cells ' '; tone = Plain } in
  let room = max 0 (cols - border_cells - detail_indent_cells) in
  let preview_row ~label preview =
    let body =
      match preview with
      | Some text ->
          { text = clip_cells (Reading.preview_line text) (max 0 (room - detail_label_cells))
          ; tone = Plain
          }
      | None -> { text = "not carried"; tone = Dim }
    in
    fit_line ~cols
      (with_border [ indent; { text = pad_right detail_label_cells label; tone = Dim }; body ])
  in
  match part with
  | Detail_facts ->
      let facts =
        { text = join [ age_text ~now tool.Acting.ct_at ^ " ago"; schedule_text tool ]
        ; tone = Dim
        }
      in
      let disposition =
        match disposition_span tool with
        | Some span -> [ span; { text = middle_dot; tone = Dim } ]
        | None -> []
      in
      fit_line ~cols (with_border ((indent :: disposition) @ [ facts ]))
  | Detail_input -> preview_row ~label:"in" tool.Acting.ct_input
  | Detail_output -> preview_row ~label:"out" tool.Acting.ct_output

(* The pane names a turn by the number its settle confirmed; the header
   then shows that number in place of the state word. An open turn spells
   its state instead, whatever number an observation gave it. A settle that
   carried no number settles the chunk without naming it: [turn_text] would
   draw that as [turn ?], a question the row cannot answer and the reader
   cannot act on. *)
let turn_name (chunk : Acting.chunk) =
  match (chunk.Acting.ck_turn, chunk.Acting.ck_settled) with
  | (Some _ as turn), true -> Some (Acting.turn_text turn)
  | Some _, false | None, (true | false) -> None

let turn_summary_line ~cols ~health (chunk : Acting.chunk) =
  let state = record_state ~health chunk in
  let named =
    match turn_name chunk with
    | Some text -> [ { text; tone = Plain } ]
    | None -> []
  in
  let prefix =
    match state with
    | Record_done -> { text = done_glyph ^ " "; tone = Dim }
    | Record_open | Record_unfinished ->
        let word, tone = record_word state in
        { text = record_glyph state ^ " " ^ word; tone }
  in
  let line ~tokens ~cost =
    with_border
      ( [ prefix ]
      @ named
      @ [ { text = middle_dot ^ join [ chunk_calls_text chunk; tokens; cost ]; tone = Dim } ] )
  in
  let parts = tokens_text chunk.Acting.ck_tokens
  and sum = tokens_sum_text chunk.Acting.ck_tokens
  and cost = cost_text chunk.Acting.ck_cost_usd in
  (* No receipt age: when this settle arrived is not what the row is read
     for, and the header carries the one clock. The cost goes before the
     token parts, since the parts are what the row is read for. *)
  fit_line ~cols
    (first_fitting ~room:cols
       [ line ~tokens:parts ~cost; line ~tokens:parts ~cost:""; line ~tokens:sum ~cost:"" ])

(* What the keeper is doing right now, when the record and the keepalive
   agree on it. The record alone cannot say: an open wire call sits in a
   record whose keeper stopped answering just the same, and the surface
   already refuses to read work out of a record that has not closed. So the
   health reading decides who may be quoted, and the record says what.

   - Running keeper, a wire call the runtime started and no return settled:
     that tool is out, and the clock is the call's own start.
   - Running keeper, no call out, [Marker_started] newest: the provider call
     is in flight, so the model has the turn.
   - Idle keeper on a done record: the turn is over, and the clock is how
     long the keeper has been quiet.

   [None] everywhere else, and the header reads as it did before: the
   record's state word and the age of its newest event. That covers a
   failing or offline keeper, whose call is not running whatever the last
   frame said; the gap between a tool's return and the next provider call;
   and a CLI lane, which sends no turn markers and runs a whole keeper turn
   as one provider call. *)
let now_text ~now ~health ~state (chunk : Acting.chunk) =
  let open_call =
    List.fold_left
      (fun open_so_far (wire : Acting.wire_tool) ->
        match wire.Acting.wt_duration_ms with
        | None -> Some wire
        | Some _ -> open_so_far)
      None chunk.Acting.ck_wire_tools
  in
  let working () =
    match open_call with
    | Some wire ->
        Some
          (Printf.sprintf "running %s %s" wire.Acting.wt_tool
             (age_text ~now wire.Acting.wt_started))
    | None -> (
        match chunk.Acting.ck_marker with
        | Some (Acting.Marker_started, at) ->
            Some ("waiting on model " ^ age_text ~now at)
        | Some (Acting.Marker_ready, _)
        | Some (Acting.Marker_completed, _)
        | None -> None)
  in
  match health with
  | Some Reading.Health_running -> (
      match state with
      | Record_open | Record_unfinished -> working ()
      | Record_done -> None)
  | Some Reading.Health_idle -> (
      match state with
      | Record_done -> Some ("idle " ^ age_text ~now chunk.Acting.ck_at)
      | Record_open | Record_unfinished -> None)
  | Some Reading.Health_failing | Some Reading.Health_offline | None -> None

let focus_header_line ~cols ~now ~health name current =
  match current with
  | Some (current : Acting.chunk) ->
      let state = record_state ~health current in
      let clock =
        { text = middle_dot ^ last_event_text ~now current.Acting.ck_at; tone = Dim }
      in
      (* A named turn is a done one, since only the end event names it: the
         number says what the word would, and the word pushed the clock off
         the row behind a sixteen-cell name. Every other record spells its
         state, the long form first, and gives that up before the clock. *)
      let states =
        match turn_name current with
        | Some turn when state = Record_done -> [ [ { text = middle_dot ^ turn; tone = Plain } ] ]
        | Some _ | None ->
            List.map
              (fun (word, tone) -> [ { text = middle_dot ^ word; tone } ])
              [ record_word_long state; record_word state ]
      in
      (* What the keeper is doing now comes before the state word, and
         carries its own clock, so the row does not spell two ages. The
         state word rows stay behind it: a narrow pane, or a record with
         nothing to say about now, falls back to them. *)
      let now_rows =
        match now_text ~now ~health ~state current with
        | None -> []
        | Some text ->
            let now_span = { text = middle_dot ^ text; tone = Info } in
            let named =
              match turn_name current with
              | Some turn when state = Record_done ->
                  [ [ now_span; { text = middle_dot ^ turn; tone = Plain } ] ]
              | Some _ | None -> []
            in
            named @ [ [ now_span ] ]
      in
      let with_clock words = with_border (({ text = name; tone = Accent } :: words) @ [ clock ]) in
      fit_line ~cols
        (first_fitting ~room:cols
           (List.map (fun words -> with_border ({ text = name; tone = Accent } :: words)) now_rows
            @ List.map with_clock states))
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

(* The calls in the order the heading names. Receipt order is what the fold
   holds; the other two are stable over it, so calls that tie keep their
   receipt order. A call still out has no duration and sorts after every
   call that has one. *)
let ordered_calls order (calls : Acting.chunk_tool list) =
  match order with
  | Oldest_first -> calls
  | Newest_first -> List.rev calls
  | Longest_first ->
      List.stable_sort
        (fun (a : Acting.chunk_tool) (b : Acting.chunk_tool) ->
          match a.Acting.ct_duration_ms, b.Acting.ct_duration_ms with
          | Some took_a, Some took_b -> Float.compare took_b took_a
          | Some _, None -> -1
          | None, Some _ -> 1
          | None, None -> 0)
        calls
  | By_tool ->
      List.stable_sort
        (fun (a : Acting.chunk_tool) (b : Acting.chunk_tool) ->
          String.compare a.Acting.ct_tool b.Acting.ct_tool)
        calls

(* The calls split into model responses, when the order and the record can
   say where one ends. Neighbours with the same session ordinal are one
   response: the next provider call has the next ordinal. The planned index
   cannot stand in for it -- a concurrent batch settles in any order, so
   [1, 0, 2] arrives inside one response, and a CLI lane counts its calls
   across the whole turn. Receipt order keeps a response's calls together,
   forwards or backwards; the two sorts interleave them. A call that states
   no ordinal leaves the boundary beside it unknown, and a single response
   has nothing to split.

   One path breaks the neighbour rule: a deferred composition runs its plan
   under the parent's ordinal after the tool returns, so a child that
   settles after the next response's calls draws as a response of its own.
   Grouping by ordinal value instead would fix that and merge two responses
   whenever a fresh agent session reuses an ordinal inside one keeper turn,
   which is the worse claim; the ledger of 2026-09-20..22 shows neither
   (0 deferred compositions in 359, 0 ordinals reappearing in 852
   multi-response turns). *)
let responses order (calls : Acting.chunk_tool list) =
  let keeps_responses_together =
    match order with
    | Oldest_first | Newest_first -> true
    | Longest_first | By_tool -> false
  in
  let states_its_response (tool : Acting.chunk_tool) =
    Option.is_some tool.Acting.ct_session_turn
  in
  if not (keeps_responses_together && List.for_all states_its_response calls) then None
  else
    let groups =
      List.fold_left
        (fun groups (tool : Acting.chunk_tool) ->
          match groups with
          | ((last : Acting.chunk_tool) :: _ as group) :: rest
            when Option.equal Int.equal last.Acting.ct_session_turn
                   tool.Acting.ct_session_turn ->
              (tool :: group) :: rest
          | [] | [] :: _ | (_ :: _) :: _ -> [ tool ] :: groups)
        [] calls
      |> List.rev_map List.rev
    in
    match groups with [] | [ _ ] -> None | _ :: _ :: _ -> Some groups

let is_expanded input ~keeper key =
  List.exists
    (fun (name, opened) -> String.equal name keeper && Acting.call_key_equal opened key)
    input.expanded

(* Every logical focus row: the heading, the calls in the heading's order
   with an opened call's detail under it, then the earlier turns. No text
   is formatted until the caller selects the visible window. *)
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
        let ordered = ordered_calls input.call_order (Acting.chunk_tools current) in
        let call_rows (tool, place) =
          Tool_row (current, tool, state, place)
          ::
          (if is_expanded input ~keeper:name (Acting.call_key tool) then
             List.map
               (fun part -> Call_detail (current, tool, part))
               [ Detail_facts; Detail_input; Detail_output ]
           else [])
        in
        let groups = responses input.call_order ordered in
        let placed =
          match groups with
          | Some groups ->
              List.concat_map
                (fun group ->
                  match group with
                  | [ only ] -> [ (only, Alone) ]
                  | first :: rest ->
                      let last = List.length rest - 1 in
                      (first, Opens)
                      :: List.mapi
                           (fun i tool -> (tool, if i = last then Closes else Inside))
                           rest
                  | [] -> [])
                groups
          | None -> List.map (fun tool -> (tool, Ungrouped)) ordered
        in
        let calls = List.concat_map call_rows placed in
        (* A call-less record draws no body row: the header already states
           the observation state and its receipt age. The heading names the
           order only when there are calls in it. *)
        let heading =
          match calls with
          | [] -> []
          | _ :: _ -> [ Calls_heading (Option.map List.length groups) ]
        in
        heading @ calls @ List.map (fun chunk -> Earlier_turn (chunk, health)) earlier
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

(* The rows before the window takes a slice of them, with the overview the
   scope folds to. Split out of [fleet_lines] so the heading above them can
   be decided from what they are: the column names belong over rows that use
   the columns, and beside the roster there may be none. *)
let fleet_body input =
  let chunks = input.chunks in
  let newest = newest_chunk_by_keeper chunks in
  let focus = focus_keeper input newest in
  let ordered = fleet_order input newest in
  let focus_rows =
    match focus with
    | Some name -> focus_rows input chunks name
    | None -> []
  in
  let fleet_row_of keeper = Fleet_row (keeper, Hashtbl.find_opt newest keeper.name) in
  match input.scope with
  | Selected_only ->
      (* Beside the roster every fleet row is a roster row said twice, except
         a keeper waiting on the reader: the roster does not say who is
         waiting on an approval, so those rows stay, above the selected
         keeper's record. The focus block already carries its own. *)
      let waiting =
        List.filter
          (fun keeper ->
            Option.is_some (approval_for input.approvals keeper.name)
            &&
            match focus with
            | Some name -> not (String.equal name keeper.name)
            | None -> true)
          ordered
        |> List.map fleet_row_of
      in
      let body =
        match waiting, focus_rows with
        | [], rows | rows, [] -> rows
        | waiting, rows -> waiting @ (Rule :: rows)
      in
      (body, fun ~below -> folded_rows ~below body)
  | Whole_fleet ->
      (* The full list: every fleet row, then the rule and the focus block
         when there is one. Scrolling walks this; the overview folds it. *)
      let fleet_rows = List.map fleet_row_of ordered in
      let body =
        fleet_rows
        @ (match focus_rows with
           | [] -> []
           | _ :: _ -> Rule :: focus_rows)
      in
      (body, fun ~below -> overview_rows ~below fleet_rows focus focus_rows)

let fleet_lines ~below ~scroll (body, overview) =
  window ~below ~scroll body ~overview:(fun () -> overview ~below)

(* A row that spends the pane's four columns -- state, tool, calls and tokens.
   The column names sit over these. A focus header with no record of its own
   is a sentence ("alpha \xc2\xb7 no events on this feed yet"), and beside the
   roster it can be every row the pane has: the roster already draws the fleet,
   so the pane keeps only the selected keeper's record and what waits on the
   reader. Naming four columns over one sentence spends a row saying nothing. *)
let row_uses_the_columns = function
  | Fleet_row _ | Tool_row _ | Earlier_turn _ -> true
  | Focus_header _ | Approval_row _ | Calls_heading _ | Call_detail _ | Rule | More _
  | Indicator _ | File_row _ | Formatted_status _ -> false

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
  | Calls_heading responses ->
      calls_heading_line ~cols input.call_order responses, Target_call_order
  | Tool_row (chunk, tool, state, place) ->
      ( tool_line ~cols ~now:input.now ~state ~place chunk tool
      , Target_call (chunk.Acting.ck_keeper, Acting.call_key tool) )
  | Call_detail (chunk, tool, part) ->
      ( call_detail_line ~cols ~now:input.now tool part
      , Target_call (chunk.Acting.ck_keeper, Acting.call_key tool) )
  | Earlier_turn (chunk, health) ->
      turn_summary_line ~cols ~health chunk, Target_calls chunk.Acting.ck_keeper
  | Rule -> rule_line ~cols, Target_none
  | More n -> more_line ~cols n
  | Indicator (direction, n) ->
      let arrow = match direction with Above -> up_arrow | Below -> down_arrow in
      indicator_line ~cols arrow n
  | File_row (index, file) -> file_line ~cols ~now:input.now index file
  | Formatted_status (line, target) -> line, target

(* Column headings, in the row the legend used to hold. With the parts in
   fixed columns the names can sit over them, which says what each one is
   once for the whole list instead of a glyph key the reader has to carry
   down every row. Built from the same widths, so a change to one moves both
   the heading and the column under it. *)
let legend ~cols =
  String.make (mark_cells + name_cells_for ~cols + gap_cells) ' '
  ^ pad_right state_cells "state"
  ^ pad_right tool_cells "tool"
  ^ pad_left calls_cells "calls"
  ^ pad_left tokens_cells "tok/turn"

let next_target_row ~(targets : row_target array) ~row ~step =
  let count = Array.length targets in
  let rec walk index =
    if index < 0 || index >= count then None
    else
      match targets.(index) with
      | Target_none -> walk (index + step)
      | Target_next_tab | Target_keeper _ | Target_more | Target_file _
      | Target_calls _ | Target_call _ | Target_call_order ->
          Some index
  in
  if step = 0 then None else walk (row + step)

let lines ~rows ~cols ~scroll input =
  let rows = max 0 rows in
  if rows = 0 then { rows = []; targets = []; scroll_max = 0 }
  else
    let header = (header_line ~cols input, Target_next_tab) in
    let fleet = match input.tab with
      | Tab_fleet -> Some (fleet_body input)
      | Tab_changes -> None
    in
    let headers =
      match fleet with
      | Some (body, _) when rows >= 2 && List.exists row_uses_the_columns body ->
        [ header; (fit_line ~cols (with_border [ { text = legend ~cols; tone = Dim } ]), Target_none) ]
      | Some _ | None -> [ header ]
    in
    let below = rows - List.length headers in
    let visible, scroll_max =
      if below <= 0 then [], 0
      else
        match fleet with
        | Some fleet -> fleet_lines ~below ~scroll fleet
        | None -> changes_lines ~cols ~below ~scroll input
    in
    let drawn = headers @ List.map (materialize_row ~cols input) visible in
    let padding =
      List.init (max 0 (rows - List.length drawn)) (fun _ -> (blank_line ~cols, Target_none))
    in
    let drawn = List.filteri (fun index _ -> index < rows) (drawn @ padding) in
    { rows = List.map fst drawn; targets = List.map snd drawn; scroll_max }

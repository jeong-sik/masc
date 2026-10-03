open Masc.Tui_decode_memory_facts
open Masc_tui_types
open Masc.Tui_decode
open Masc.Tui_decode_memory_health
open Masc_tui_ansi

module Render_schedule = Masc_tui_render_schedule
module Message_layout = Masc_tui_message_layout
module Terminal_text = Masc_tui_ansi.Terminal_text
module Theme = Masc_tui_ansi.Theme
module Rows = Masc_tui_rows
module Memory_category = Masc.Keeper_memory_os_types

let keeper_lane_idle_text seconds =
  let seconds = max 0 seconds in
  if seconds < 60 then Printf.sprintf "%ds" seconds
  else if seconds < 3600 then Printf.sprintf "%dm" (seconds / 60)
  else if seconds < 86400 then Printf.sprintf "%dh" (seconds / 3600)
  else Printf.sprintf "%dd" (seconds / 86400)

(* What the operator reads for how the last Librarian pass ended. The wire
   words name code paths ("not_committed"); these say what happened. *)
let librarian_pass_end_words = function
  | Masc.Tui_decode_memory_health.Pass_off -> "switched off"
  | Masc.Tui_decode_memory_health.Pass_lane_unconfigured -> "no model lane set up"
  | Masc.Tui_decode_memory_health.Pass_drained -> "caught up"
  | Masc.Tui_decode_memory_health.Pass_yielded_to_waiting_unit -> "yielded to waiting work"
  | Masc.Tui_decode_memory_health.Pass_not_committed -> "last pass saved nothing"
  | Masc.Tui_decode_memory_health.Pass_stopped _ -> "stopped on an error"
  | Masc.Tui_decode_memory_health.Pass_raised _ -> "crashed"

let librarian_failure_words = function
  | Masc.Tui_decode_memory_health.Failure_prompt_render -> "prompt could not be built"
  | Masc.Tui_decode_memory_health.Failure_execution_clock_unavailable -> "no clock to run on"
  | Masc.Tui_decode_memory_health.Failure_exact_setup -> "model call could not be set up"
  | Masc.Tui_decode_memory_health.Failure_exact_execution -> "model call failed"
  | Masc.Tui_decode_memory_health.Failure_domain_output_invalid -> "model answer was not usable"
  | Masc.Tui_decode_memory_health.Failure_absorb_judgment -> "copy check failed; nothing saved"
  | Masc.Tui_decode_memory_health.Failure_memory_snapshot_write -> "Memory could not be saved"
  | Masc.Tui_decode_memory_health.Failure_runtime_context_unavailable -> "no runtime context"
  | Masc.Tui_decode_memory_health.Failure_lane_cancelled -> "cancelled before saving"
  | Masc.Tui_decode_memory_health.Failure_unhandled_exception -> "unexpected crash"

(* How the facts title reads its own keeper. "*" is how the fleet view is asked
   for, not how it should be read, so the title reads it as a phrase. The title
   is drawn at every terminal size; a body row is not. *)
let facts_keeper_label = function
  | Some "*" -> "all keepers"
  | Some name -> name
  | None -> ""

(* What the title carries while the read is in flight and once it has landed.
   Typed so the two spellings cannot drift into each other's shape. The unread
   word arrives rendered, like [screen] and [badge]: whether a read is still in
   flight or came back failed is the caller's reading, and
   [Masc_tui_types.title_missing_reading] is the one place that words it. *)
type facts_reading =
  | Facts_unread of { reading : string }
  | Facts_loaded of
      { total : int
      ; filter_label : string
      ; query_label : string
      }

(* The facts title. Here beside the row under it so the two cannot disagree
   about which fact each one carries: the title says the total and the filters,
   the row says the breakdown and the sort. The title is the narrow line and the
   clock and the connection badge sit at its end, so a fact spelled here and
   there goes off the right edge.

   [screen] and [badge] arrive rendered because colour and the connection
   reading belong to the caller. The clock and the badge are the heading's
   tail and are never shortened; when the row is narrow the keeper's name
   folds to its floor, the counts and filters are cut at their end, and only
   then the name goes further ([detail_heading]). *)
let facts_title ~cols ~screen ~keeper ~reading ~timestamp ~badge =
  let after =
    match reading with
    | Facts_unread { reading } -> "  " ^ reading
    | Facts_loaded { total; filter_label; query_label } ->
      Printf.sprintf " (%s \xc2\xb7 %s%s)"
        (Masc_tui_message_layout.count_noun total "fact") filter_label
        query_label
  in
  detail_heading ~cols ~lead:(Lead_text (screen ^ " \xe2\x96\xb8 ")) ~id:keeper
    ~after ~tail:(timestamp ^ "  " ^ badge)

(* The row under the facts title. The title says the total and the filter; this
   says how that total breaks down and which sort produced the order, so each
   fact is written in one place. The split runs in this direction because the
   title is the line with no room to spare: beside the Activity pane at the
   width it opens from, the title keeps only the pane's surface floor, less
   the frame, for the screen name, the keeper, the total, both filters, the
   clock and the badge.

   [grand_total] is not passed in because it is not drawn here. *)
let facts_stats_row ~ordinary ~source ~dropped ~sort_label =
  Printf.sprintf "  %s(%d ord \xc2\xb7 %d src \xc2\xb7 %d drop)%s \xc2\xb7 %sSort [s]:%s %s"
    (Theme.recede ()) ordinary source dropped Ansi.reset
    (Theme.recede ()) Ansi.reset sort_label

let memory_fact_age_label ts =
  keeper_lane_idle_text (int_of_float (Unix.gettimeofday () -. ts))

let memory_date ts =
  let tm = Unix.localtime ts in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min

let memory_updated_text = function
  | None -> Masc_tui_theme.Glyph.no_value
  | Some ts -> memory_date ts

(* Stored JSON bytes are not model input and cannot establish a token count.
   The Context inspector carries observed per-turn prompt block bytes. *)
let storage_size bytes =
  if bytes >= 1024 * 1024 then Printf.sprintf "%.1f MiB" (float bytes /. 1048576.)
  else if bytes >= 1024 then Printf.sprintf "%.1f KiB" (float bytes /. 1024.)
  else Printf.sprintf "%d B" bytes
;;
(* One break, and no more. The block sits under the list and is paid for out
   of the same frame, so a reading never takes more than two rows. At a
   terminal wide enough to draw the roster, the Librarian row and an alert
   each need one break; a narrower one folds the middle (see [clause_rows]). *)
let maximum_rows_for_a_reading = 2

(* A row of the keeper block, given as its clauses rather than as the joined
   string: [pack_clauses] keeps a clause whose own text holds the mark whole,
   which it cannot do for a row that has already been joined. The block was
   drawn one row per reading and cut at the frame: the Librarian row lost
   "failed N since server start", the tail #36497 records as reading like a
   running total, and a server alert lost the half that says what to do about
   it.

   An alert is one sentence and arrives as one clause; [pack_clauses] wraps a
   clause too wide for a row rather than cutting it. Continuation rows carry
   the same two-space indent as the first.

   A reading that packs into more rows than the block pays for keeps its
   first row and its last, with the cut mark between them, the way a roster
   name folds its middle (#38469). The first row says which reading it is;
   the last holds the clause that changes what the others mean. Joined back
   into one row instead, the frame cut that tail again -- at 80 columns, the
   commonest terminal, the Librarian row still ended "failed N". The fold
   draws exactly two rows, so it holds for any [maximum_rows_for_a_reading]
   of two or more. *)
let clause_rows ~cols clauses =
  let indent = "  " in
  let fold = Message_layout.cut_mark ^ " " in
  let lead_cells =
    max (Message_layout.display_width indent) (Message_layout.display_width fold)
  in
  let rows =
    Message_layout.pack_clauses
      ~max_cells:(max 1 (framed_inner_width cols - lead_cells))
      clauses
  in
  match rows with
  | first :: rest when List.length rows > maximum_rows_for_a_reading ->
    let last = List.fold_left (fun _ row -> row) first rest in
    [ indent ^ first; fold ^ last ]
  | rows -> List.map (fun row -> indent ^ row) rows

(* #39831: what the block under the selected keeper draws before the operator
   asks for detail. The operator's first question is whether this keeper's
   memory can be used now and whether there is something to do; the ledger
   coordinates (revision, atoms, trace, recall size, source-bound snapshot,
   the context cycle) answer a developer's question and wait behind [d].
   A reading that did not come back is an action, never a zero: an unread lag
   and a read error stay on the default view. *)
type memory_row_kind =
  | Row_state
  | Row_last_saved
  | Row_ledger
  | Row_lag of int option
  | Row_librarian_failures of int
  | Row_vision_errors of int
  | Row_stalled
  | Row_cause
  | Row_read_error
  | Row_alert

type memory_row_visibility =
  | Shown_by_default
  | Detail_only

let memory_row_visibility = function
  | Row_state | Row_last_saved | Row_stalled | Row_cause | Row_read_error | Row_alert ->
    Shown_by_default
  | Row_lag None -> Shown_by_default
  | Row_lag (Some behind) -> if behind > 0 then Shown_by_default else Detail_only
  | Row_librarian_failures failed -> if failed > 0 then Shown_by_default else Detail_only
  | Row_ledger | Row_vision_errors _ -> Detail_only

let shown_by_default kind =
  match memory_row_visibility kind with
  | Shown_by_default -> true
  | Detail_only -> false

type memory_context_projection =
  { rows : string list
  ; stalled_row : (int * string) option
  }

let memory_context_lines ~cols ~detail (k : Masc.Tui_decode_memory_health.memory_keeper_health) =
  let current_line =
    Printf.sprintf "  %s · %s · snapshot r%d · stored %s · updated %s"
      k.mkh_keeper_id (memory_state_label (memory_state k)) k.mkh_revision
      (storage_size k.mkh_snapshot_bytes)
      (memory_updated_text k.mkh_updated_at)
  in
  let facts_line =
    Printf.sprintf
      "  facts %d (observed %d / derived %d) · last change +%d / -%d / support-invalidated %d"
      k.mkh_facts k.mkh_observed_facts k.mkh_derived_facts k.mkh_added
      k.mkh_removed k.mkh_support_invalidations
  in
  (* RFC librarian-lifecycle §4.9: how far behind, when that was counted,
     and what the journal last said. A count the durable drain could not take prints
     as "unread ?" rather than as zero. *)
  let librarian = k.mkh_librarian in
  let unread_lag =
    match librarian.mlh_unread_atom_turns, librarian.mlh_unread_official_turns with
    | Some atoms, Some official -> Some (atoms + official)
    | Some _, None | None, Some _ | None, None -> None
  in
  let unread =
    match unread_lag with
    | Some behind -> Printf.sprintf "unread %d" behind
    | None -> "unread ?"
  in
  (* The two rounds fall behind separately, so the continuity lag prints
     beside the drain's count rather than folded into it. "?" is its own
     reading: no snapshot, an unreadable one, or one from another trace. *)
  let continuity =
    match librarian.mlh_continuity_unread_atoms with
    | Some atoms -> Printf.sprintf "continuity behind %d" atoms
    | None -> "continuity behind ?"
  in
  let memory_saved = "Memory saved " ^ memory_updated_text librarian.mlh_last_success_at in
  let last_failure =
    "last failure "
    ^ (match librarian.mlh_last_failure_kind with
       | Some kind -> librarian_failure_words kind
       | None -> Masc_tui_theme.Glyph.no_value)
  in
  let failed = Printf.sprintf "failed %d since server start" k.mkh_librarian_failures in
  let librarian_clauses =
    [ "Librarian"
    ; (match librarian.mlh_state with
       | Some state -> librarian_pass_end_words state
       | None -> "not measured")
    ; unread
    ; continuity
    ; "measured " ^ memory_updated_text librarian.mlh_measured_at
    ; memory_saved
    ; last_failure
    ; failed
    ]
  in
  (* RFC librarian-lifecycle §4.10: the atoms requests skip while the
     Librarian stands behind the start the provider last accepted. An alarm,
     not a state anything waits on. On its own row, under the Librarian line,
     so the frame cutting a long Librarian line never cuts its atom numbers.
     A file the gap is read from that did not read gets the same row, naming
     which file: it is neither "no gap" nor a gap. *)
  let librarian_stalled_lines =
    match k.mkh_librarian.mlh_stalled with
    | Some (Masc.Tui_decode_memory_health.Stalled_gap { mls_gap_start_atom; mls_gap_end_atom }) ->
      let atoms =
        if mls_gap_end_atom - mls_gap_start_atom = 1
        then Printf.sprintf "atom %d is" mls_gap_start_atom
        else Printf.sprintf "atoms %d-%d are" mls_gap_start_atom (mls_gap_end_atom - 1)
      in
      [ Printf.sprintf "  Librarian stalled · %s in neither the request nor memory" atoms ]
    | Some (Masc.Tui_decode_memory_health.Stalled_unmeasured { mls_cause; mls_detail }) ->
      let cause =
        match mls_cause with
        | Masc.Tui_decode_memory_health.Stall_meta_unreadable -> "keeper meta unreadable"
        | Masc.Tui_decode_memory_health.Stall_turn_records_unreadable -> "turn records unreadable"
        | Masc.Tui_decode_memory_health.Stall_turn_boundary_refused -> "turn boundaries unreadable"
        | Masc.Tui_decode_memory_health.Stall_snapshot_unreadable -> "continuity snapshot unreadable"
        | Masc.Tui_decode_memory_health.Stall_read_position_unreadable -> "read position unreadable"
      in
      [ Printf.sprintf "  Librarian stalled · not measured, %s · %s" cause
          (Terminal_text.preview_line mls_detail) ]
    | None -> []
  in
  let librarian_cause_lines =
    (* The cause is drawn on its own row because it is the part of the
       Librarian row an operator acts on. *)
    match Option.bind k.mkh_librarian.mlh_state Masc.Tui_decode_memory_health.memory_librarian_pass_end_cause with
    | Some cause -> [ "  Librarian cause · " ^ Terminal_text.preview_line cause ]
    | None -> []
  in
  let context_lines =
    let cycle = k.mkh_context_cycle in
    let frontier value = Printf.sprintf "atom %d / boundary %d · trace %s"
      value.mcf_end_atom value.mcf_boundary_line (Terminal_text.single_line value.mcf_trace_id) in
    let saved =
      let cut = match cycle.mcc_saved with
        | Some value -> frontier value
        | None -> if cycle.mcc_saved_unreadable then "unreadable" else "absent" in
      (* Where the Librarian has read to belongs beside the cut, not on a line
         of its own: a request starts at the cut and carries the atoms up to
         the position, so the two apart is what the turn pays (#37793). *)
      let read = match cycle.mcc_read_position, cycle.mcc_saved with
        | None, _ ->
          if cycle.mcc_read_position_unreadable
          then " · read position unreadable"
          else " · nothing read yet"
        | Some position, Some value when position > value.mcf_end_atom ->
          Printf.sprintf " · read to atom %d, %s past the cut" position
            (Masc_tui_message_layout.count_noun
               (position - value.mcf_end_atom) "atom")
        | Some position, Some _ | Some position, None ->
          Printf.sprintf " · read to atom %d" position in
      let rewriting = match cycle.mcc_rewriting_through with
        | None -> ""
        | Some through ->
          Printf.sprintf " · rewriting from atom 0, unused until atom %d" through in
      cut ^ read ^ rewriting in
    let prepared, input = match cycle.mcc_prepared with
      | None -> "not observed since server start", "not observed"
      | Some value ->
        let input = match value.mcp_input with
          | Masc.Tui_decode_memory_health.Context_summarized value -> "summary " ^ frontier value
          | Masc.Tui_decode_memory_health.Context_absorbed value ->
            Printf.sprintf "absorbed to atom %d · trace %s · no summary"
              value.mcpo_end_atom (Terminal_text.single_line value.mcpo_trace_id)
          | Masc.Tui_decode_memory_health.Context_without_snapshot -> "no snapshot: this turn only"
          | Masc.Tui_decode_memory_health.Context_not_applied -> "saved context not applied" in
        (* The size as a size. The row drew the digit count -- one live block
           read "446558 request bytes" -- while every other size on this TUI
           goes through the shared ladder and reads "436.1 KB". The heading a
           line above already says what was prepared, so the figure needs no
           noun of its own. *)
        Printf.sprintf "%s · %s · %s"
          (memory_updated_text (Some value.mcp_prepared_at))
          (Masc_tui_context_inspector.format_bytes value.mcp_request_bytes)
          (Terminal_text.single_line value.mcp_runtime_id), input in
    let synthesis = match cycle.mcc_synthesis with
      | None -> "not observed since server start"
      | Some value ->
        let module O = Masc.Keeper_continuity_observation in
        let state = match value.state with
          | O.No_source -> "no new completed source (coverage not inferred)"
          | state -> O.synthesis_state_to_string state in
        let range = match value.range with
          | None -> " · atom range unavailable"
          | Some range -> Printf.sprintf " · last selected atoms [%d,%d) / observed completed %d"
              range.start_atom range.end_atom range.completed_end_atom in
        state ^ range ^ " · " ^ memory_updated_text (Some value.observed_at) in
    ["  Context synthesis · " ^ synthesis;
     "  Context saved · " ^ saved;
     "  Request prepared (not provider success) · " ^ prepared;
     "  Context used · " ^ input]
  in
  let source_line =
    Printf.sprintf
      "  source-bound snapshot r%d · facts %d · invalidations %d · stored %s · %s"
      k.mkh_source_revision k.mkh_source_facts k.mkh_source_invalidations
      (storage_size k.mkh_source_snapshot_bytes)
      (if k.mkh_source_snapshot_present then "present" else "absent")
  in
  let vision_line =
    let reasons =
      match k.mkh_vision_ingest_error_reasons with
      | [] -> "none"
      | reasons ->
        String.concat ", "
          (List.map
             (fun (reason, count) -> Printf.sprintf "%s x%d" reason count)
             reasons)
    in
    Printf.sprintf "  vision ingest errors %d · reasons %s"
      k.mkh_vision_ingest_errors reasons
  in
  let alert_lines =
    List.map
      (fun (a : Masc.Tui_decode_memory_health.memory_alert) ->
        Printf.sprintf "[%s] %s \xe2\x80\x94 %s"
          ((if Masc.Tui_decode_memory_health.memory_alert_is_history a.ma_code
            then "history " else "")
           ^ (match Masc.Tui_decode_memory_health.memory_alert_severity a.ma_code with
              | `Warn -> "warn"
              | `Error -> "error"))
          a.ma_label
          (Terminal_text.single_line a.ma_message))
      k.mkh_alerts
  in
  let read_error_lines =
    List.filter_map Fun.id
      [ Option.map
          (fun message ->
            "  ordinary read error: " ^ Terminal_text.single_line message)
          k.mkh_read_error
      ; Option.map
          (fun message ->
            "  source-bound read error: " ^ Terminal_text.single_line message)
          k.mkh_source_read_error
      ]
  in
  (* Only the rows whose tail changes what the row claims are broken. The
     Librarian row ends in "failed N since server start", and a cut leaves
     "failed N", which reads as a running total (#36497); an alert is one
     sentence from the server and a cut takes the half that says what to do.
     The readings around them end in a timestamp or a byte count, where a cut
     costs a value rather than the meaning of the ones before it, and
     breaking every row would double the block at the widths a terminal is
     likely to have. *)
  let alert_rows =
    List.concat_map (fun sentence -> clause_rows ~cols [ sentence ]) alert_lines
  in
  let rows =
    if detail
    then
      [ current_line; facts_line; source_line;
        "  Turn recall bytes: open Keeper chat /context; Librarian status is memory processing, not Keeper execution." ]
      @ clause_rows ~cols librarian_clauses
      @ librarian_stalled_lines
      @ librarian_cause_lines @ context_lines
      @ (vision_line :: read_error_lines)
      @ alert_rows
    else begin
      (* One status row: the keeper, its state word, and when memory was last
         saved -- the Librarian's success time, not the snapshot file's, which
         changes without a save succeeding. The action rows follow only when
         [memory_row_visibility] lets them through. *)
      let status_row =
        Printf.sprintf "  %s · memory %s · %s" k.mkh_keeper_id
          (memory_state_label (memory_state k)) memory_saved
      in
      let when_shown kind clauses = if shown_by_default kind then clauses else [] in
      let librarian_action_rows =
        match
          when_shown (Row_lag unread_lag) [ unread ]
          @ when_shown (Row_lag librarian.mlh_continuity_unread_atoms) [ continuity ]
          @ when_shown (Row_librarian_failures k.mkh_librarian_failures)
              [ last_failure; failed ]
        with
        | [] -> []
        | clauses -> clause_rows ~cols ("Librarian" :: clauses)
      in
      [ status_row ]
      @ librarian_action_rows
      @ librarian_stalled_lines
      @ librarian_cause_lines
      @ read_error_lines
      @ alert_rows
    end
  in
  { rows
  ; stalled_row =
      (match librarian_stalled_lines with
       | row :: _ ->
         Option.map (fun index -> index, row) (List.find_index (String.equal row) rows)
       | [] -> None)
  }

type memory_state = Masc_tui_types.memory_state =
  | Memory_ordinary | Memory_warning | Memory_degraded | Memory_no_current
  | Memory_source_only | Memory_starving | Memory_read_error

(* The glyph and the word for it are one module, so the column below and the
   [?] sheet cannot spell the same state two ways. *)
let memory_state_cell = Masc_tui_memory_mark.glyph

let memory_deviation_style (k : Masc.Tui_decode_memory_health.memory_keeper_health) =
  let server_error =
    List.exists
      (fun alert ->
        if Masc.Tui_decode_memory_health.memory_alert_is_history alert.ma_code then false
        else match Masc.Tui_decode_memory_health.memory_alert_severity alert.ma_code with
        | `Error -> true
        | `Warn -> false)
      k.mkh_alerts
  in
  if server_error then Some (Theme.bad ())
  else
    match memory_state k with
    | Memory_starving -> Some (Theme.bad ())
    | Memory_read_error
    | Memory_no_current
    | Memory_source_only
    | Memory_degraded
    | Memory_warning ->
        Some (Theme.warn ())
    | Memory_ordinary -> None

let memory_row_line columns (k : Masc.Tui_decode_memory_health.memory_keeper_health) =
  let no_value = Masc_tui_theme.Glyph.no_value in
  let ordinary_reading value = if k.mkh_snapshot_present then value () else no_value in
  let source =
    if Option.is_some k.mkh_source_read_error then "read error"
    else if k.mkh_source_snapshot_present then
      Printf.sprintf "r%d i%d %s" k.mkh_source_revision
        k.mkh_source_invalidations
        (storage_size k.mkh_source_snapshot_bytes)
    else no_value
  in
  let delta =
    match k.mkh_added, k.mkh_removed with
    | 0, 0 -> ""
    | added, 0 -> Printf.sprintf "+%d" added
    | 0, removed -> Printf.sprintf "-%d" removed
    | added, removed -> Printf.sprintf "+%d -%d" added removed
  in
  let deviation = Option.value (memory_deviation_style k) ~default:"" in
  let state_style = deviation in
  let size_style = if k.mkh_snapshot_present then "" else deviation in
  let delta_style = if k.mkh_removed > 0 then Theme.warn () else "" in
  "  "
  ^ Render_schedule.memory_row ~state_style ~size_style ~delta_style columns
      { Render_schedule.mrow_state = memory_state_cell (memory_state k)
      ; mrow_name = k.mkh_keeper_id
      ; mrow_updated = memory_updated_text k.mkh_updated_at
      ; mrow_facts = ordinary_reading (fun () -> string_of_int k.mkh_facts)
      ; mrow_size =
          ordinary_reading (fun () -> storage_size k.mkh_snapshot_bytes)
      ; mrow_source = source
      ; mrow_delta = delta
      }

(* What a row wears in its first cell. The category is the librarian
   label the producer writes ([Keeper_memory_os_types.category]); the other two are this
   pane's own words for rows that are not ordinary facts, and the call sites
   know which they are drawing, so they say so rather than handing over a
   string to be recognised. *)
type memory_row_badge =
  | Badge_category of Memory_category.category
  | Badge_source
  | Badge_dropped

(* The word comes from [category_to_string], the one place that spells the
   taxonomy, so the badge, the category strip and the detail all read one
   value. A table used to answer both the word and its colour by matching the
   string: across the fleet's 1768 facts it recognised 749 and let 1019 fall
   through a catch-all, nine of its eleven spellings matched nothing any
   keeper writes, and [preference] was renamed to PREF on the row while the
   detail under it read "preference".

   Only [Blocker] is dressed, because it is the one category whose name is an
   alarm; the table used to draw it in the same receded style as every word it
   did not know. The rest share one style: which of them matters is the
   reader's question, not this cell's. *)
let format_row_badge badge =
  let cat_style, label =
    match badge with
    | Badge_source -> (Theme.info (), "SOURCE")
    | Badge_dropped -> (Theme.bad (), "DROPPED")
    | Badge_category category ->
        let style =
          match category with
          | Memory_category.Blocker -> Theme.warn ()
          | Memory_category.Code_change | Memory_category.Fact
          | Memory_category.Preference | Memory_category.Goal
          | Memory_category.Constraint | Memory_category.Validated_approach
          | Memory_category.Lesson | Memory_category.Custom _ ->
              Theme.recede ()
        in
        ( style
        , String.uppercase_ascii
            (Memory_category.category_to_string category) )
  in
  let cat_str =
    if Message_layout.display_width label > 10 then
      match badge with
      | Badge_category (Memory_category.Custom _) ->
          Message_layout.take_cells label 4 ^ "\xe2\x80\xa6"
          ^ Message_layout.drop_cells label (Message_layout.display_width label - 5)
      | Badge_category _ | Badge_source | Badge_dropped ->
          Message_layout.take_cells label 9 ^ "\xe2\x80\xa6"
    else label
  in
  let pad = String.make (max 0 (10 - Message_layout.display_width cat_str)) ' ' in
  Printf.sprintf "%s%s[%s%s]%s" Ansi.bold cat_style cat_str pad Ansi.reset

let memory_fact_row_line ?(is_fleet = false) ~cols (row : memory_fact_row) =
  let inner_width = max 10 (framed_inner_width cols) in
  let keeper_prefix =
    if not is_fleet then ""
    else
      let keeper =
        match row with
        | Memory_row_fact fact ->
            (match String.index_opt fact.mf_origin ' ' with
             | Some idx when idx > 0 -> String.sub fact.mf_origin 0 idx
             | _ -> if String.trim fact.mf_origin <> "" then fact.mf_origin else "fleet")
        | Memory_row_source_fact fact ->
            (match String.split_on_char ':' fact.msf_path with
             | k :: _ when String.trim k <> "" -> String.trim k
             | _ -> "fleet")
        | Memory_row_invalidation row ->
            (match String.split_on_char ':' row.mi_source_path with
             | k :: _ when String.trim k <> "" -> String.trim k
             | _ -> "fleet")
      in
      let clean = Terminal_text.single_line keeper in
      let truncated =
        if Message_layout.display_width clean > 8 then
          Message_layout.take_cells clean 7 ^ "\xe2\x80\xa6"
        else clean
      in
      let pad = String.make (max 0 (8 - Message_layout.display_width truncated)) ' ' in
      Printf.sprintf "%s[%s%s]%s " (Theme.info ()) truncated pad Ansi.reset
  in
  let keeper_cells = if is_fleet then 11 else 0 in
  match row with
  | Memory_row_fact fact ->
      let cat_badge = format_row_badge (Badge_category fact.mf_category) in
      let age = memory_fact_age_label fact.mf_last_seen in
      let age_badge = Printf.sprintf "%s%6s%s" (Theme.recede ()) age Ansi.reset in
      let prefix = Printf.sprintf "  %s%s %s " keeper_prefix cat_badge age_badge in
      let prefix_cells = 2 + keeper_cells + 12 + 1 + 6 + 1 in
      let claim_budget = max 4 (inner_width - prefix_cells) in
      let claim = Terminal_text.single_line fact.mf_claim in
      let claim_display =
        if Message_layout.display_width claim > claim_budget then
          if claim_budget > 1 then
            Message_layout.take_cells claim (claim_budget - 1) ^ "\xe2\x80\xa6"
          else Message_layout.take_cells claim claim_budget
        else claim
      in
      prefix ^ claim_display
  | Memory_row_source_fact fact ->
      let cat_badge = format_row_badge Badge_source in
      let age = memory_fact_age_label fact.msf_first_seen in
      let age_badge = Printf.sprintf "%s%6s%s" (Theme.recede ()) age Ansi.reset in
      let raw_path =
        if is_fleet then
          match String.split_on_char ':' fact.msf_path with
          | _ :: rest -> String.concat ":" rest
          | [] -> fact.msf_path
        else fact.msf_path
      in
      let path_raw = Terminal_text.single_line raw_path in
      let path_width = Message_layout.display_width path_raw in
      let path_str =
        if path_width > 16 then
          "\xe2\x80\xa6" ^ Message_layout.drop_cells path_raw (path_width - 15)
        else path_raw
      in
      let pad = String.make (max 0 (16 - Message_layout.display_width path_str)) ' ' in
      let path_badge = Printf.sprintf "%s%s%s%s" (Theme.info ()) path_str pad Ansi.reset in
      let prefix = Printf.sprintf "  %s%s %s %s " keeper_prefix cat_badge age_badge path_badge in
      let prefix_cells = 2 + keeper_cells + 12 + 1 + 6 + 1 + 16 + 1 in
      let claim_budget = max 4 (inner_width - prefix_cells) in
      let claim = Terminal_text.single_line fact.msf_claim in
      let claim_display =
        if Message_layout.display_width claim > claim_budget then
          if claim_budget > 1 then
            Message_layout.take_cells claim (claim_budget - 1) ^ "\xe2\x80\xa6"
          else Message_layout.take_cells claim claim_budget
        else claim
      in
      prefix ^ claim_display
  | Memory_row_invalidation row ->
      let cat_badge = format_row_badge Badge_dropped in
      let age = memory_fact_age_label row.mi_invalidated_at in
      let age_badge = Printf.sprintf "%s%6s%s" (Theme.recede ()) age Ansi.reset in
      let raw_path =
        if is_fleet then
          match String.split_on_char ':' row.mi_source_path with
          | _ :: rest -> String.concat ":" rest
          | [] -> row.mi_source_path
        else row.mi_source_path
      in
      let path_raw = Terminal_text.single_line raw_path in
      let path_width = Message_layout.display_width path_raw in
      let path_str =
        if path_width > 16 then
          "\xe2\x80\xa6" ^ Message_layout.drop_cells path_raw (path_width - 15)
        else path_raw
      in
      let pad = String.make (max 0 (16 - Message_layout.display_width path_str)) ' ' in
      let path_badge = Printf.sprintf "%s%s%s%s" (Theme.recede ()) path_str pad Ansi.reset in
      let prefix = Printf.sprintf "  %s%s %s %s " keeper_prefix cat_badge age_badge path_badge in
      let prefix_cells = 2 + keeper_cells + 12 + 1 + 6 + 1 + 16 + 1 in
      let claim_budget = max 4 (inner_width - prefix_cells) in
      let reason = Terminal_text.single_line row.mi_reason in
      let reason_display =
        if Message_layout.display_width reason > claim_budget then
          if claim_budget > 1 then
            Message_layout.take_cells reason (claim_budget - 1) ^ "\xe2\x80\xa6"
          else Message_layout.take_cells reason claim_budget
        else reason
      in
      prefix ^ reason_display

(* One label column for the three detail blocks. They take turns in the same
   rows as the cursor moves down the list, and each line padded its own label
   by hand -- "Reason:" and five spaces, "Source Path:" and one -- so a dropped
   fact put its values a cell right of an ordinary fact's, and its own Reason
   a cell left of the Source Path under it. The column is sized by the
   longest label any block draws, so stepping from one kind of row to another
   leaves the values where they were. A longer label still gets its space. *)
let detail_label_cells = Message_layout.display_width "Source Path:" + 1

let detail_label label =
  Printf.sprintf "%s%s%s%s" (Theme.recede ()) label Ansi.reset
    (String.make
       (max 1 (detail_label_cells - Message_layout.display_width label))
       ' ')

let detail_field ~width label value =
  let indent = String.make (min 4 (max 0 (width - 1))) ' ' in
  let prefix = indent ^ detail_label label in
  let prefix_cells = Message_layout.display_width prefix in
  if prefix_cells < width then
    Message_layout.wrap_words ~max_cells:(width - prefix_cells) value
    |> List.mapi (fun index line ->
         (if index = 0 then prefix else String.make prefix_cells ' ') ^ line)
  else
    (* When the label leaves no value cell, it owns a row and the value
       uses the whole remaining width under the indentation. *)
    (Message_layout.wrap_words
       ~max_cells:(max 1 (width - Message_layout.display_width indent)) label
     |> List.map (fun line -> indent ^ Theme.recede () ^ line ^ Ansi.reset))
    @ (Message_layout.wrap_words
         ~max_cells:(max 1 (width - Message_layout.display_width indent)) value
       |> List.map (fun line -> indent ^ line))

(* A claim is prose a Keeper wrote, often paragraphs and a numbered list. The
   list rows fold it to one line because a row has one line to give it; the
   detail pane has the height, so it keeps the claim's own breaks. Each line is
   escaped on its own -- escaping the whole claim turns every newline into a
   printed \x0A (#37017) -- and wrapped at spaces, so a word is not cut in two
   at the pane's edge. A blank line stays a blank row: it is a paragraph break,
   not an absence. *)
let detail_claim_lines ?state ~inner_width claim =
  let wrap () =
    let lines =
      let indent = String.make (min 4 (max 0 (inner_width - 1))) ' ' in
      Message_layout.wrap_body
        ~max_cells:(max 1 (inner_width - Message_layout.display_width indent))
        ~sanitize:Terminal_text.single_line claim
      |> List.map (fun line -> if String.equal line "" then "" else indent ^ line)
    in
    let count = List.length lines in
    Option.iter
      (fun (state : state) ->
        state.memory_fact_claim_wrap <- Some (claim, inner_width, lines, count))
      state;
    lines, count
  in
  match state with
  | Some state ->
      (match state.memory_fact_claim_wrap with
       | Some (source, width, lines, count)
         when source == claim && width = inner_width -> lines, count
       | Some _ | None -> wrap ())
  | None -> wrap ()

type fact_detail_parts = {
  heading : string;
  claim_lines : string list;
  claim_line_count : int;
  other_lines : string list;
}

let memory_fact_detail_parts ?state ~cols (row : memory_fact_row) =
  let width = max 1 (framed_inner_width cols) in
  let field = detail_field ~width in
  match row with
  | Memory_row_fact fact ->
      let claim_lines, claim_line_count =
        detail_claim_lines ?state ~inner_width:width fact.mf_claim
      in
      let history =
        (* The retrieval count, its day count and its last clock are one
           reading: the server derives all three from the same list of
           retrieval times, and the decoder keeps them as one value. A fact
           nobody has read draws the single phrase "Never retrieved".

           [Retracted] and [Revised from] keep their zeros. Both are measured
           counts the server always sends, and hiding a measured zero makes it
           read as "not measured" -- the shape RFC-0462 closed. *)
        let read =
          match fact.mf_events.mfe_retrieval with
          | Never_retrieved -> "Never retrieved"
          | Retrieved { count; distinct_days; last_at } ->
              Printf.sprintf "Retrieved %d on %s · last %s" count
                (Message_layout.count_noun distinct_days "day")
                (memory_fact_age_label last_at)
        in
        Printf.sprintf "%s · Retracted %d · Revised from %d" read
          fact.mf_events.mfe_retracted_count
          (List.length fact.mf_events.mfe_revised_from)
      in
      let history_lines = field "History:" history in
      { heading =
          Printf.sprintf "  %s%sFact Detail%s" Ansi.bold (Theme.info ()) Ansi.reset
      ; claim_lines
      ; claim_line_count
      ; other_lines =
        (* The word comes from [Keeper_memory_os_types.category], a closed
             set this build spells itself, so it is printed rather than
             escaped: there is no wire text left in it to escape. *)
        field "Category:" (Memory_category.category_to_string fact.mf_category)
          (* Two labelled readings used to share this row, the first in a
             hand-sized slot of fifteen cells. Every other field in this pane
             owns a row, and the slot was a guess: in the fleet reading the
             origin carries its keeper, and the shortest keeper name in the
             fleet already makes it seventeen bytes, so "Timeline:" lost the
             space before it on every row. Printf's width counts bytes as
             well, which the middle dot in that reading is three of. *)
        @ field "Origin:" (Terminal_text.single_line fact.mf_origin)
        @ field "Timeline:"
            (Printf.sprintf "First: %s \xc2\xb7 Last: %s"
               (memory_fact_age_label fact.mf_first_seen)
               (memory_fact_age_label fact.mf_last_seen))
        @ history_lines
        @ field "Memory ID:" (Terminal_text.single_line fact.mf_memory_id)
      }
  | Memory_row_source_fact fact ->
      let claim_lines, claim_line_count =
        detail_claim_lines ?state ~inner_width:width fact.msf_claim
      in
      { heading =
          Printf.sprintf "  %s%sSource-Bound Fact Detail%s" Ansi.bold
            (Theme.info ()) Ansi.reset
      ; claim_lines
      ; claim_line_count
      ; other_lines =
        field "Bound Path:" (Terminal_text.single_line fact.msf_path)
        @ field "File SHA:"
            (Printf.sprintf "%s · %sFirst Seen:%s %s" 
               (Terminal_text.single_line fact.msf_sha256)
               (Theme.recede ()) Ansi.reset
               (memory_fact_age_label fact.msf_first_seen))
      }
  | Memory_row_invalidation row ->
      { heading =
          Printf.sprintf "  %s%sDropped / Invalidated Fact%s" Ansi.bold
            (Theme.bad ()) Ansi.reset
      ; claim_lines = []
      ; claim_line_count = 0
      ; other_lines =
        field "Reason:" (Terminal_text.single_line row.mi_reason)
        @ field "Source Path:" (Terminal_text.single_line row.mi_source_path)
        @ field "Dropped At:"
            (memory_fact_age_label row.mi_invalidated_at ^ " ago")
      }

let fact_detail_line_count parts =
  1 + parts.claim_line_count + List.length parts.other_lines

let first_lines count lines =
  let rec collect remaining kept = function
    | _ when remaining <= 0 -> List.rev kept
    | [] -> List.rev kept
    | line :: rest -> collect (remaining - 1) (line :: kept) rest
  in
  collect count [] lines

let fact_detail_prefix parts count =
  if count <= 0 then []
  else
    let claim_kept = min parts.claim_line_count (count - 1) in
    parts.heading
    :: (first_lines claim_kept parts.claim_lines
       @ first_lines (count - 1 - claim_kept) parts.other_lines)

let memory_fact_detail_lines ~cols row =
  let parts = memory_fact_detail_parts ~cols row in
  fact_detail_prefix parts (fact_detail_line_count parts)

(* The fleet header above the sort row: the Total, Ordinary and Librarian
   readings, each wrapped to the frame. Its row count depends on the width, so
   the list's height is worked out from these same rows ([memory_overview_scrolled])
   rather than from a fixed count of header lines. *)
let memory_fleet_header_rows ~cols (state : state) : string list =
  (* A failed first read has no counts. The error row below owns the cause;
     keep these two labelled values unavailable without repeating its verdict.
     An unread first visit still says what it is waiting for. *)
  let missing_reading waiting =
    if Option.is_some state.memory_health_error
    then Masc_tui_theme.Glyph.no_value
    else waiting
  in
  (* Every reading in this header is a labelled row that asks the frame for its
     width. The row that carried the Ordinary and Librarian readings together
     needed 176 cells with every count a single digit, while the frame gives 96
     at the 100 columns the PTY harness opens and 136 at 140 -- so it was cut
     mid-word at every width a terminal is likely to have, and the tail it lost
     was the one saying the failure count restarts with the server. A cut count
     reads as a running total. A count is not a thing to spell halfway.

     The shape is the one this file already uses for the History field: wrap at
     the width the label leaves, continuation rows hanging under the label so a
     row starting with a number still has its subject above it. The break is a
     clause mark rather than any space, because "0 failures since server start"
     and "0 failures" are different claims (#36497). *)
  let labelled label clauses =
    let prefix = "  " ^ label ^ " " in
    let prefix_cells = Message_layout.display_width prefix in
    let room = max 1 (framed_inner_width cols - prefix_cells) in
    Message_layout.pack_clauses ~max_cells:room clauses
    |> List.mapi (fun index line ->
           (if index = 0 then prefix else String.make prefix_cells ' ') ^ line)
  in
  let total =
    match state.memory_health with
    | None -> [ "  Total: " ^ missing_reading "waiting for memory snapshots" ]
    | Some snapshot ->
       labelled "Total"
         [ Masc_tui_message_layout.count_noun
             (snapshot.mhs_total_facts + snapshot.mhs_total_source_facts) "fact"
         ; Printf.sprintf "%d ordinary + %d source"
             snapshot.mhs_total_facts snapshot.mhs_total_source_facts
         ; Printf.sprintf "stored %s"
             (storage_size
                (snapshot.mhs_total_snapshot_bytes + snapshot.mhs_total_source_snapshot_bytes))
         ; Masc_tui_message_layout.count_noun (List.length snapshot.mhs_keepers) "keeper"
         ; "storage, not turn input"
         ]
  in
  let readings =
    match state.memory_health with
    | None -> [ "  Librarian: " ^ missing_reading "waiting for health data" ]
    | Some snapshot ->
       (* Every count spells its own noun: each of these reads 1 on an
          ordinary day, and the line said "1 keepers", "1 atoms",
          "1 failures". The unread turns keep "?" when nothing measured
          them, which is not a count and cannot take a noun from one. *)
       labelled "Ordinary:"
         [ Printf.sprintf "%d observed / %d derived"
             snapshot.mhs_total_observed_facts snapshot.mhs_total_derived_facts
         ; Masc_tui_message_layout.count_noun
             snapshot.mhs_total_support_invalidations "support invalidation"
         ]
       @ labelled "Librarian:"
         [ (match snapshot.mhs_total_librarian_unread_turns with
            | None -> "? turns"
            | Some turns -> Masc_tui_message_layout.count_noun turns "turn")
           ^ " unread"
         ; Printf.sprintf "%s behind in continuity (%s not measured)"
             (Masc_tui_message_layout.count_noun
                snapshot.mhs_total_librarian_continuity_unread_atoms "atom")
             (Masc_tui_message_layout.count_noun
                snapshot.mhs_total_librarian_continuity_unmeasured "keeper")
         ; Masc_tui_message_layout.count_noun
             snapshot.mhs_total_librarian_failures "failure"
           ^ " since server start"
         ]
  in
  total @ readings


(* Both counts are the length of what this module draws: the fleet header
   above the list, and the selected keeper's block below it. Neither is a
   count of readings -- a reading breaks into as many rows as the frame
   gives it. *)
(* The header and selected Keeper's detail share one finite body with the
   roster. If their wrapped rows do not fit, show both ends when there is room
   and say how many rows are hidden. A one-row slot shows only that omission,
   rather than pretending that a clipped alert is complete. *)
let fold_memory_rows ~subject ~max_rows rows =
  let count = List.length rows in
  if count <= max_rows then rows
  else if max_rows <= 0 then []
  else
    let leading = (max_rows - 1) / 2 in
    let trailing = max_rows - 1 - leading in
    let hidden = count - leading - trailing in
    let note =
      Printf.sprintf "  … %d %s rows hidden; enlarge terminal" hidden subject
    in
    List.filteri (fun index _ -> index < leading) rows
    @ [ note ]
    @ List.filteri (fun index _ -> index >= count - trailing) rows

(* A stalled gap is the actionable reading in the selected Keeper's block.
   Keep its typed row when the body budget folds the surrounding detail; the
   generic first/last fold could otherwise hide it in the middle. *)
let fold_memory_context_rows ~max_rows context =
  let rows = context.rows in
  let count = List.length rows in
  match context.stalled_row with
  | None -> fold_memory_rows ~subject:"Keeper detail" ~max_rows rows
  | Some _ when count <= max_rows -> rows
  | Some _ when max_rows <= 1 ->
    fold_memory_rows ~subject:"Keeper detail" ~max_rows rows
  | Some (stalled_index, stalled_row) ->
    let extra = max_rows - 2 in
    let before = min stalled_index (extra / 2) in
    let after = min (count - stalled_index - 1) (extra - before) in
    let before = min stalled_index (extra - after) in
    let hidden = count - before - after - 1 in
    let note =
      Printf.sprintf "  … %d Keeper detail rows hidden; enlarge terminal" hidden
    in
    List.filteri (fun index _ -> index < before) rows
    @ [ note; stalled_row ]
    @ List.filteri (fun index _ -> index >= count - after) rows

let memory_refused_keeper_lines (state : state) =
  match state.memory_health with
  | Some { mhs_refused_keepers = []; _ } | None -> []
  | Some { mhs_refused_keepers = refused; _ } ->
    List.map
      (fun refusal ->
        Printf.sprintf "  %s · row not read: %s"
          (match refusal.mkr_keeper_id with
           | Some keeper_id -> Terminal_text.single_line keeper_id
           | None -> "(keeper id not read)")
          (Terminal_text.single_line refusal.mkr_reason))
      refused

type memory_overview_projection =
  { header : string list
  ; refused : string list
  ; refused_divider : bool
  ; context : string list
  }

let refused_rows projection =
  List.length projection.refused + if projection.refused_divider then 1 else 0

let memory_overview_rows ~cols ~budget ?cursor (state : state) =
  let keepers = visible_memory_keepers state in
  let cursor = Option.value cursor ~default:state.memory_health_cursor in
  let context =
    match List.nth_opt keepers (max 0 (min cursor (List.length keepers - 1))) with
    | None -> { rows = []; stalled_row = None }
    | Some keeper ->
      memory_context_lines ~cols ~detail:state.memory_overview_detail keeper
  in
  let all_refused = memory_refused_keeper_lines state in
  let base = memory_overview_scrolled ~header_rows:0 ~refused_rows:0 ~context_rows:0 state in
  (* The context divider needs a row only when the detail itself is shown. *)
  let fixed_rows = base.sc_chrome - Masc_tui_frame.chrome_rows in
  (* A nonempty list needs one selected row; a longer list also needs its
     overflow line. The empty state needs one explanation row. *)
  let list_rows = if List.length keepers > 1 then 2 else 1 in
  (* Reserve a visible count when decoding rejected rows. The rejection
     block spends any additional room after the summary and before detail. *)
  let refused_min = if all_refused = [] then 0 else 1 in
  (* Preserve an omission count and the stalled-gap row, plus their divider,
     before the fleet summary and rejected rows spend the remaining body. *)
  let context_reserve =
    if Option.is_some context.stalled_row then 3 else 0
  in
  let header =
    memory_fleet_header_rows ~cols state
    |> fold_memory_rows ~subject:"Memory summary"
         ~max_rows:(max 0 (budget - fixed_rows - list_rows - refused_min - context_reserve))
  in
  let refused_available =
    max 0 (budget - fixed_rows - list_rows - List.length header - context_reserve)
  in
  let refused =
    fold_memory_rows ~subject:"rejected Keeper"
      ~max_rows:(if refused_available > 1 then refused_available - 1 else refused_available)
      all_refused
  in
  let refused_divider = refused <> [] && refused_available > 1 in
  let refused_spent = List.length refused + if refused_divider then 1 else 0 in
  let context =
    let available =
      budget - fixed_rows - list_rows - List.length header - refused_spent
    in
    if context.rows = [] || available <= 1 then []
    else
      fold_memory_context_rows ~max_rows:(available - 1) context
  in
  { header; refused; refused_divider; context }

let memory_overview_scrolled ~cols ~budget ?cursor (state : state) =
  let projection = memory_overview_rows ~cols ~budget ?cursor state in
  memory_overview_scrolled
    ~header_rows:(List.length projection.header)
    ~refused_rows:(refused_rows projection)
    ~context_rows:(List.length projection.context) state

let render_memory_body ~cols ~budget (state : state)
    ~(push : string -> unit)
    ~(push_styled : style:string -> string -> unit)
    ~(push_selected : string -> unit)
    ~(push_divider : unit -> unit)
    ~(push_empty : unit -> unit) : unit =
  let query = memory_overview_query state in
  let keepers = visible_memory_keepers state in
  let shown = List.length keepers in
  let columns =
    Render_schedule.allocate_memory_columns
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  let sort_label = memory_overview_sort_label state.memory_overview_sort in
  (* The sort it is in, and the filter key the footer gives up first. The row
     also named [a / A] in bold, a key with no value beside it that the footer
     carries at every width, so it said the footer's word again louder. *)
  let info_bar =
    Printf.sprintf "  %sSort [s]:%s %s  %s·%s  %s[/]:%s Filter"
      (Theme.recede ()) Ansi.reset sort_label
      (Theme.recede ()) Ansi.reset
      (Theme.recede ()) Ansi.reset
  in
  let projection = memory_overview_rows ~cols ~budget state in
  List.iter push projection.header;
  push info_bar;
  let search_bar =
    (* The one value the list was filtered by. [visible_memory_keepers] narrows
       on [memory_overview_query], which is the text being typed while a search
       is open and the applied one otherwise; the bar decided whether to draw
       from that and then quoted [search_last] instead. Typing the first filter
       drew the count for what was typed beside an empty pair of quotes, so the
       line named a filter that matched everything and a number that did not.

       And the noun follows the count: filtering by a Keeper's name usually
       leaves exactly one, which read "1 matching keepers". The stats line four
       rows up already counts through the helper that declines the plural. *)
    if query <> "" then
      Printf.sprintf "  %sFilter [/]:%s \"%s\" (%s)  %s[Esc to clear]%s"
        Ansi.bold Ansi.reset (Terminal_text.single_line query)
        (Masc_tui_message_layout.count_noun shown "matching keeper")
        (Theme.recede ()) Ansi.reset
    else ""
  in
  if search_bar <> "" then push search_bar;
  push_divider ();
  push_styled ~style:(Theme.recede ())
    ("  " ^ Render_schedule.memory_header_row columns);
  push_divider ();
  (match state.memory_health_error with
   | None -> ()
   | Some detail ->
       push_styled ~style:(Theme.bad ())
         ("  " ^ Terminal_text.single_line detail);
       push_divider ());
  (* The rejected rows use the same bounded projection as scroll layout. An
     omitted block retains its count, and never pushes the roster offscreen. *)
  List.iter (push_styled ~style:(Theme.bad ())) projection.refused;
  if projection.refused_divider then push_divider ();
  let cursor =
    if shown = 0 then 0 else max 0 (min state.memory_health_cursor (shown - 1))
  in
  let layout = Masc_tui_types.memory_overview_scrolled
      ~header_rows:(List.length projection.header)
      ~refused_rows:(refused_rows projection)
      ~context_rows:(List.length projection.context) state in
  let rows = budget + Masc_tui_frame.chrome_rows in
  let available = max 1 (rows - layout.sc_chrome) in
  let overflowing = shown > available in
  let content_height =
    Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
      ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
      ~overflow_takes_row:layout.sc_overflow_takes_row
  in
  let scroll =
    Masc_tui_scroll.normalize ~count:shown ~height:content_height
      state.memory_health_scroll
    |> Masc_tui_scroll.ensure_visible ~cursor ~height:content_height
  in
  if shown = 0 then
    (* A failed read and an unread one say what every page says. Memory had its
       own words for both, and "server error" named a connection nobody made. *)
    let note =
      match
        empty_page_of ~snapshot:state.memory_health ~error:state.memory_health_error
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty when query <> "" ->
        Printf.sprintf "  (no keepers matching \"%s\" \xe2\x80\x94 Esc clears filter)"
          (Terminal_text.single_line query)
      | Page_empty -> "  (no keepers with a memory config or snapshot)"
    in
    push_styled ~style:(Theme.recede ()) note
  else begin
    let keepers_window =
      Rows.of_list ~first:scroll ~height:content_height keepers
    in
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at keepers_window idx with
      | None -> push_empty ()
      | Some k ->
          if idx = cursor then
            push_selected (Masc_tui_theme.strip_sgr (memory_row_line columns k))
          else push (memory_row_line columns k)
    done;
    if overflowing then
      push_styled ~style:(Theme.recede ())
        (Printf.sprintf "[keepers %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height shown))
  end;
  (match projection.context with
   | [] -> ()
   | lines ->
       push_divider ();
       List.iter (push_styled ~style:(Theme.recede ())) lines)

(* How many fact rows the list keeps before the detail below it takes any.
   Enough to read the cursor against its neighbours -- one row above, one
   below, and the room a filter leaves when it lands the cursor near an
   edge. One of these rows goes to the window reading when the list
   overflows, the way it does on every other reading pane. Under this the
   browser stops being one. *)
let memory_fact_list_floor_rows = 5

let memory_facts_layout ~cols ~budget ~cursor (state : state) rows =
  let total = List.length rows in
  let cursor = max 0 (min cursor (total - 1)) in
  let detail =
    Option.map (memory_fact_detail_parts ~state ~cols) (List.nth_opt rows cursor)
  in
  let total_detail_lines =
    Option.fold ~none:0 ~some:fact_detail_line_count detail
  in
  let store_error_rows =
    match memory_facts_snapshot state with
    | None -> 0
    | Some snapshot ->
        (match snapshot.mfs_ordinary with
         | Memory_store_read_error _ -> 1
         | Memory_store_absent | Memory_store_present _ -> 0)
        + (match snapshot.mfs_source with
           | Memory_store_read_error _ -> 1
           | Memory_store_absent | Memory_store_present _ -> 0)
        + (match snapshot.mfs_events_read_error with None -> 0 | Some _ -> 1)
  in
  (* Stats, optional categories/search, two dividers and the column header.
     These are the rows rendered above the list below; detail owns its own
     divider. Input asks for the target cursor because wrapped details can
     change the height on every movement. The search row is counted from
     [memory_search_query], the same value the renderer draws it from. *)
  let chrome_rows =
    4
    + (if Option.is_some (memory_facts_snapshot state) then 1 else 0)
    + (if String.trim (memory_search_query state) <> "" then 1 else 0)
    + store_error_rows
    + (if Option.is_some (memory_facts_failure state) then 2 else 0)
  in
  (* The detail is as tall as the fact under the cursor, and a fact can be
     any length. On the live store at thirty rows one fact filled fifteen of
     them and the list fell to its floor of one: a browser of 254 facts
     showing one row, whose height then moved on every [j] as the next fact
     wrapped to a different depth. The list keeps this many rows before the
     detail takes any, and what the detail then loses is one keypress away --
     [Enter] opens the whole fact in an overlay that owns the terminal. *)
  let room_below_chrome = max 1 (budget - chrome_rows) in
  let detail_row_budget =
    min (if total_detail_lines = 0 then 0 else 1 + total_detail_lines)
      (max 0 (room_below_chrome - memory_fact_list_floor_rows))
  in
  let detail_lines =
    match detail with
    | None -> []
    | Some parts ->
      let kept = max 0 (detail_row_budget - 1) in
      (* The detail also needs its divider. With no line left after that,
         even the folded marker would exceed the rows reserved for it. *)
      if kept = 0 then []
      else if kept >= total_detail_lines then
        fact_detail_prefix parts total_detail_lines
      else
        (* The last row it can draw says what is under the fold, in the
           window the list below and the other reading panes draw. *)
        fact_detail_prefix parts (kept - 1)
        @ [ Printf.sprintf "      [fact %s \xc2\xb7 Enter for the whole fact]"
              (Masc_tui_scroll.window_text ~scroll:0
                 ~height:(kept - 1) total_detail_lines) ]
  in
  (* A budgeted detail that drew nothing also spends no divider. Returning
     that row to the list keeps tiny viewports full. *)
  let detail_rows =
    match detail_lines with [] -> 0 | lines -> 1 + List.length lines
  in
  let room = max 1 (room_below_chrome - detail_rows) in
  let overflowing = total > room in
  let height = if overflowing then max 1 (room - 1) else room in
  let scroll =
    Masc_tui_scroll.normalize ~count:total ~height state.memory_facts_scroll
    |> Masc_tui_scroll.ensure_visible ~cursor ~height
  in
  (detail_lines, height, overflowing, scroll)

let memory_facts_pane_cols state cols =
  if state.memory_facts_categories_open && cols >= Masc_tui_roster_pane.threshold_cols then
    cols - Masc_tui_roster_pane.pane_cols - Message_layout.display_width " │ "
  else cols

let memory_facts_content_height ~cols ~budget ~cursor state =
  let _, height, _, _ =
    memory_facts_layout ~cols:(memory_facts_pane_cols state cols) ~budget ~cursor state (memory_fact_rows state)
  in
  height

let render_memory_facts_body_single ?(show_category_strip = true) ~cols ~budget (state : state)
    ~(push : string -> unit)
    ~(push_styled : style:string -> string -> unit)
    ~(push_selected : string -> unit)
    ~(push_divider : unit -> unit)
    ~(push_empty : unit -> unit) : unit =
  let is_fleet =
    Option.equal String.equal state.memory_facts_keeper (Some "*")
  in
  let rows = memory_fact_rows state in
  let total = List.length rows in
  let cursor = max 0 (min state.memory_facts_cursor (total - 1)) in
  let sort_label = memory_sort_order_label state.memory_facts_sort in
  (* The parts of the total the title draws, counted from the rows this screen
     is about to list, so the title's total and this breakdown count the same
     set. Counting the store instead gives a filtered title saying "2 facts"
     above a breakdown that sums to 285. The store's own totals are the category
     pills' job, and the All pill carries the grand total. *)
  let ordinary_count, source_count, dropped_count =
    List.fold_left
      (fun (ordinary, source, dropped) row ->
        match row with
        | Memory_row_fact _ -> (ordinary + 1, source, dropped)
        | Memory_row_source_fact _ -> (ordinary, source + 1, dropped)
        | Memory_row_invalidation _ -> (ordinary, source, dropped + 1))
      (0, 0, 0) rows
  in
  (* The row says what the listing below it says: a failed read drew
     "(loading facts…)" here over a body reading "(load failed; …)", because
     this row looked only at whether facts were held. *)
  let stats_line, pills_line =
    match memory_facts_view state with
    | Masc_tui_fetched.Loading -> ("  (loading facts\xe2\x80\xa6)", "")
    | Masc_tui_fetched.Absent -> ("  " ^ title_unread, "")
    | Masc_tui_fetched.Failed _ -> ("  " ^ title_failed, "")
    | Masc_tui_fetched.Ready (snapshot, _) | Masc_tui_fetched.Stale ((snapshot, _), _) ->
        let store_ordinary, store_ordinary_facts =
          match snapshot.mfs_ordinary with
          | Memory_store_present store ->
              (List.length store.mos_facts, store.mos_facts)
          | _ -> (0, [])
        in
        let store_source, store_dropped =
          match snapshot.mfs_source with
          | Memory_store_present store ->
              (List.length store.mss_facts, List.length store.mss_invalidations)
          | _ -> (0, 0)
        in
        let grand_total = store_ordinary + store_source + store_dropped in
        let stats =
          facts_stats_row ~ordinary:ordinary_count ~source:source_count
            ~dropped:dropped_count ~sort_label
        in
        let all_categories = if show_category_strip then memory_fact_categories state else [] in
        (* Through [tab_strip], the one drawing every in-screen strip shares,
           the way the Themes filter draws its chips: the key that walks the
           entries first, then the entries with the one being read marked.
           This row drew its own "[● All: 4] [○ blocker: 1]" -- a third
           shape for a strip, with the key in brackets the footer spells as
           "c / C:category". *)
        let count_of = function
          | Category_all -> grand_total
          | Category_source -> store_source
          | Category_dropped -> store_dropped
          | Category_ordinary cat ->
              List.length
                (List.filter
                   (fun (f : memory_fact) -> f.mf_category = cat)
                   store_ordinary_facts)
        in
        let keys = "  c/C:category  " in
        let after =
          if cols < Masc_tui_roster_pane.threshold_cols then ""
          else if state.memory_facts_categories_open then "  d:접기"
          else "  d:Category 펼치기"
        in
        let pills =
          if not show_category_strip then "  c/C:category · Enter:fact detail"
          else Ansi.dim ^ keys ^ Ansi.reset
          ^ tab_strip
              ~width:(tab_strip_width ~cols ~before:keys ~after)
              ~press:(fun filt text ->
                Masc_tui_press.(pressable (Press_memory_category filt) text))
              (List.map
                 (fun filt ->
                   ( Printf.sprintf "%s %d" (memory_category_filter_label filt)
                       (count_of filt)
                   , state.memory_facts_category = filt
                   , filt ))
                 (Category_all :: all_categories))
          ^ Ansi.dim ^ after ^ Ansi.reset
        in
        (stats, pills)
  in
  push stats_line;
  if pills_line <> "" then push pills_line;
  let search_banner =
    (* [memory_search_query], the value [memory_fact_rows] filtered by, for
       all three of the decision, the quotation and the count. It used to
       decide and quote from [search_last] while the rows were already
       narrowed by the text being typed, so a second filter typed over an
       applied one drew the old word above rows the new one had left. *)
    let filter = memory_search_query state in
    if String.trim filter <> "" then
      Printf.sprintf "  %sFilter [/]:%s \"%s\" (%s)  %s[Esc to clear]%s"
        Ansi.bold Ansi.reset (Terminal_text.single_line filter)
        (Masc_tui_message_layout.count_noun total "matching fact")
        (Theme.recede ()) Ansi.reset
    else ""
  in
  if search_banner <> "" then push search_banner;
  push_divider ();
  (match memory_facts_failure state with
   | None -> ()
   | Some detail ->
       push_styled ~style:(Theme.bad ())
         ("  " ^ Terminal_text.single_line detail);
       push_divider ());
  (match memory_facts_snapshot state with
   | None -> ()
   | Some snapshot ->
       (match snapshot.mfs_ordinary with
        | Memory_store_read_error detail ->
            push_styled ~style:(Theme.bad ())
              ("  ordinary store: " ^ Terminal_text.single_line detail)
        | Memory_store_absent | Memory_store_present _ -> ());
       (match snapshot.mfs_source with
        | Memory_store_read_error detail ->
            push_styled ~style:(Theme.bad ())
              ("  source-bound store: " ^ Terminal_text.single_line detail)
        | Memory_store_absent | Memory_store_present _ -> ());
       (match snapshot.mfs_events_read_error with
        | None -> ()
        | Some detail ->
          push_styled ~style:(Theme.bad ())
            ("  events sidecar: " ^ Terminal_text.single_line detail)));
  let col_header =
    if is_fleet then
      Printf.sprintf "  %-10s %-12s %6s %s" "KEEPER" "CATEGORY" "AGE" "CLAIM / BOUND PATH"
    else
      Printf.sprintf "  %-12s %6s %s" "CATEGORY" "AGE" "CLAIM / BOUND PATH"
  in
  push_styled ~style:(Theme.recede ()) col_header;
  push_divider ();
  let detail_lines, content_height, overflowing, scroll =
    memory_facts_layout ~cols ~budget ~cursor state rows
  in
  if total = 0 then
    (let empty =
       match
         empty_page_of ~snapshot:(memory_facts_snapshot state) ~error:(memory_facts_failure state),
         state.memory_facts_category
       with
       | Page_failed, _ -> page_failed_note
       | Page_unread, _ -> page_unread_note
       | Page_empty, Category_all ->
           (* [total] counts rows filtered by [memory_search_query], so the
              note reads the same value; the store is not empty just because
              a filter being typed matched nothing. *)
           let filter = memory_search_query state in
           if String.trim filter <> "" then
             Printf.sprintf "  (no facts matching \"%s\" \xe2\x80\x94 Esc clears filter)"
               (Terminal_text.single_line filter)
           else if is_fleet then
             "  (no facts across any keeper in the fleet)"
           else "  (no facts in either store)"
       | Page_empty, filt ->
           Printf.sprintf "  (no facts in category %s \xe2\x80\x94 c/C cycles)"
             (memory_category_filter_label filt)
     in
     push_styled ~style:(Theme.recede ()) empty)
  else begin
    let rows_window = Rows.of_list ~first:scroll ~height:content_height rows in
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at rows_window idx with
      | None -> push_empty ()
      | Some row ->
          let line = memory_fact_row_line ~is_fleet ~cols row in
          if idx = cursor then push_selected (Masc_tui_theme.strip_sgr line)
          else push line
    done;
    if overflowing then
      push_styled ~style:(Theme.recede ())
        (Printf.sprintf "[facts %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height total))
  end;
  (match detail_lines with
   | [] -> ()
   | lines ->
       push_divider ();
       List.iter push lines)

let render_memory_facts_body ~cols ~budget (state : state)
    ~push ~push_styled ~push_selected ~push_divider ~push_empty =
  if not state.memory_facts_categories_open || cols < Masc_tui_roster_pane.threshold_cols then
    render_memory_facts_body_single ~cols ~budget state
      ~push ~push_styled ~push_selected ~push_divider ~push_empty
  else begin
    let width = Masc_tui_roster_pane.pane_cols in
    let fact_cols = memory_facts_pane_cols state cols in
    let facts = ref [] in
    let collect text = facts := text :: !facts in
    render_memory_facts_body_single ~show_category_strip:false ~cols:fact_cols ~budget state
      ~push:collect
      ~push_styled:(fun ~style text -> collect (style ^ text ^ Ansi.reset))
      ~push_selected:(fun text -> collect (Theme.selection ^ text ^ Ansi.reset))
      ~push_divider:(fun () -> collect (String.make fact_cols '-'))
      ~push_empty:(fun () -> collect "");
    let count category =
      match memory_facts_snapshot state with
      | None -> None
      | Some snapshot ->
        let ordinary = match snapshot.mfs_ordinary with
          | Memory_store_present store -> Some store.mos_facts
          | Memory_store_absent -> Some [] | Memory_store_read_error _ -> None in
        let source = match snapshot.mfs_source with
          | Memory_store_present store -> Some (List.length store.mss_facts, List.length store.mss_invalidations)
          | Memory_store_absent -> Some (0,0) | Memory_store_read_error _ -> None in
        match category, ordinary, source with
        | Category_ordinary cat, Some facts, _ ->
          Some (List.length (List.filter (fun (fact : memory_fact) -> fact.mf_category = cat) facts))
        | Category_source, _, Some (count, _) | Category_dropped, _, Some (_, count) -> Some count
        | Category_all, Some facts, Some (source, dropped) -> Some (List.length facts + source + dropped)
        | _ -> None
    in
    let header = [Theme.info () ^ "CATEGORIES" ^ Ansi.reset ^ Ansi.dim ^ "  d:접기" ^ Ansi.reset; "c/C 순서 이동 · 클릭 선택"; ""] in
    let height = max 0 (budget - List.length header) in
    let categories = Category_all :: memory_fact_categories state in
    let selected =
      categories |> List.find_mapi (fun index category ->
        if category = state.memory_facts_category then Some index else None)
      |> Option.value ~default:0 in
    let category_scroll = Masc_tui_scroll.ensure_visible ~cursor:selected ~height:(max 1 height) 0 in
    let entries =
      categories
      |> List.filteri (fun index _ -> index >= category_scroll && index < category_scroll + height)
      |> List.concat_map (fun category ->
        let count = match count category with None -> "?" | Some count -> string_of_int count in
        let suffix = " (" ^ count ^ ")" in
        (* Category names are validated ASCII. Bound bytes before wrapping:
           the selected label gets the rail height; other previews get one row.
           Enter's fact detail retains the complete category value. *)
        let rows = if category = state.memory_facts_category then max 1 height else 1 in
        let room = max 1 (rows * (width - 2) - String.length suffix) in
        let name = memory_category_filter_label category in
        let name = if String.length name <= room then name
          else String.sub name 0 (room - 1) ^ "…" in
        Message_layout.wrap_words ~max_cells:(width - 2) (Terminal_text.single_line (name ^ suffix))
        |> List.map (fun text -> category, text)) in
    let selected_indices =
      entries
      |> List.mapi (fun index (category, _) -> index, category)
      |> List.filter (fun (_, category) -> category = state.memory_facts_category)
      |> List.map fst in
    let start_row, end_row = match selected_indices with
      | [] -> 0, 0
      | first :: _ -> first, List.hd (List.rev selected_indices) in
    let span = end_row - start_row + 1 in
    let scroll =
      if span <= height then
        let s = Masc_tui_scroll.ensure_visible ~cursor:end_row ~height:(max 1 height) 0 in
        Masc_tui_scroll.ensure_visible ~cursor:start_row ~height:(max 1 height) s
      else
        start_row
    in
    let rail = header @
      (entries |> List.filteri (fun index _ -> index >= scroll && index < scroll + height)
       |> List.map (fun (category, text) ->
           let text = fit_width ("  " ^ text) width in
           let style = if category = state.memory_facts_category then Theme.selection else Theme.recede () in
           Masc_tui_press.(pressable (Press_memory_category category) (style ^ text ^ Ansi.reset)))) in
    let facts = List.rev !facts in
    let height = max (List.length facts) (min budget (List.length rail)) in
    (* Both panes through the list-window helper the scroll panes read: two
       arrays, one pass, each row reads its own cells -- no row of the loop
       walks either list to find itself. *)
    let rail_window = Rows.of_list ~first:0 ~height rail in
    let facts_window = Rows.of_list ~first:0 ~height facts in
    for index = 0 to height - 1 do
      let cell window = Option.value (Rows.at window index) ~default:"" in
      push (fit_width (cell rail_window) width ^ Theme.recede () ^ " │ " ^ Ansi.reset
        ^ fit_width (cell facts_window) fact_cols)
    done
  end

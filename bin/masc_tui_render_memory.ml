open Masc_tui_types
open Masc.Tui_decode
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
  | Pass_off -> "switched off"
  | Pass_lane_unconfigured -> "no model lane set up"
  | Pass_drained -> "caught up"
  | Pass_not_committed -> "last pass saved nothing"
  | Pass_stopped _ -> "stopped on an error"
  | Pass_raised _ -> "crashed"

let librarian_failure_words = function
  | Failure_prompt_render -> "prompt could not be built"
  | Failure_execution_clock_unavailable -> "no clock to run on"
  | Failure_exact_setup -> "model call could not be set up"
  | Failure_exact_execution -> "model call failed"
  | Failure_domain_output_invalid -> "model answer was not usable"
  | Failure_memory_snapshot_write -> "Memory could not be saved"
  | Failure_runtime_context_unavailable -> "no runtime context"
  | Failure_lane_cancelled -> "cancelled before saving"
  | Failure_unhandled_exception -> "unexpected crash"

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
   reading belong to the caller. *)
let facts_title ~screen ~keeper ~reading ~timestamp ~badge =
  match reading with
  | Facts_unread { reading } ->
    Printf.sprintf "%s \xe2\x96\xb8 %s  %s  %s  %s" screen keeper reading
      timestamp badge
  | Facts_loaded { total; filter_label; query_label } ->
    Printf.sprintf "%s \xe2\x96\xb8 %s (%s \xc2\xb7 %s%s)  %s  %s" screen
      keeper (Masc_tui_message_layout.count_noun total "fact") filter_label query_label timestamp badge

(* The row under the facts title. The title says the total and the filter; this
   says how that total breaks down and which sort produced the order, so each
   fact is written in one place. The split runs in this direction because the
   title is the line with no room to spare: at 140 columns the Activity pane
   takes 56 of the 136 inner cells, leaving the title 80 for the screen name,
   the keeper, the total, both filters, the clock and the badge.

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
  | None -> "-"
  | Some ts -> memory_date ts

(* Every size on this screen is the recall block the keeper injects, not the
   snapshot file: the file's first_seen, origin, basis and JSON punctuation
   never reach a request.

   Read in tokens, because that is the unit the window is declared in and the
   only unit an operator can hold a keeper's memory against. No provider this
   fleet runs counts a block inside a request, and this screen carries no turn
   record to take a ratio from, so the figure is the fleet scale and wears the
   "≈" every estimated token figure in this TUI wears. The exact count is
   derivable -- a first round carries the pinned blocks and the post-tool round
   in the same turn does not, so their (total - carried) difference is the
   pinned bundle -- and wants the ledger to expose carried tokens per record. *)
let recall_tokens bytes =
  Masc_tui_token_scale.format_estimate Masc_tui_token_scale.fleet bytes
;;
let memory_context_lines (k : memory_keeper_health) =
  let current_line =
    Printf.sprintf "  %s · %s · snapshot r%d · recall %s tok · updated %s"
      k.mkh_keeper_id (memory_state_label (memory_state k)) k.mkh_revision
      (recall_tokens k.mkh_snapshot_bytes)
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
  let librarian_line =
    let librarian = k.mkh_librarian in
    let unread =
      match librarian.mlh_unread_atom_turns, librarian.mlh_unread_official_turns with
      | Some atoms, Some official -> Printf.sprintf "unread %d" (atoms + official)
      | Some _, None | None, Some _ | None, None -> "unread ?"
    in
    (* The two rounds fall behind separately, so the continuity lag prints
       beside the drain's count rather than folded into it. "?" is its own
       reading: no snapshot, an unreadable one, or one from another trace. *)
    let continuity =
      match librarian.mlh_continuity_unread_atoms with
      | Some atoms -> Printf.sprintf "continuity behind %d" atoms
      | None -> "continuity behind ?"
    in
    Printf.sprintf
      "  Librarian · %s · %s · %s · measured %s · Memory saved %s · last failure %s · failed %d since server start"
      (match librarian.mlh_state with
       | Some state -> librarian_pass_end_words state
       | None -> "not measured")
      unread
      continuity
      (memory_updated_text librarian.mlh_measured_at)
      (memory_updated_text librarian.mlh_last_success_at)
      (match librarian.mlh_last_failure_kind with
       | Some kind -> librarian_failure_words kind
       | None -> "-")
      k.mkh_librarian_failures
  in
  let librarian_cause_lines =
    (* The cause is drawn on its own row because it is the part of the
       Librarian row an operator acts on. *)
    match Option.bind k.mkh_librarian.mlh_state memory_librarian_pass_end_cause with
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
          Printf.sprintf " · read to atom %d, %d atoms past the cut"
            position (position - value.mcf_end_atom)
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
          | Context_summarized value -> "summary " ^ frontier value
          | Context_absorbed value ->
            Printf.sprintf "absorbed to atom %d · trace %s · no summary"
              value.mcpo_end_atom (Terminal_text.single_line value.mcpo_trace_id)
          | Context_without_snapshot -> "no snapshot: this turn only"
          | Context_not_applied -> "saved context not applied" in
        Printf.sprintf "%s · %d request bytes · %s"
          (memory_updated_text (Some value.mcp_prepared_at))
          value.mcp_request_bytes (Terminal_text.single_line value.mcp_runtime_id), input in
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
      "  source-bound snapshot r%d · facts %d · invalidations %d · recall %s tok · %s"
      k.mkh_source_revision k.mkh_source_facts k.mkh_source_invalidations
      (recall_tokens k.mkh_source_snapshot_bytes)
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
      (fun (a : memory_alert) ->
        Printf.sprintf "  [%s] %s \xe2\x80\x94 %s"
          (match Masc.Tui_decode.memory_alert_severity a.ma_code with
           | `Warn -> "warn"
           | `Error -> "error")
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
  [current_line; facts_line; source_line; librarian_line] @ librarian_cause_lines @ context_lines
  @ (vision_line :: (read_error_lines @ alert_lines))

type memory_state = Masc_tui_types.memory_state =
  | Memory_ordinary | Memory_warning | Memory_degraded | Memory_no_current
  | Memory_source_only | Memory_starving | Memory_read_error

(* The glyph and the word for it are one module, so the column below and the
   [?] sheet cannot spell the same state two ways. *)
let memory_state_cell = Masc_tui_memory_mark.glyph

let memory_deviation_style (k : memory_keeper_health) =
  let server_error =
    List.exists
      (fun alert ->
        match Masc.Tui_decode.memory_alert_severity alert.ma_code with
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

let memory_row_line columns (k : memory_keeper_health) =
  let em_dash = "\xe2\x80\x94" in
  let ordinary_reading value = if k.mkh_snapshot_present then value () else em_dash in
  let source =
    if Option.is_some k.mkh_source_read_error then "read error"
    else if k.mkh_source_snapshot_present then
      Printf.sprintf "r%d i%d %s tok" k.mkh_source_revision
        k.mkh_source_invalidations
        (recall_tokens k.mkh_source_snapshot_bytes)
    else em_dash
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
          ordinary_reading (fun () -> recall_tokens k.mkh_snapshot_bytes)
      ; mrow_source = source
      ; mrow_delta = delta
      }

(* What a row wears in its first cell. The category is the librarian
   taxonomy, a closed sum the producer writes and the model's schema enum is
   built from ([Keeper_memory_os_types.category]); the other two are this
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
          | Memory_category.Lesson ->
              Theme.recede ()
        in
        ( style
        , String.uppercase_ascii
            (Memory_category.category_to_string category) )
  in
  let cat_str =
    if Message_layout.display_width label > 10 then
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

let detail_field label value = "    " ^ detail_label label ^ value

(* A claim is prose a Keeper wrote, often paragraphs and a numbered list. The
   list rows fold it to one line because a row has one line to give it; the
   detail pane has the height, so it keeps the claim's own breaks. Each line is
   escaped on its own -- escaping the whole claim turns every newline into a
   printed \x0A (#37017) -- and wrapped at spaces, so a word is not cut in two
   at the pane's edge. A blank line stays a blank row: it is a paragraph break,
   not an absence. *)
let detail_claim_lines ~inner_width claim =
  Message_layout.wrap_body ~max_cells:inner_width
    ~sanitize:Terminal_text.single_line claim
  |> List.map (fun line -> if String.equal line "" then "" else "    " ^ line)

let memory_fact_detail_lines ~cols (row : memory_fact_row) =
  let inner_width = max 30 (cols - 6) in
  match row with
  | Memory_row_fact fact ->
      let claim_lines = detail_claim_lines ~inner_width fact.mf_claim in
      let history =
        Printf.sprintf "Retrieved %d · %s · last %s · Retracted %d · Revised from %d"
          fact.mf_events.mfe_retrieved_count
          (Message_layout.count_noun fact.mf_events.mfe_retrieved_distinct_days "day")
          (match fact.mf_events.mfe_last_retrieved_at with
           | None -> "never"
           | Some at -> memory_fact_age_label at)
          fact.mf_events.mfe_retracted_count
          (List.length fact.mf_events.mfe_revised_from)
      in
      let history_prefix = detail_field "History:" "" in
      let prefix_width = Message_layout.display_width history_prefix in
      let history_lines =
        Message_layout.wrap_words ~max_cells:(max 1 (cols - prefix_width)) history
        |> List.mapi (fun index line ->
             (if index = 0 then history_prefix else String.make prefix_width ' ') ^ line)
      in
      [ Printf.sprintf "  %s%sFact Detail%s" Ansi.bold (Theme.info ()) Ansi.reset ]
      @ claim_lines
      @ [ (* The word comes from [Keeper_memory_os_types.category], a closed
             set this build spells itself, so it is printed rather than
             escaped: there is no wire text left in it to escape. *)
          detail_field "Category:"
            (Memory_category.category_to_string fact.mf_category)
          (* Two labelled readings used to share this row, the first in a
             hand-sized slot of fifteen cells. Every other field in this pane
             owns a row, and the slot was a guess: in the fleet reading the
             origin carries its keeper, and the shortest keeper name in the
             fleet already makes it seventeen bytes, so "Timeline:" lost the
             space before it on every row. Printf's width counts bytes as
             well, which the middle dot in that reading is three of. *)
        ; detail_field "Origin:" (Terminal_text.single_line fact.mf_origin)
        ; detail_field "Timeline:"
            (Printf.sprintf "First: %s \xc2\xb7 Last: %s"
               (memory_fact_age_label fact.mf_first_seen)
               (memory_fact_age_label fact.mf_last_seen))
        ]
      @ history_lines
      @ [ detail_field "Memory ID:" (Terminal_text.single_line fact.mf_memory_id) ]
  | Memory_row_source_fact fact ->
      let claim_lines = detail_claim_lines ~inner_width fact.msf_claim in
      [ Printf.sprintf "  %s%sSource-Bound Fact Detail%s" Ansi.bold (Theme.info ()) Ansi.reset ]
      @ claim_lines
      @ [ detail_field "Bound Path:" (Terminal_text.single_line fact.msf_path)
        ; detail_field "File SHA:"
            (Printf.sprintf "%s · %sFirst Seen:%s %s" 
               (Terminal_text.single_line fact.msf_sha256)
               (Theme.recede ()) Ansi.reset
               (memory_fact_age_label fact.msf_first_seen))
        ]
  | Memory_row_invalidation row ->
      [ Printf.sprintf "  %s%sDropped / Invalidated Fact%s" Ansi.bold (Theme.bad ()) Ansi.reset
      ; detail_field "Reason:" (Terminal_text.single_line row.mi_reason)
      ; detail_field "Source Path:" (Terminal_text.single_line row.mi_source_path)
      ; detail_field "Dropped At:"
          (memory_fact_age_label row.mi_invalidated_at ^ " ago")
      ]

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
  (* What to say where the numbers would go. They are missing for two reasons
     and the line has to name the one that holds: nothing has arrived yet, or
     the load failed. The table below already draws the server's own reason in
     red, so a header that says "waiting" after a failure puts two answers to
     the same question on one screen -- and this one is on top, so it is the
     one that gets read. *)
  let missing_reading waiting =
    if Option.is_some state.memory_health_error then field_failed else waiting
  in
  (match state.memory_health with
   | None -> push ("  Total: " ^ missing_reading "waiting for memory snapshots")
   | Some snapshot ->
       push (Printf.sprintf "  Total %s · %d ordinary + %d source · recall %s tok · %s"
         (Masc_tui_message_layout.count_noun (snapshot.mhs_total_facts + snapshot.mhs_total_source_facts) "fact")
         snapshot.mhs_total_facts snapshot.mhs_total_source_facts
         (recall_tokens
            (snapshot.mhs_total_snapshot_bytes + snapshot.mhs_total_source_snapshot_bytes))
         (Masc_tui_message_layout.count_noun (List.length snapshot.mhs_keepers) "keeper")));
  (match state.memory_health with
   | None -> push ("  Librarian: " ^ missing_reading "waiting for health data")
   | Some snapshot ->
       push (Printf.sprintf "  Ordinary: %d observed / %d derived · %d support invalidations · Librarian: %s turns unread · %d atoms behind in continuity (%d keepers not measured) · %d failures since server start"
         snapshot.mhs_total_observed_facts snapshot.mhs_total_derived_facts
         snapshot.mhs_total_support_invalidations
         (Option.fold ~none:"?" ~some:string_of_int snapshot.mhs_total_librarian_unread_turns)
         snapshot.mhs_total_librarian_continuity_unread_atoms
         snapshot.mhs_total_librarian_continuity_unmeasured
         snapshot.mhs_total_librarian_failures));
  push info_bar;
  let search_bar =
    if query <> "" then
      Printf.sprintf "  %sFilter [/]:%s \"%s\" (%d matching keepers)  %s[Esc to clear]%s"
        Ansi.bold Ansi.reset (Terminal_text.single_line state.search_last)
        shown (Theme.recede ()) Ansi.reset
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
  (* A keeper row the decoder refused is drawn as one line naming the keeper
     and the reason; the rows that decoded are drawn below as usual. *)
  (match state.memory_health with
   | Some { mhs_refused_keepers = []; _ } | None -> ()
   | Some { mhs_refused_keepers = refused; _ } ->
       List.iter
         (fun refusal ->
           push_styled ~style:(Theme.bad ())
             (Printf.sprintf "  %s · row not read: %s"
                (match refusal.mkr_keeper_id with
                 | Some keeper_id -> Terminal_text.single_line keeper_id
                 | None -> "(keeper id not read)")
                (Terminal_text.single_line refusal.mkr_reason)))
         refused;
       push_divider ());
  let cursor =
    if shown = 0 then 0 else max 0 (min state.memory_health_cursor (shown - 1))
  in
  let context_lines =
    match List.nth_opt keepers cursor with
    | None -> []
    | Some k -> memory_context_lines k
  in
  let layout = memory_overview_scrolled ~cursor state in
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
          state.search_last
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
  (match context_lines with
   | [] -> ()
   | lines ->
       push_divider ();
       List.iter (push_styled ~style:(Theme.recede ())) lines)

let memory_facts_layout ~cols ~budget ~cursor (state : state) rows =
  let total = List.length rows in
  let cursor = max 0 (min cursor (total - 1)) in
  let detail_lines =
    match List.nth_opt rows cursor with
    | None -> []
    | Some row -> memory_fact_detail_lines ~cols row
  in
  let detail_rows =
    match detail_lines with [] -> 0 | lines -> 1 + List.length lines
  in
  let store_error_rows =
    match state.memory_facts with
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
     change the height on every movement. *)
  let fixed_rows =
    4
    + (if Option.is_some state.memory_facts then 1 else 0)
    + (if String.trim state.search_last <> "" then 1 else 0)
    + detail_rows + store_error_rows
    + (if Option.is_some state.memory_facts_error then 2 else 0)
  in
  let room = max 1 (budget - fixed_rows) in
  let overflowing = total > room in
  let height = if overflowing then max 1 (room - 1) else room in
  let scroll =
    Masc_tui_scroll.normalize ~count:total ~height state.memory_facts_scroll
    |> Masc_tui_scroll.ensure_visible ~cursor ~height
  in
  (detail_lines, height, overflowing, scroll)

let memory_facts_content_height ~cols ~budget ~cursor state =
  let _, height, _, _ =
    memory_facts_layout ~cols ~budget ~cursor state (memory_fact_rows state)
  in
  height

let render_memory_facts_body ~cols ~budget (state : state)
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
  let stats_line, pills_line =
    match state.memory_facts with
    | None -> ("  (loading facts\xe2\x80\xa6)", "")
    | Some snapshot ->
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
        let all_categories = memory_fact_categories state in
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
        let pills =
          Ansi.dim ^ keys ^ Ansi.reset
          ^ tab_strip
              ~width:(tab_strip_width ~cols ~before:keys ~after:"")
              (List.map
                 (fun filt ->
                   ( Printf.sprintf "%s %d" (memory_category_filter_label filt)
                       (count_of filt)
                   , state.memory_facts_category = filt ))
                 (Category_all :: all_categories))
        in
        (stats, pills)
  in
  push stats_line;
  if pills_line <> "" then push pills_line;
  let search_banner =
    if String.length (String.trim state.search_last) > 0 then
      Printf.sprintf "  %sFilter [/]:%s \"%s\" (%d matching facts)  %s[Esc to clear]%s"
        Ansi.bold Ansi.reset (Terminal_text.single_line state.search_last) total
        (Theme.recede ()) Ansi.reset
    else ""
  in
  if search_banner <> "" then push search_banner;
  push_divider ();
  (match state.memory_facts_error with
   | None -> ()
   | Some detail ->
       push_styled ~style:(Theme.bad ())
         ("  " ^ Terminal_text.single_line detail);
       push_divider ());
  (match state.memory_facts with
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
         empty_page_of ~snapshot:state.memory_facts ~error:state.memory_facts_error,
         state.memory_facts_category
       with
       | Page_failed, _ -> page_failed_note
       | Page_unread, _ -> page_unread_note
       | Page_empty, Category_all ->
           if state.search_last <> "" then
             Printf.sprintf "  (no facts matching \"%s\" \xe2\x80\x94 Esc clears filter)"
               state.search_last
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

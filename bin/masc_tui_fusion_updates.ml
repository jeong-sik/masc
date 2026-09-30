(** Fusion response application; transport and reporting remain caller-owned. *)

open Masc_tui_types

let apply_fusion_runs_load state request = function
  | Ok snapshot ->
      let keeper_run_id =
        Option.map (fun (_, run) -> run.Masc.Tui_decode_fusion.fur_run_id)
          (selected_keeper_run state)
      in
      let current_selected_id =
        match state.fusion_mode with
        | Fusion_historical_detail reference -> Some (fusion_entry_identity (Masc.Tui_decode_fusion.Fusion_historical_evidence reference))
        | Fusion_detail run_id -> Some ("run:" ^ run_id)
        | Fusion_list -> Option.map fusion_entry_identity (selected_fusion_entry state)
      in
      let next_ids =
        List.map fusion_entry_identity (fusion_snapshot_entries snapshot)
      in
      let fallback_cursor =
        min (max 0 state.fusion_cursor) (max 0 (List.length next_ids - 1))
      in
      let next_cursor =
        match current_selected_id with
        | None -> fallback_cursor
        | Some run_id ->
            Option.value
              (List.find_index (String.equal run_id) next_ids)
              ~default:fallback_cursor
      in
      state.fusion_runs <-
        Masc_tui_fetched.complete ~equal:Unit.equal state.fusion_runs request (Ok snapshot);
      let keeper_runs = selected_keeper_runs state in
      state.keeper_run_cursor <-
        Option.bind keeper_run_id (fun id ->
          List.find_index (fun run -> String.equal run.Masc.Tui_decode_fusion.fur_run_id id) keeper_runs)
        |> Option.value ~default:(max 0 (min state.keeper_run_cursor (List.length keeper_runs - 1)));
      state.fusion_launch_error <- None;
      (* A run the form just started is selected the first time the list
         carries it, and the wait ends there. *)
      (match state.fusion_launch with
       | Some (Fusion_launch_started started) -> (
           match
             fusion_snapshot_entries snapshot
             |> List.find_index (function
                  | Masc.Tui_decode_fusion.Fusion_retained_run run ->
                      String.equal run.fur_run_id started.fls_run_id
                  | Masc.Tui_decode_fusion.Fusion_historical_evidence _ -> false)
           with
           | Some cursor ->
               state.fusion_cursor <- cursor;
               state.fusion_launch <- None
           | None ->
               state.fusion_cursor <- next_cursor;
               (* Each read that does not carry it spends one of the waits.
                  Spent, the wait ends rather than moving the cursor onto
                  that run at whatever later refresh first carries it. *)
               let reads_left = started.fls_reads_left - 1 in
               state.fusion_launch <-
                 (if reads_left > 0 then
                    Some (Fusion_launch_started { started with fls_reads_left = reads_left })
                  else None))
       | Some (Fusion_launch_reading_presets _ | Fusion_launch_open _) | None ->
           state.fusion_cursor <- next_cursor);
      (match state.fusion_mode, current_selected_id with
       | Fusion_detail run_id, Some selected
         when String.equal ("run:" ^ run_id) selected
              && List.exists (String.equal selected) next_ids ->
           ()
       | Fusion_detail _, _ ->
           state.fusion_mode <- Fusion_list;
           state.fusion_scroll <- 0;
           state.fusion_detail <- None;
           state.fusion_detail_error <- None;
           state.fusion_detail_generation <- state.fusion_detail_generation + 1
       | Fusion_historical_detail _, _ | Fusion_list, _ -> ())
  | Error detail ->
      (* A refresh of rows already held settles as stale and keeps them; a
         failed refresh does not read as an empty registry. *)
      state.fusion_runs <-
        Masc_tui_fetched.complete ~equal:Unit.equal state.fusion_runs request (Error detail)

let apply_fusion_detail_load state generation run_id result =
  if
    generation = state.fusion_detail_generation
    &&
    match state.fusion_mode with
    | Fusion_detail current -> String.equal current run_id
    | Fusion_historical_detail _ | Fusion_list -> false
  then
    match result with
    | Ok detail when String.equal detail.Masc.Tui_decode_fusion.fud_run.fur_run_id run_id ->
        state.fusion_detail <- Some detail;
        state.fusion_detail_error <- None
    | Ok detail ->
        state.fusion_detail_error <-
          Some
            (Printf.sprintf "fusion detail returned run %s for request %s"
               detail.Masc.Tui_decode_fusion.fud_run.fur_run_id run_id)
    | Error detail -> state.fusion_detail_error <- Some detail

let apply_fusion_historical_detail_load state generation reference result =
  if generation = state.fusion_detail_generation
     && (match state.fusion_mode with
         | Fusion_historical_detail current -> current = reference
         | Fusion_list | Fusion_detail _ -> false)
  then
    match result with
    | Ok detail when detail.Masc.Tui_decode_fusion.fhd_reference = reference ->
        state.fusion_historical_detail <- Some detail;
        state.fusion_detail_error <- None
    | Ok _ ->
        state.fusion_detail_error <- Some "Fusion Board original returned a different reference"
    | Error error -> state.fusion_detail_error <- Some error

let runs_loaded state request result =
  (* An answer the list has moved past is dropped here, before the cursor
     bookkeeping reads it. *)
  if Masc_tui_fetched.is_current ~equal:Unit.equal state.fusion_runs request then
    apply_fusion_runs_load state request result

let detail_loaded state ~generation ~run_id result =
  (match state.fusion_detail_inflight with
   | Some (inflight_generation, inflight_run_id)
     when inflight_generation = generation
          && String.equal inflight_run_id run_id ->
       state.fusion_detail_inflight <- None
   | Some _ | None -> ());
  apply_fusion_detail_load state generation run_id result

let historical_detail_loaded state ~generation ~reference result =
  (match state.fusion_historical_inflight with
   | Some (inflight_generation, inflight_reference)
     when inflight_generation = generation && inflight_reference = reference ->
       state.fusion_historical_inflight <- None
   | Some _ | None -> ());
  apply_fusion_historical_detail_load state generation reference result

let launch_options_loaded state ~generation ~report result =
  (match state.fusion_launch with
   | Some (Fusion_launch_reading_presets pending) when pending = generation ->
       (match result with
        | Error detail ->
            state.fusion_launch <- None;
            (* [fusion_launch_error] draws the reason now and the event
               keeps it: a successful list load clears that line, and the
               cadence issues one every two seconds, so the line alone
               would show the reason for less time than it takes to read. *)
            state.fusion_launch_error <- Some detail;
            report ("Fusion launch: " ^ detail)
        | Ok options ->
            let keepers = List.map (fun (k : keeper) -> k.k_name) state.keepers in
            (* The run under the cursor names the Keeper the operator is
               looking at; without one, the roster's own cursor does. *)
            let keeper =
              match selected_fusion_entry state with
              | Some (Masc.Tui_decode_fusion.Fusion_retained_run run) -> Some run.fur_keeper
              | Some (Masc.Tui_decode_fusion.Fusion_historical_evidence _) | None ->
                  Option.map (fun (k : keeper) -> k.k_name) (selected_keeper state)
            in
            (match Masc_tui_fusion_launch.open_form ~keepers ~keeper ~options with
             | Ok launch ->
                 state.fusion_launch <- Some (Fusion_launch_open launch);
                 state.fusion_launch_error <- None
             | Error detail ->
                 state.fusion_launch <- None;
                 state.fusion_launch_error <- Some detail;
                 report ("Fusion launch: " ^ detail)))
   | Some (Fusion_launch_reading_presets _ | Fusion_launch_open _ | Fusion_launch_started _)
   | None -> ())

let launched state ~generation ~report ~refresh result =
  (match state.fusion_launch with
   | Some (Fusion_launch_open launch)
     when generation = state.fusion_launch_generation
          && Masc_tui_fusion_launch.submitting launch ->
       (match result with
        | Error detail ->
            state.fusion_launch <-
              Some (Fusion_launch_open (Masc_tui_fusion_launch.refused ~detail launch));
            state.fusion_scroll <- 0;
            report ("Fusion launch refused: " ^ detail)
        | Ok run_id ->
            (* The list selects the run once it carries it; a list read
               already in flight may answer without it. *)
            state.fusion_launch <-
              Some
                (Fusion_launch_started
                   { fls_run_id = run_id
                   ; fls_reads_left = Masc_tui_types.fusion_started_list_reads
                   });
            state.fusion_scroll <- 0;
            report ("Fusion run " ^ run_id ^ " started");
            refresh ())
   | Some (Fusion_launch_reading_presets _ | Fusion_launch_open _ | Fusion_launch_started _)
   | None -> ())

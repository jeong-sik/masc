(** Fusion response application; transport and reporting remain caller-owned. *)

open Masc_tui_types

(* A change observed after a request started cannot be answered by that
   request. Several such changes share one follow-up, after the owner settles. *)
type demand = Share | After_change
type completion = Applied | Reread | Await_observer | Obsolete

type changed_runs = { any : bool; open_run : bool }
let no_changed_runs = { any = false; open_run = false }
let note_run_changed ~open_run_id changed ~run_id =
  { any = true
  ; open_run = changed.open_run || Option.exists (String.equal run_id) open_run_id
  }

let open_identity state =
  match state.fusion_mode with
  | Fusion_list -> None
  | Fusion_detail run_id -> Some ("run:" ^ run_id)
  | Fusion_historical_detail reference -> Some ("board:" ^ reference.fhe_post_id)

let begin_runs state ~demand =
  match Masc_tui_fetched.start ~equal:Unit.equal state.fusion_runs ~key:() with
  | Masc_tui_fetched.Already_loading ->
      if demand = After_change then state.fusion_runs_reread_pending <- true;
      None
  | Masc_tui_fetched.Started (reading, request) ->
      state.fusion_runs <- reading;
      state.fusion_runs_reread_pending <- false;
      state.fusion_runs_open_at_start <- open_identity state;
      Some request

let begin_detail state ~demand ~run_id =
  match state.fusion_detail_inflight with
  | Some (generation, current)
    when generation = state.fusion_detail_generation && String.equal current run_id ->
      if demand = After_change then state.fusion_detail_reread_pending <- true;
      None
  | Some _ | None ->
      state.fusion_detail_generation <- state.fusion_detail_generation + 1;
      let generation = state.fusion_detail_generation in
      state.fusion_detail_inflight <- Some (generation, run_id);
      state.fusion_detail_reread_pending <- false;
      Some generation

let begin_historical state ~demand ~reference =
  match state.fusion_historical_inflight with
  | Some (generation, current)
    when generation = state.fusion_detail_generation && current = reference ->
      if demand = After_change then state.fusion_historical_reread_pending <- true;
      None
  | Some _ | None ->
      state.fusion_detail_generation <- state.fusion_detail_generation + 1;
      let generation = state.fusion_detail_generation in
      state.fusion_historical_inflight <- Some (generation, reference);
      state.fusion_historical_reread_pending <- false;
      Some generation

(* Subscribe first, then re-read the visible projection: its initial read may
   predate the subscription, and a resumed feed may have missed a gap. *)
let revalidate_visible state ~runs ~detail ~historical =
  if server_authority_ready state then
    match state.view with
    | Fusion ->
        runs ();
        (match state.fusion_mode with
         | Fusion_list -> ()
         | Fusion_detail run_id -> detail run_id
         | Fusion_historical_detail reference -> historical reference)
    | Keepers Keeper_detail when state.detail_tab = Detail_runs -> runs ()
    | Keepers (Keeper_detail | Keeper_list | Keeper_logs | Keeper_calls
              | Keeper_message | Keeper_runtime_pick)
    | Overview | Acting | Metrics | Memory | Lanes | Clients | Board
    | Approvals | Planning | Schedules | Verification | Harness
    | Repositories | Code | Changes | Connectors | Runtime | Config
    | Resources | Tools | System_logs -> ()

let apply_fusion_runs_load state request ~superseded = function
  | Ok (snapshot : Masc.Tui_decode_fusion.fusion_snapshot) ->
      let keeper_run_id =
        Option.map (fun (_, run) -> run.Masc.Tui_decode_fusion.fur_run_id)
          (Masc_tui_fusion_model.selected_keeper_run state)
      in
      let current_selected_id =
        match state.fusion_mode with
        | Fusion_historical_detail reference -> Some (Masc_tui_fusion_model.fusion_entry_identity (Masc.Tui_decode_fusion.Fusion_historical_evidence reference))
        | Fusion_detail run_id -> Some ("run:" ^ run_id)
        | Fusion_list -> Option.map Masc_tui_fusion_model.fusion_entry_identity (Masc_tui_fusion_model.selected_fusion_entry state)
      in
      (* A read overtaken by a change is useful progress but cannot prove a
         selected row vanished. Keep just the selected old rows until a
         post-change answer settles; this also preserves deliberate cursor
         moves made while that answer is in flight. *)
      let snapshot =
        if not superseded then snapshot else
        match Masc_tui_fusion_model.fusion_snapshot state with
        | None -> snapshot
        | Some previous ->
            let selected id =
              current_selected_id = Some id
              || Option.map (fun run_id -> "run:" ^ run_id) keeper_run_id = Some id in
            let missing_run (run : Masc.Tui_decode_fusion.fusion_run) =
              selected ("run:" ^ run.fur_run_id)
              && not (List.exists (fun (next : Masc.Tui_decode_fusion.fusion_run) ->
                String.equal run.fur_run_id next.fur_run_id) snapshot.fus_runs) in
            let missing_evidence (entry : Masc.Tui_decode_fusion.fusion_historical_evidence) =
              selected ("board:" ^ entry.fhe_post_id)
              && not (List.exists (fun (next : Masc.Tui_decode_fusion.fusion_historical_evidence) ->
                String.equal entry.fhe_post_id next.fhe_post_id) snapshot.fus_historical_evidence) in
            { snapshot with
              fus_runs = snapshot.fus_runs @ List.filter missing_run previous.fus_runs;
              fus_historical_evidence = snapshot.fus_historical_evidence
                @ List.filter missing_evidence previous.fus_historical_evidence }
      in
      let next_ids =
        List.map Masc_tui_fusion_model.fusion_entry_identity (Masc_tui_fusion_model.fusion_snapshot_entries snapshot)
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
      let keeper_runs = Masc_tui_fusion_model.selected_keeper_runs state in
      state.keeper_run_cursor <-
        Option.bind keeper_run_id (fun id ->
          List.find_index (fun run -> String.equal run.Masc.Tui_decode_fusion.fur_run_id id) keeper_runs)
        |> Option.value ~default:(max 0 (min state.keeper_run_cursor (List.length keeper_runs - 1)));
      if not superseded then state.fusion_launch_error <- None;
      (* A run the form just started is selected the first time the list
         carries it, and the wait ends there. *)
      (match state.fusion_launch with
       | Some (Fusion_launch_started _) when superseded ->
           state.fusion_cursor <- next_cursor
       | Some (Fusion_launch_started started) -> (
           match
             Masc_tui_fusion_model.fusion_snapshot_entries snapshot
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
       | Fusion_detail _, _ when superseded -> ()
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
  if not (Masc_tui_fetched.is_current ~equal:Unit.equal state.fusion_runs request) then Obsolete
  else
  let open_now = open_identity state in
  let selection_changed = Option.is_some open_now && open_now <> state.fusion_runs_open_at_start in
  if state.fusion_runs_reread_pending || selection_changed || state.observer = Observer_opening then begin
    let reread = state.fusion_runs_reread_pending || selection_changed in
    state.fusion_runs_reread_pending <- false;
    (* Progress is still useful under a continuous event stream, but this
       snapshot cannot establish that a selected or launched run is absent.
       Keep it visibly stale while the newer read is outstanding. *)
    apply_fusion_runs_load state request ~superseded:true result;
    (match result with
     | Ok _ ->
         state.fusion_runs <- Masc_tui_fetched.invalidate
             ~reason:"Fusion changed while reading; refreshing" state.fusion_runs
     | Error _ -> ());
    if reread then Reread else Await_observer
  end else begin
    apply_fusion_runs_load state request ~superseded:false result;
    Applied
  end

let mark_detail_stale state =
  let message = "Fusion changed while reading; refreshing" in
  state.fusion_detail_error <- Some
      (match state.fusion_detail_error with
       | None -> message
       | Some error -> message ^ " (last read: " ^ error ^ ")")

let detail_loaded state ~generation ~run_id result =
  match state.fusion_detail_inflight with
   | Some (inflight_generation, inflight_run_id)
     when inflight_generation = generation
          && String.equal inflight_run_id run_id ->
       state.fusion_detail_inflight <- None;
       let reread = state.fusion_detail_reread_pending in
       state.fusion_detail_reread_pending <- false;
       if generation <> state.fusion_detail_generation
          || state.fusion_mode <> Fusion_detail run_id then Obsolete
       else if reread || state.observer = Observer_opening then begin
         apply_fusion_detail_load state generation run_id result;
         mark_detail_stale state;
         if reread then Reread else Await_observer
       end
       else begin apply_fusion_detail_load state generation run_id result; Applied end
   | Some _ | None -> Obsolete

let historical_detail_loaded state ~generation ~reference result =
  match state.fusion_historical_inflight with
   | Some (inflight_generation, inflight_reference)
     when inflight_generation = generation && inflight_reference = reference ->
       state.fusion_historical_inflight <- None;
       let reread = state.fusion_historical_reread_pending in
       state.fusion_historical_reread_pending <- false;
       if generation <> state.fusion_detail_generation
          || state.fusion_mode <> Fusion_historical_detail reference then Obsolete
       else if reread || state.observer = Observer_opening then begin
         apply_fusion_historical_detail_load state generation reference result;
         mark_detail_stale state;
         if reread then Reread else Await_observer
       end
       else begin apply_fusion_historical_detail_load state generation reference result; Applied end
   | Some _ | None -> Obsolete

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
              match Masc_tui_fusion_model.selected_fusion_entry state with
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

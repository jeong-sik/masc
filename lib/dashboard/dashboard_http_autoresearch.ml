(** Dashboard HTTP autoresearch — loop listing and detail for the dashboard.

    Scans both in-memory active loops and persisted state files from
    .masc/autoresearch/{loop_id}/state.json.

    @since 2.122.0 *)

let cycle_record_json (r : Autoresearch_types.cycle_record) : Yojson.Safe.t =
  Autoresearch_serde.cycle_to_yojson r

let loop_summary_json (base_path : string)
    (state : Autoresearch_types.loop_state) : Yojson.Safe.t =
  let recent_cycles =
    state.history
    |> List.filteri (fun i _ -> i < 5)
    |> List.map cycle_record_json
  in
  let insights =
    state.insights
    |> List.filteri (fun i _ -> i < 10)
    |> List.map (fun s -> `String s)
  in
  let link =
    Autoresearch_storage.load_swarm_link_by_loop ~base_path state.loop_id
  in
  `Assoc
    [
      ("loop_id", `String state.loop_id);
      ("goal", `String state.goal);
      ("metric_fn", `String state.metric_fn);
      ("model_model", `String state.model_model);
      ("target_file", `String state.target_file);
      ("status", `String (Autoresearch_serde.status_to_string state.status));
      ("current_cycle", `Int state.current_cycle);
      ("max_cycles", `Int state.max_cycles);
      ("baseline", `Float state.baseline);
      ("best_score", `Float state.best_score);
      ("best_cycle", `Int state.best_cycle);
      ("total_keeps", `Int state.total_keeps);
      ("total_discards", `Int state.total_discards);
      ("elapsed_s", `Float (Time_compat.now () -. state.start_time));
      ("workdir", `String state.workdir);
      ("source_workdir", `String state.source_workdir);
      ( "program_note",
        match state.program_note with Some v -> `String v | None -> `Null );
      ("warnings", `List (List.map (fun v -> `String v) state.warnings));
      ("insights", `List insights);
      ("recent_cycles", `List recent_cycles);
      ( "error",
        match state.error_message with Some e -> `String e | None -> `Null );
      ( "session_id",
        match link with Some l -> `String l.session_id | None -> `Null );
      ( "queued_hypothesis",
        match state.queued_hypothesis with
        | Some v -> `String v
        | None -> `Null );
    ]

let persisted_to_loop_summary_json (base_path : string)
    (p : Autoresearch_types.persisted_summary) : Yojson.Safe.t =
  let link =
    Autoresearch_storage.load_swarm_link_by_loop ~base_path p.loop_id
  in
  `Assoc
    [
      ("loop_id", `String p.loop_id);
      ("goal", `String p.goal);
      ("metric_fn", `String p.metric_fn);
      ("model_model", `String p.model_model);
      ("target_file", `String p.target_file);
      ("status", `String (Autoresearch_serde.status_to_string p.status));
      ("current_cycle", `Int p.current_cycle);
      ("max_cycles", `Int p.max_cycles);
      ("baseline", `Float p.baseline);
      ("best_score", `Float p.best_score);
      ("best_cycle", `Int p.best_cycle);
      ("total_keeps", `Int p.total_keeps);
      ("total_discards", `Int p.total_discards);
      ("elapsed_s", `Float p.elapsed_s);
      ("workdir", `String p.workdir);
      ("source_workdir", `String p.source_workdir);
      ( "program_note",
        match p.program_note with Some v -> `String v | None -> `Null );
      ("warnings", `List (List.map (fun v -> `String v) p.warnings));
      ("insights", `List []);
      ("recent_cycles", `List []);
      ( "error",
        match p.error_message with Some e -> `String e | None -> `Null );
      ( "session_id",
        match link with Some l -> `String l.session_id | None -> `Null );
      ( "queued_hypothesis",
        match p.queued_hypothesis with
        | Some v -> `String v
        | None -> `Null );
    ]

(** Sort key: (status_rank, negative_elapsed) for running-first, newest-first ordering. *)
type sort_key = { status_rank : int; neg_elapsed : float }

(** Build the loops list JSON for GET /api/v1/autoresearch/loops.
    Merges in-memory active loops with persisted-only loops.
    Converts to JSON early to avoid polymorphic variant type mismatch. *)
let autoresearch_loops_json ~(base_path : string) : Yojson.Safe.t =
  (* 1. Collect in-memory active loops as (id, sort_key, json) *)
  let active_entries =
    Autoresearch.with_loops_ro (fun () ->
      Hashtbl.fold
        (fun _id (state : Autoresearch_types.loop_state) acc ->
          let json = loop_summary_json base_path state in
          let sk =
            { status_rank =
                (match state.status with Running -> 0 | _ -> 1);
              neg_elapsed = -. (Time_compat.now () -. state.start_time);
            }
          in
          (state.loop_id, sk, json) :: acc)
        Autoresearch.active_loops [])
  in
  let active_ids =
    List.map (fun (id, _, _) -> id) active_entries
  in
  (* 2. Scan persisted loops not in memory *)
  let persisted_ids =
    Autoresearch.scan_persisted_loop_ids ~base_path
    |> List.filter (fun id -> not (List.mem id active_ids))
  in
  let persisted_entries =
    List.filter_map
      (fun loop_id ->
        match Autoresearch.load_state ~base_path loop_id with
        | Some summary ->
            let json = persisted_to_loop_summary_json base_path summary in
            let sk =
              { status_rank =
                  (match summary.status with Running -> 0 | _ -> 1);
                neg_elapsed = -. summary.elapsed_s;
              }
            in
            Some (loop_id, sk, json)
        | None -> None)
      persisted_ids
  in
  (* 3. Merge and sort *)
  let all = active_entries @ persisted_entries in
  let sorted =
    List.sort
      (fun (_, a, _) (_, b, _) ->
        let by_status = Int.compare a.status_rank b.status_rank in
        if by_status <> 0 then by_status
        else Float.compare a.neg_elapsed b.neg_elapsed)
      all
  in
  `Assoc
    [
      ("loops", `List (List.map (fun (_, _, json) -> json) sorted));
      ("total", `Int (List.length sorted));
    ]

(** Build the loop detail JSON for GET /api/v1/autoresearch/loops/:loopId.
    Includes full cycle history. *)
let autoresearch_loop_detail_json ~(base_path : string)
    ~(loop_id : string) ~(history_limit : int) :
    (Yojson.Safe.t, string) result =
  (* Try in-memory first *)
  let in_memory =
    Autoresearch.with_loops_ro (fun () ->
      Hashtbl.find_opt Autoresearch.active_loops loop_id)
  in
  let base_json, insights_list, full_history =
    match in_memory with
    | Some state ->
        let json = loop_summary_json base_path state in
        let insights = state.insights in
        let history =
          Autoresearch.load_cycle_history ~base_path loop_id
        in
        (json, insights, history)
    | None -> (
        match Autoresearch.load_state ~base_path loop_id with
        | Some summary ->
            let json = persisted_to_loop_summary_json base_path summary in
            let history =
              Autoresearch.load_cycle_history ~base_path loop_id
            in
            (json, [], history)
        | None ->
            let msg = Printf.sprintf "Loop %s not found" loop_id in
            raise (Invalid_argument msg))
  in
  (* Replace recent_cycles and insights with full data *)
  let history_json =
    full_history
    |> List.rev
    |> (fun l ->
         if history_limit > 0 then
           List.filteri (fun i _ -> i < history_limit) l
         else l)
    |> List.map cycle_record_json
  in
  let insights_json =
    insights_list
    |> List.filteri (fun i _ -> i < 10)
    |> List.map (fun s -> `String s)
  in
  match base_json with
  | `Assoc fields ->
      let fields =
        fields
        |> List.map (fun (k, v) ->
               match k with
               | "recent_cycles" -> (k, `Null)
               | "insights" -> (k, `List insights_json)
               | _ -> (k, v))
      in
      Ok
        (`Assoc
          (fields
          @ [
              ("history", `List history_json);
              ("history_count", `Int (List.length full_history));
            ]))
  | other -> Ok other

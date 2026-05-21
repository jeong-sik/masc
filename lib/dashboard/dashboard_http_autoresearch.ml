(** Dashboard HTTP autoresearch — loop listing and detail for the dashboard.

    Scans both in-memory active loops and persisted state files from
    .masc/autoresearch/{loop_id}/state.json.

    @since 2.122.0 *)

let cycle_record_json (r : Autoresearch_types.cycle_record) : Yojson.Safe.t =
  Autoresearch_serde.cycle_to_yojson r

let updated_at_json = Json_util.float_opt_to_json

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
    Autoresearch_storage.load_execution_link_by_loop ~base_path state.loop_id
  in
  `Assoc
    [
      ("loop_id", `String state.loop_id);
      ("goal", `String state.goal);
      ("metric_fn", `String state.metric_fn);
      ("model_model", `String "runtime");
      ("target_file", `String state.target_file);
      ("status", `String (Autoresearch_serde.status_to_string state.status));
      ("current_cycle", `Int state.current_cycle);
      ("max_cycles", `Int state.max_cycles);
      ("baseline", `Float state.baseline);
      ("best_score", `Float state.best_score);
      ("best_cycle", `Int state.best_cycle);
      ("target_score", Json_util.float_opt_to_json state.target_score);
      ("target_reached", `Bool (Autoresearch.target_reached state));
      ("total_keeps", `Int state.total_keeps);
      ("total_discards", `Int state.total_discards);
      ("elapsed_s", `Float (Time_compat.now () -. state.start_time));
      ("updated_at", `Float state.updated_at);
      ("live", `Bool true);
      ("workdir", `String state.workdir);
      ("source_workdir", `String state.source_workdir);
      ( "program_note",
        Json_util.string_opt_to_json state.program_note );
      ("warnings", `List (List.map (fun v -> `String v) state.warnings));
      ("insights", `List insights);
      ("recent_cycles", `List recent_cycles);
      ( "error",
        Json_util.string_opt_to_json state.error_message );
      ( "session_id",
        Json_util.string_opt_to_json (Option.map (fun (l : Autoresearch_types.execution_link) -> l.session_id) link) );
      ( "operation_id",
        Json_util.string_opt_to_json (Option.bind link (fun (l : Autoresearch_types.execution_link) -> l.operation_id)) );
      ( "task_id",
        Json_util.string_opt_to_json
          (Option.bind link (fun (l : Autoresearch_types.execution_link) -> l.task_id)) );
      ( "linked_at",
        Json_util.float_opt_to_json (Option.map (fun (l : Autoresearch_types.execution_link) -> l.linked_at) link) );
      ( "queued_hypothesis",
        Json_util.string_opt_to_json state.queued_hypothesis );
    ]

let persisted_to_loop_summary_json (base_path : string)
    (p : Autoresearch_types.persisted_summary) : Yojson.Safe.t =
  let link =
    Autoresearch_storage.load_execution_link_by_loop ~base_path p.loop_id
  in
  `Assoc
    [
      ("loop_id", `String p.loop_id);
      ("goal", `String p.goal);
      ("metric_fn", `String p.metric_fn);
      ("model_model", `String "runtime");
      ("target_file", `String p.target_file);
      ("status", `String (Autoresearch_serde.status_to_string p.status));
      ("current_cycle", `Int p.current_cycle);
      ("max_cycles", `Int p.max_cycles);
      ("baseline", `Float p.baseline);
      ("best_score", `Float p.best_score);
      ("best_cycle", `Int p.best_cycle);
      ("target_score", Json_util.float_opt_to_json p.target_score);
      ( "target_reached",
        `Bool
          (match p.target_score with
           | None -> false
           | Some target ->
               if p.lower_is_better then p.best_score <= target
               else p.best_score >= target) );
      ("total_keeps", `Int p.total_keeps);
      ("total_discards", `Int p.total_discards);
      ("elapsed_s", `Float p.elapsed_s);
      ("updated_at", updated_at_json p.updated_at);
      ("live", `Bool false);
      ("workdir", `String p.workdir);
      ("source_workdir", `String p.source_workdir);
      ( "program_note",
        Json_util.string_opt_to_json p.program_note );
      ("warnings", `List (List.map (fun v -> `String v) p.warnings));
      ("insights", `List []);
      ("recent_cycles", `List []);
      ( "error",
        Json_util.string_opt_to_json p.error_message );
      ( "session_id",
        Json_util.string_opt_to_json (Option.map (fun (l : Autoresearch_types.execution_link) -> l.session_id) link) );
      ( "operation_id",
        Json_util.string_opt_to_json (Option.bind link (fun (l : Autoresearch_types.execution_link) -> l.operation_id)) );
      ( "task_id",
        Json_util.string_opt_to_json
          (Option.bind link (fun (l : Autoresearch_types.execution_link) -> l.task_id)) );
      ( "linked_at",
        Json_util.float_opt_to_json (Option.map (fun (l : Autoresearch_types.execution_link) -> l.linked_at) link) );
      ( "queued_hypothesis",
        Json_util.string_opt_to_json p.queued_hypothesis );
    ]

(** Sort key: live loops first, then running loops, then most recently updated. *)
type sort_key = {
  live_rank : int;
  status_rank : int;
  neg_updated_at : float;
}

let safe_active_entry_json ~(base_path : string)
    (state : Autoresearch_types.loop_state) =
  try
    let json = loop_summary_json base_path state in
    let sk =
      {
        live_rank = 0;
        status_rank =
          (match state.status with Running -> 0 | Completed | Stopped | Error -> 1);
        neg_updated_at = -. state.updated_at;
      }
    in
    Some (state.loop_id, sk, json)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Autoresearch.warn
        "dashboard autoresearch list skipped active loop %s: %s"
        state.loop_id (Printexc.to_string exn);
      None

let safe_persisted_entry_json ~(base_path : string)
    (summary : Autoresearch_types.persisted_summary) =
  try
    let json = persisted_to_loop_summary_json base_path summary in
    let sk =
      {
        live_rank = 1;
        status_rank =
          (match summary.status with Running -> 0 | Completed | Stopped | Error -> 1);
        neg_updated_at =
          -. Option.value ~default:0.0 summary.updated_at;
      }
    in
    Some (summary.loop_id, sk, json)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Autoresearch.warn
        "dashboard autoresearch list skipped persisted loop %s: %s"
        summary.loop_id (Printexc.to_string exn);
      None

let persisted_summaries_cache : (string, float * Autoresearch_types.persisted_summary) Hashtbl.t = Hashtbl.create 1024

let load_state_cached ~base_path loop_id =
  let path = Autoresearch.state_file ~base_path loop_id in
  try
    let stats = Unix.stat path in
    let mtime = stats.st_mtime in
    match Hashtbl.find_opt persisted_summaries_cache loop_id with
    | Some (cached_mtime, summary) when cached_mtime = mtime ->
        Some summary
    | _ ->
        (match Autoresearch.load_state ~base_path loop_id with
         | Some summary as result ->
             Hashtbl.replace persisted_summaries_cache loop_id (mtime, summary);
             result
         | None -> None)
  with
  (* Issue #8619: re-raise cancellation so a shutdown mid-load does
     not silently render the dashboard panel as "no data". Other
     exceptions (Unix.stat ENOENT, JSON parse failure on a partial
     write) keep the prior cached/None behaviour. *)
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> None

(** Build the loops list JSON for GET /api/v1/autoresearch/loops.
    Merges in-memory active loops with persisted-only loops.
    Converts to JSON early to avoid polymorphic variant type mismatch. *)
let autoresearch_loops_json ~(base_path : string) ?(offset = 0) ?(limit = 100) () : Yojson.Safe.t =
  (* 1. Collect in-memory active loops as (id, sort_key, json) *)
  let active_entries =
    Autoresearch.with_loops_ro (fun () ->
      Hashtbl.fold
        (fun _id (state : Autoresearch_types.loop_state) acc ->
          match safe_active_entry_json ~base_path state with
          | Some entry -> entry :: acc
          | None -> acc)
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
        match load_state_cached ~base_path loop_id with
        | Some summary -> safe_persisted_entry_json ~base_path summary
        | None -> None)
      persisted_ids
  in
  (* 3. Merge and sort *)
  let all = active_entries @ persisted_entries in
  let sorted =
    List.sort
      (fun (_, a, _) (_, b, _) ->
        let by_live = Int.compare a.live_rank b.live_rank in
        if by_live <> 0 then by_live
        else
        let by_status = Int.compare a.status_rank b.status_rank in
        if by_status <> 0 then by_status
        else Float.compare a.neg_updated_at b.neg_updated_at)
      all
  in
  let total = List.length sorted in
  let sliced =
    sorted
    |> List.filteri (fun i _ -> i >= offset && i < offset + limit)
  in
  `Assoc
    [
      ("loops", `List (List.map (fun (_, _, json) -> json) sliced));
      ("total", `Int total);
      ("offset", `Int offset);
      ("limit", `Int limit);
    ]

let escape_csv s =
  let s = String.concat "\"\"" (String.split_on_char '"' s) in
  "\"" ^ s ^ "\""

let json_string_safe json key =
  match Yojson.Safe.Util.member key json with
  | `String s -> escape_csv s
  | `Null -> ""
  | _ -> ""

let json_number_safe json key =
  match Yojson.Safe.Util.member key json with
  | `Int i -> string_of_int i
  | `Float f -> Printf.sprintf "%.4f" f
  | `Null -> ""
  | _ -> ""

let json_bool_safe json key =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> string_of_bool b
  | `Null -> ""
  | _ -> ""

let autoresearch_loops_csv ~(base_path : string) : string =
  let active_entries =
    Autoresearch.with_loops_ro (fun () ->
      Hashtbl.fold
        (fun _id (state : Autoresearch_types.loop_state) acc ->
          match safe_active_entry_json ~base_path state with
          | Some entry -> entry :: acc
          | None -> acc)
        Autoresearch.active_loops [])
  in
  let active_ids =
    List.map (fun (id, _, _) -> id) active_entries
  in
  let persisted_ids =
    Autoresearch.scan_persisted_loop_ids ~base_path
    |> List.filter (fun id -> not (List.mem id active_ids))
  in
  let persisted_entries =
    List.filter_map
      (fun loop_id ->
        match load_state_cached ~base_path loop_id with
        | Some summary -> safe_persisted_entry_json ~base_path summary
        | None -> None)
      persisted_ids
  in
  let all = active_entries @ persisted_entries in
  let sorted =
    List.sort
      (fun (_, a, _) (_, b, _) ->
        let by_live = Int.compare a.live_rank b.live_rank in
        if by_live <> 0 then by_live
        else
        let by_status = Int.compare a.status_rank b.status_rank in
        if by_status <> 0 then by_status
        else Float.compare a.neg_updated_at b.neg_updated_at)
      all
  in
  let headers = "loop_id,author,goal,metric_fn,model_model,target_file,status,current_cycle,max_cycles,baseline,best_score,best_cycle,total_keeps,total_discards,elapsed_s,updated_at,live\n" in
  let rows =
    List.map (fun (_, _, json) ->
      String.concat "," [
        json_string_safe json "loop_id";
        json_string_safe json "author";
        json_string_safe json "goal";
        json_string_safe json "metric_fn";
        json_string_safe json "model_model";
        json_string_safe json "target_file";
        json_string_safe json "status";
        json_number_safe json "current_cycle";
        json_number_safe json "max_cycles";
        json_number_safe json "baseline";
        json_number_safe json "best_score";
        json_number_safe json "best_cycle";
        json_number_safe json "total_keeps";
        json_number_safe json "total_discards";
        json_number_safe json "elapsed_s";
        json_number_safe json "updated_at";
        json_bool_safe json "live";
      ] ^ "\n"
    ) sorted
  in
  String.concat "" (headers :: rows)

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
  let detail =
    match in_memory with
    | Some state ->
        let json = loop_summary_json base_path state in
        let insights = state.insights in
        let history =
          Autoresearch.load_cycle_history ~base_path loop_id
        in
        Ok (json, insights, history)
    | None -> (
        match load_state_cached ~base_path loop_id with
        | Some summary ->
            let json = persisted_to_loop_summary_json base_path summary in
            let history =
              Autoresearch.load_cycle_history ~base_path loop_id
            in
            Ok (json, [], history)
        | None ->
            Error (Printf.sprintf "Loop %s not found" loop_id))
  in
  match detail with
  | Error msg -> Error msg
  | Ok (base_json, insights_list, full_history) ->
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

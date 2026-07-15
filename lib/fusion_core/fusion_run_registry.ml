(* Fusion — in-memory run registry for in-progress + recent fusion visibility
   (RFC-0266 §7 Phase 2/Phase D). The fusion tool registers a run [Running] at
   fork start and the sink/failure path marks it [Completed] on finish, so an
   operator surface (masc_fusion_status tool = Phase 3, dashboard = Phase 4)
   can show what is deliberating now and what just finished — instead of run_id
   only living in the caller's tool-result.

   Lock-free Atomic + CAS; optional append-only JSONL backing under
   [<base-path>/.masc/fusion-runs.jsonl] so history survives server restart.
   A register without a matching completion is retained as
   [Recovery_required] on replay. The registry never claims that a dead worker
   is still running, but it also never erases unfinished work.

   This module never wakes a keeper (that is the WAKE half, Phase 1). Recording
   a run is the visibility half and is intentionally side-effect-free beyond
   the in-memory table and the append-only log. *)

type recovery_reason = Worker_process_restarted

type persistence_error =
  | Append_failed of
      { path : string
      ; detail : string
      }

type completion_receipt =
  | Durable
  | Persistence_failed of persistence_error

type completion_error =
  | Unknown_run of string
  | Completion_persistence_failed of persistence_error

type run_status =
  | Running
  | Recovery_required of { reason : recovery_reason }
  | Completed of {
      ok : bool;
      (* ok=false일 때의 사람-가독 사유 + 안정 분류 태그. 2026-07-01 사고에서
         상태 표면(masc_fusion_status/SSE)이 status="failed"만 나르는 바람에
         키퍼가 원인을 얻을 tool-reachable 경로가 없었다 (mli 참조). *)
      failure : string option;
      failure_code : string option;
      receipt : completion_receipt;
    }

type run = {
  run_id : string;
  keeper : string;
  preset : string;
  started_at : float;  (* unix seconds from the keeper clock at fork start *)
  status : run_status;
}

type t = {
  runs : run list Atomic.t;
  path : string option;
}

(* Recent-history retention for [Completed] runs. Active and recovery-required
   runs are never evicted. This is log retention only; it never limits
   execution or invocation rate. *)
let max_completed_retained = 64

let create ?path () : t = { runs = Atomic.make []; path }

let is_unresolved (r : run) =
  match r.status with
  | Running | Recovery_required _
  | Completed { receipt = Persistence_failed _; _ } -> true
  | Completed { receipt = Durable; _ } -> false
;;

(* Keep every live/recovery/undurable-receipt run plus the
   [max_completed_retained] most recent durably completed runs. *)
let prune (runs : run list) : run list =
  let unresolved, completed = List.partition is_unresolved runs in
  let recent_completed =
    completed
    |> List.sort (fun a b -> Float.compare b.started_at a.started_at)
    |> List.filteri (fun i _ -> i < max_completed_retained)
  in
  unresolved @ recent_completed
;;

let rec update (t : t) (f : run list -> run list) =
  let cur = Atomic.get t.runs in
  let next = f cur in
  if not (Atomic.compare_and_set t.runs cur next) then update t f
;;

let persistence_error_to_string = function
  | Append_failed { path; detail } ->
    Printf.sprintf "fusion registry append failed for %s: %s" path detail
;;

let completion_error_to_string = function
  | Unknown_run run_id -> Printf.sprintf "unknown fusion run %s" run_id
  | Completion_persistence_failed error -> persistence_error_to_string error
;;

let append_event t event =
  match t.path with
  | None -> Ok ()
  | Some path ->
    (try
       Fs_compat.append_jsonl path (Fusion_run_registry_event.to_yojson event);
       Ok ()
     with
     | exn ->
       let error = Append_failed { path; detail = Printexc.to_string exn } in
       Log.Misc.warn "%s" (persistence_error_to_string error);
       Error error)
;;

let register_running t ~run_id ~keeper ~preset ~started_at =
  match
    append_event
      t
      (Fusion_run_registry_event.Register { run_id; keeper; preset; started_at })
  with
  | Error _ as error -> error
  | Ok () ->
    update t (fun runs ->
      let run = { run_id; keeper; preset; started_at; status = Running } in
      (* defensive: a re-registered run_id replaces its prior entry *)
      let without_dup = List.filter (fun r -> not (String.equal r.run_id run_id)) runs in
      prune (run :: without_dup));
    Ok ()
;;

let list_runs (t : t) : run list =
  Atomic.get t.runs |> List.sort (fun a b -> Float.compare b.started_at a.started_at)
;;

let get (t : t) ~run_id : run option =
  List.find_opt (fun r -> String.equal r.run_id run_id) (Atomic.get t.runs)
;;

let mark_completed (t : t) ~run_id ?failure ?failure_code ~ok () =
  match get t ~run_id with
  | None -> Error (Unknown_run run_id)
  | Some _ ->
    let persisted =
      append_event t
        (Fusion_run_registry_event.Complete { run_id; ok; failure; failure_code })
    in
    let receipt =
      match persisted with
      | Ok () -> Durable
      | Error error -> Persistence_failed error
    in
    update t (fun runs ->
      runs
      |> List.map (fun r ->
           if String.equal r.run_id run_id
           then { r with status = Completed { ok; failure; failure_code; receipt } }
           else r)
      |> prune);
    (match persisted with
     | Ok () -> Ok ()
     | Error error -> Error (Completion_persistence_failed error))
;;

(* Stable status vocabulary shared by every fusion-run surface (Phase 3 keeper
   tool, Phase 4 dashboard route, the [fusion_run_status] SSE event). Hand-
   written rather than [@@deriving] so the closed on-wire labels stay stable
   regardless of the variant shape. A consumer never reconstructs run state
   from the variant, only reads these labels. *)
let status_label = function
  | Running -> "running"
  | Recovery_required _ -> "recovery_required"
  | Completed { ok = true; _ } -> "completed"
  | Completed { ok = false; _ } -> "failed"
;;

(* The single per-run JSON object. The HTTP list endpoint, the SSE delta, and the
   keeper status tool all serialize a run through here so the field set and the
   status label never drift between surfaces. *)
let run_to_yojson (r : run) : Yojson.Safe.t =
  let base =
    [ ("run_id", `String r.run_id)
    ; ("keeper", `String r.keeper)
    ; ("preset", `String r.preset)
    ; ("started_at", `Float r.started_at)
    ; ("status", `String (status_label r.status))
    ]
  in
  (* 실패 사유는 additive 필드로만 싣는다 — 기존 소비자(tool/HTTP/SSE/프론트)의
     필드 집합은 그대로 유지된다. *)
  let failure_fields =
    match r.status with
    | Running | Completed { ok = true; _ } -> []
    | Recovery_required { reason = Worker_process_restarted } ->
      [ ("error", `String "worker process restarted before fusion completion")
      ; ("failure_code", `String "worker_process_restarted")
      ]
    | Completed { ok = false; failure; failure_code; _ } ->
      List.filter_map
        (fun (k, v) -> Option.map (fun s -> (k, `String s)) v)
        [ ("error", failure); ("failure_code", failure_code) ]
  in
  let receipt_fields =
    match r.status with
    | Running | Recovery_required _ -> []
    | Completed { receipt = Durable; _ } -> [ "receipt_status", `String "durable" ]
    | Completed { receipt = Persistence_failed error; _ } ->
      [ ("receipt_status", `String "persistence_failed")
      ; ("receipt_error", `String (persistence_error_to_string error))
      ]
  in
  `Assoc (base @ failure_fields @ receipt_fields)
;;

(* Replay helpers — used to hydrate the in-memory table from disk at boot. *)
let apply_event runs = function
  | Fusion_run_registry_event.Register { run_id; keeper; preset; started_at } ->
    let run = { run_id; keeper; preset; started_at; status = Running } in
    let without_dup = List.filter (fun r -> not (String.equal r.run_id run_id)) runs in
    run :: without_dup
  | Fusion_run_registry_event.Complete { run_id; ok; failure; failure_code } ->
    List.map
      (fun r ->
         if String.equal r.run_id run_id
         then { r with status = Completed { ok; failure; failure_code; receipt = Durable } }
         else r)
      runs
;;

let expose_replayed_running_as_recovery_required runs =
  let recovered =
    List.map
      (fun run ->
         match run.status with
         | Running ->
           { run with
             status = Recovery_required { reason = Worker_process_restarted }
           }
         | Recovery_required _ | Completed _ -> run)
      runs
  in
  let recovery_count =
    List.fold_left
      (fun count run ->
         match run.status with
         | Recovery_required _ -> count + 1
         | Running | Completed _ -> count)
      0
      recovered
  in
  (match recovery_count with
   | 0 -> ()
   | _ ->
     Log.Misc.warn
       "fusion_run_registry: %d unfinished run(s) require recovery after worker restart"
       recovery_count);
  recovered
;;

let parse_event_line ~path ~line_no line =
  match String.trim line with
  | "" -> Ok None
  | line ->
    (match
       try Ok (Yojson.Safe.from_string line) with
       | Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
     with
     | Error msg -> Error msg
     | Ok json ->
       (match Fusion_run_registry_event.of_yojson json with
        | Ok event -> Ok (Some event)
        | Error msg -> Error msg))
    |> Result.map_error (fun msg ->
      Printf.sprintf "%s:%d: %s" path line_no msg)
;;

let events_of_run (run : run) =
  let register =
    Fusion_run_registry_event.Register
      { run_id = run.run_id
      ; keeper = run.keeper
      ; preset = run.preset
      ; started_at = run.started_at
      }
  in
  match run.status with
  | Running | Recovery_required _ -> [ register ]
  | Completed { receipt = Persistence_failed _; _ } -> [ register ]
  | Completed { ok; failure; failure_code; receipt = Durable } ->
    [ register
    ; Fusion_run_registry_event.Complete
        { run_id = run.run_id; ok; failure; failure_code }
    ]
;;

let compact_replay_log path runs =
  let events =
    runs
    |> List.sort (fun a b -> Float.compare a.started_at b.started_at)
    |> List.concat_map events_of_run
  in
  let content =
    events
    |> List.map Fusion_run_registry_event.to_jsonl
    |> String.concat ""
  in
  try
    match Fs_compat.save_file_atomic path content with
    | Ok () -> ()
    | Error msg ->
      Log.Misc.warn "fusion_run_registry: replay compaction failed for %s: %s" path msg
  with
  | exn ->
    Log.Misc.warn
      "fusion_run_registry: replay compaction raised for %s: %s"
      path
      (Printexc.to_string exn)
;;

let fold_replay_events path =
  if not (Fs_compat.file_exists path)
  then [], [], false
  else (
    try
      let (events, malformed, _line_no), _boundary =
        Fs_compat.fold_appended_lines
          ~path
          ~from:0
          ~init:([], [], 1)
          ~f:(fun (events, malformed, line_no) line ->
            match parse_event_line ~path ~line_no line with
            | Ok None -> events, malformed, line_no + 1
            | Ok (Some event) -> event :: events, malformed, line_no + 1
            | Error msg -> events, msg :: malformed, line_no + 1)
      in
      let should_compact =
        match Fs_compat.file_size path with
        | Some size when _boundary < size ->
          Log.Misc.warn
            "fusion_run_registry: replay left unterminated tail in %s (%d/%d bytes \
             consumed)"
            path
            _boundary
            size;
          false
        | Some _ -> true
        | None ->
          Log.Misc.warn "fusion_run_registry: replay stat failed after streaming %s" path;
          false
      in
      List.rev events, List.rev malformed, should_compact
    with
    | exn ->
      Log.Misc.warn
        "fusion_run_registry: replay stream failed for %s: %s"
        path
        (Printexc.to_string exn);
      [], [], false)
;;

let replay path : t =
  let events, malformed, should_compact = fold_replay_events path in
  (match malformed with
   | [] -> ()
   | first :: _ as errors ->
     Log.Misc.warn
       "fusion_run_registry: skipped %d malformed replay line(s); first=%s"
       (List.length errors)
       first);
  let runs =
    List.fold_left apply_event [] events
    |> expose_replayed_running_as_recovery_required
    |> prune
  in
  if should_compact then compact_replay_log path runs;
  { runs = Atomic.make runs; path = Some path }
;;

(* Process-wide registry the fusion tool/sink write to (server-lifetime). Tests
   use a fresh [create ()] for state isolation, avoiding a reset backdoor.
   The backing path is set at server boot via [set_global] after replaying the
   persisted JSONL. *)
let global_atomic : t Atomic.t = Atomic.make (create ())

let global () : t = Atomic.get global_atomic

let set_global (t : t) = Atomic.set global_atomic t

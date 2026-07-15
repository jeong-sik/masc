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

module Claim_id = Fusion_run_registry_event.Claim_id

type persistence_error =
  | Append_failed of
      { path : string
      ; detail : string
      }
  | Operation_already_registered of string

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

type worker_state =
  | Registered
  | Claimed of Claim_id.t
  | Started of Claim_id.t

type run = {
  operation : Fusion_types.fusion_operation;
  started_at : float;  (* unix seconds from the keeper clock at fork start *)
  worker_state : worker_state;
  status : run_status;
}

type t = {
  runs : run list Atomic.t;
  path : string option;
  lock : Mutex.t;
}

(* Recent-history retention for [Completed] runs. Active and recovery-required
   runs are never evicted. This is log retention only; it never limits
   execution or invocation rate. *)
let max_completed_retained = 64

let create ?path () : t = { runs = Atomic.make []; path; lock = Mutex.create () }

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
  | Operation_already_registered operation_id ->
    Printf.sprintf "fusion operation %s is already registered" operation_id
;;

let completion_error_to_string = function
  | Unknown_run operation_id ->
    Printf.sprintf "unknown fusion run %s" operation_id
  | Completion_persistence_failed error -> persistence_error_to_string error
;;

let run_operation_id (run : run) = Fusion_types.fusion_operation_id run.operation
let operation_id = run_operation_id
let keeper (run : run) = run.operation.request.keeper
let preset (run : run) = run.operation.request.preset

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

let register_running t ~operation ~started_at =
  let id = Fusion_types.fusion_operation_id operation in
  Mutex.protect t.lock (fun () ->
    if List.exists (fun run -> String.equal (run_operation_id run) id) (Atomic.get t.runs)
    then Error (Operation_already_registered id)
    else
      (match
         append_event t
           (Fusion_run_registry_event.Register { operation; started_at })
       with
       | Error _ as error -> error
       | Ok () ->
         update t (fun runs ->
           prune ({ operation; started_at; worker_state = Registered; status = Running } :: runs));
         Ok ()))
;;

let list_runs (t : t) : run list =
  Atomic.get t.runs |> List.sort (fun a b -> Float.compare b.started_at a.started_at)
;;

let get (t : t) ~operation_id:expected : run option =
  List.find_opt
    (fun run -> String.equal (run_operation_id run) expected)
    (Atomic.get t.runs)
;;

type claim =
  { operation_id : string
  ; claim_id : Claim_id.t
  }

type claim_error =
  | Claim_unknown_operation of string
  | Claim_terminal_operation of string
  | Claim_already_owned of Claim_id.t
  | Claim_persistence_failed of persistence_error

type start_error =
  | Start_unknown_operation of string
  | Start_terminal_operation of string
  | Start_not_claimed of string
  | Start_claim_mismatch of string
  | Start_already_started of Claim_id.t
  | Start_persistence_failed of persistence_error

let claim_error_to_string = function
  | Claim_unknown_operation id -> Printf.sprintf "unknown fusion operation %s" id
  | Claim_terminal_operation id -> Printf.sprintf "fusion operation %s is terminal" id
  | Claim_already_owned id ->
    Printf.sprintf "fusion operation is already claimed by %s" (Claim_id.to_string id)
  | Claim_persistence_failed error -> persistence_error_to_string error
;;

let start_error_to_string = function
  | Start_unknown_operation id -> Printf.sprintf "unknown fusion operation %s" id
  | Start_terminal_operation id -> Printf.sprintf "fusion operation %s is terminal" id
  | Start_not_claimed id -> Printf.sprintf "fusion operation %s is not claimed" id
  | Start_claim_mismatch id -> Printf.sprintf "fusion operation %s claim is stale" id
  | Start_already_started claim_id ->
    Printf.sprintf "fusion claim %s already started" (Claim_id.to_string claim_id)
  | Start_persistence_failed error -> persistence_error_to_string error
;;

let claim_operation t ~operation_id =
  Mutex.protect t.lock (fun () ->
    match get t ~operation_id with
    | None -> Error (Claim_unknown_operation operation_id)
    | Some { status = Completed _; _ } -> Error (Claim_terminal_operation operation_id)
    | Some { status = Running; worker_state = (Claimed id | Started id); _ } ->
      Error (Claim_already_owned id)
    | Some ({ status = Running; worker_state = Registered; _ } | { status = Recovery_required _; _ }) ->
      let claim_id = Claim_id.create () in
      (match
         append_event t (Fusion_run_registry_event.Claim { operation_id; claim_id })
       with
       | Error error -> Error (Claim_persistence_failed error)
       | Ok () ->
         update t (List.map (fun run ->
           if String.equal (run_operation_id run) operation_id
           then { run with worker_state = Claimed claim_id; status = Running }
           else run));
         Ok { operation_id; claim_id }))
;;

let start_claimed t claim =
  Mutex.protect t.lock (fun () ->
    match get t ~operation_id:claim.operation_id with
    | None -> Error (Start_unknown_operation claim.operation_id)
    | Some { status = Completed _; _ } -> Error (Start_terminal_operation claim.operation_id)
    | Some { worker_state = Registered; _ } -> Error (Start_not_claimed claim.operation_id)
    | Some { worker_state = Started current; _ } when Claim_id.equal current claim.claim_id ->
      Error (Start_already_started current)
    | Some { worker_state = (Claimed current | Started current); _ }
      when not (Claim_id.equal current claim.claim_id) ->
      Error (Start_claim_mismatch claim.operation_id)
    | Some run ->
      (match
         append_event t
           (Fusion_run_registry_event.Start
              { operation_id = claim.operation_id; claim_id = claim.claim_id })
       with
       | Error error -> Error (Start_persistence_failed error)
       | Ok () ->
         update t (List.map (fun current ->
           if String.equal (run_operation_id current) claim.operation_id
           then { current with worker_state = Started claim.claim_id; status = Running }
           else current));
         Ok run.operation))
;;

let mark_completed (t : t) ~operation_id ?failure ?failure_code ~ok () =
  Mutex.protect t.lock (fun () -> match get t ~operation_id with
  | None -> Error (Unknown_run operation_id)
  | Some _ ->
    let persisted =
      append_event t
        (Fusion_run_registry_event.Complete { operation_id; ok; failure; failure_code })
    in
    let receipt =
      match persisted with
      | Ok () -> Durable
      | Error error -> Persistence_failed error
    in
    update t (fun runs ->
      runs
      |> List.map (fun r ->
           if String.equal (run_operation_id r) operation_id
           then { r with status = Completed { ok; failure; failure_code; receipt } }
           else r)
      |> prune);
    (match persisted with
     | Ok () -> Ok ()
     | Error error -> Error (Completion_persistence_failed error)))
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
  let request = r.operation.Fusion_types.request in
  let base =
    [ ("run_id", `String request.run_id)
    ; ("keeper", `String request.keeper)
    ; ("preset", `String request.preset)
    ; ("topology", `String (Fusion_types.fusion_topology_to_string r.operation.topology))
    ; ("started_at", `Float r.started_at)
    ; ("status", `String (status_label r.status))
    ]
  in
  let worker_fields =
    match r.worker_state with
    | Registered -> [ "worker_state", `String "registered" ]
    | Claimed claim_id ->
      [ ("worker_state", `String "claimed"); ("claim_id", `String (Claim_id.to_string claim_id)) ]
    | Started claim_id ->
      [ ("worker_state", `String "started"); ("claim_id", `String (Claim_id.to_string claim_id)) ]
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
  `Assoc (base @ worker_fields @ failure_fields @ receipt_fields)
;;

(* Replay helpers — used to hydrate the in-memory table from disk at boot. *)
let apply_event runs = function
  | Fusion_run_registry_event.Register { operation; started_at } ->
    let id = Fusion_types.fusion_operation_id operation in
    let run = { operation; started_at; worker_state = Registered; status = Running } in
    let without_dup =
      List.filter
        (fun run -> not (String.equal (run_operation_id run) id))
        runs
    in
    run :: without_dup
  | Fusion_run_registry_event.Claim { operation_id; claim_id } ->
    List.map (fun run ->
      if String.equal (run_operation_id run) operation_id
      then { run with worker_state = Claimed claim_id }
      else run) runs
  | Fusion_run_registry_event.Start { operation_id; claim_id } ->
    List.map (fun run ->
      if String.equal (run_operation_id run) operation_id
      then { run with worker_state = Started claim_id }
      else run) runs
  | Fusion_run_registry_event.Complete { operation_id = completed_id; ok; failure; failure_code } ->
    List.map
      (fun r ->
         if String.equal (run_operation_id r) completed_id
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
      { operation = run.operation
      ; started_at = run.started_at
      }
  in
  let worker_events =
    match run.worker_state with
    | Registered -> []
    | Claimed claim_id ->
      [ Fusion_run_registry_event.Claim
          { operation_id = run_operation_id run; claim_id }
      ]
    | Started claim_id ->
      [ Fusion_run_registry_event.Claim
          { operation_id = run_operation_id run; claim_id }
      ; Fusion_run_registry_event.Start
          { operation_id = run_operation_id run; claim_id }
      ]
  in
  match run.status with
  | Running | Recovery_required _ -> register :: worker_events
  | Completed { receipt = Persistence_failed _; _ } -> register :: worker_events
  | Completed { ok; failure; failure_code; receipt = Durable } ->
    register :: worker_events
    @ [ Fusion_run_registry_event.Complete
        { operation_id = run_operation_id run; ok; failure; failure_code }
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
    | Ok () -> Fs_compat.invalidate_cached_writer path
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
  { runs = Atomic.make runs; path = Some path; lock = Mutex.create () }
;;

(* Process-wide registry the fusion tool/sink write to (server-lifetime). Tests
   use a fresh [create ()] for state isolation, avoiding a reset backdoor.
   The backing path is set at server boot via [set_global] after replaying the
   persisted JSONL. *)
let global_atomic : t Atomic.t = Atomic.make (create ())

let global () : t = Atomic.get global_atomic

let set_global (t : t) = Atomic.set global_atomic t

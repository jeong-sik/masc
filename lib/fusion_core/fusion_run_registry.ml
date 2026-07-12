(* Fusion — in-memory run registry for in-progress + recent fusion visibility
   (RFC-0266 §7 Phase 2/Phase D). The fusion tool registers a run [Running] at
   fork start and the sink/failure path marks it [Completed] on finish, so an
   operator surface (masc_fusion_status tool = Phase 3, dashboard = Phase 4)
   can show what is deliberating now and what just finished — instead of run_id
   only living in the caller's tool-result.

   Lock-free Atomic + CAS; optional append-only JSONL backing under
   [<base-path>/.masc/fusion-runs.jsonl] so history survives server restart.
   Server-lifetime: a fork that dies on server shutdown takes its registry entry
   with it, so no orphan [Running] survives a restart (RFC-0266 §10 #4).

   This module never wakes a keeper (that is the WAKE half, Phase 1). Recording
   a run is the visibility half and is intentionally side-effect-free beyond
   the in-memory table and the append-only log. *)

type run_status =
  | Running
  | Completed of {
      ok : bool;
      (* ok=false일 때의 사람-가독 사유 + 안정 분류 태그. 2026-07-01 사고에서
         상태 표면(masc_fusion_status/SSE)이 status="failed"만 나르는 바람에
         키퍼가 원인을 얻을 tool-reachable 경로가 없었다 (mli 참조). *)
      failure : string option;
      failure_code : string option;
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

(* Recent-history retention for [Completed] runs. [Running] runs are never
   evicted (active state must stay accurate). NOTE: 이전 주석은 [Running]이
   "per-hour fusion budget (RFC-0252 §10)으로 bounded"라고 주장했으나 그 budget은
   PR #22051에서 제거되어 존재하지 않는다 — 현재 fusion 호출률 제한은 없다(설계
   미결정, 집계만 한다는 운영 원칙과 정합). This is a log-retention bound, not a
   symptom cap — it stops the table from growing without limit over a long
   server lifetime. *)
let max_completed_retained = 64

let create ?path () : t = { runs = Atomic.make []; path }

let is_running (r : run) =
  match r.status with
  | Running -> true
  | Completed _ -> false
;;

(* Keep every [Running] run plus the [max_completed_retained] most recent
   [Completed] runs (newest [started_at] first). *)
let prune (runs : run list) : run list =
  let running, completed = List.partition is_running runs in
  let recent_completed =
    completed
    |> List.sort (fun a b -> Float.compare b.started_at a.started_at)
    |> List.filteri (fun i _ -> i < max_completed_retained)
  in
  running @ recent_completed
;;

let rec update (t : t) (f : run list -> run list) =
  let cur = Atomic.get t.runs in
  let next = f cur in
  if not (Atomic.compare_and_set t.runs cur next) then update t f
;;

let append_event t event =
  match t.path with
  | None -> ()
  | Some path ->
    (try Fs_compat.append_jsonl path (Fusion_run_registry_event.to_yojson event) with
     | exn ->
       Log.Misc.warn
         "fusion_run_registry: append failed for %s: %s"
         path
         (Printexc.to_string exn))
;;

let register_running t ~run_id ~keeper ~preset ~started_at =
  append_event
    t
    (Fusion_run_registry_event.Register { run_id; keeper; preset; started_at });
  update t (fun runs ->
    let run = { run_id; keeper; preset; started_at; status = Running } in
    (* defensive: a re-registered run_id replaces its prior entry *)
    let without_dup = List.filter (fun r -> not (String.equal r.run_id run_id)) runs in
    prune (run :: without_dup))
;;

let mark_completed (t : t) ~run_id ?failure ?failure_code ~ok () =
  append_event t
    (Fusion_run_registry_event.Complete { run_id; ok; failure; failure_code });
  update t (fun runs ->
    runs
    |> List.map (fun r ->
         if String.equal r.run_id run_id
         then { r with status = Completed { ok; failure; failure_code } }
         else r)
    |> prune)
;;

let list_runs (t : t) : run list =
  Atomic.get t.runs |> List.sort (fun a b -> Float.compare b.started_at a.started_at)
;;

let get (t : t) ~run_id : run option =
  List.find_opt (fun r -> String.equal r.run_id run_id) (Atomic.get t.runs)
;;

(* Stable status vocabulary shared by every fusion-run surface (Phase 3 keeper
   tool, Phase 4 dashboard route, the [fusion_run_status] SSE event). Hand-
   written rather than [@@deriving] so the on-wire labels stay
   "running"/"completed"/"failed" regardless of the variant shape — a consumer
   never reconstructs run state from the variant, only reads these labels. *)
let status_label = function
  | Running -> "running"
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
    | Completed { ok = false; failure; failure_code } ->
      List.filter_map
        (fun (k, v) -> Option.map (fun s -> (k, `String s)) v)
        [ ("error", failure); ("failure_code", failure_code) ]
  in
  `Assoc (base @ failure_fields)
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
         then { r with status = Completed { ok; failure; failure_code } }
         else r)
      runs
;;

let drop_replayed_running runs =
  let running, completed = List.partition is_running runs in
  (match running with
   | [] -> ()
   | stale ->
     Log.Misc.warn
       "fusion_run_registry: dropped %d replayed running run(s); worker fibers do not \
        survive server restart"
       (List.length stale));
  completed
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
  | Running -> [ register ]
  | Completed { ok; failure; failure_code } ->
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
    let report = Fs_compat.save_file_atomic_blocking path content in
    Fs_compat.Durable_mutation.fold_report report
      ~not_committed:(fun report ->
        Log.Misc.warn
          "fusion_run_registry: replay compaction not committed for %s: %s"
          path
          (Fs_compat.Durable_mutation.report_to_string report))
      ~committed_not_durable:(fun report ->
        Log.Misc.warn
          "fusion_run_registry: replay compaction committed with sync debt for %s: %s"
          path
          (Fs_compat.Durable_mutation.report_to_string report))
      ~durable:(fun report ->
        match report.diagnostics with
        | [] -> ()
        | _ ->
          Log.Misc.warn
            "fusion_run_registry: replay compaction durable with cleanup diagnostics for %s: %s"
            path
            (Fs_compat.Durable_mutation.report_to_string report))
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
    |> drop_replayed_running
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

(* Completion-authority review registry (RFC-0361 D4).

   [Completion_authority_agent] registers a review [Running] when it claims a
   submitted verification and marks it [Completed] on every exit path, so an
   operator surface can show which reviews are running and how the finished ones
   ended. Before this, a review that deferred or rejected on the evidence
   contract left no durable trace at all: only the paths that committed a
   verdict emitted a [task_completion_verdict] event.

   Lock-free Atomic + CAS; optional append-only JSONL backing under
   [<base-path>/.masc/verification-runs.jsonl] so history survives restart.

   Observation record, not execution abstraction (RFC-0284 §2): nothing here
   drives, retries, or gates a review. Recording never fails a review — append
   errors are logged and swallowed, matching [Fusion_run_registry]. *)

type run_status =
  | Running
  | Completed of
      { outcome : Verification_run_registry_event.outcome
      ; evaluator_runtime : string option
      ; elapsed_s : float
      }

type run =
  { verification_id : string
  ; task_id : string
  ; producer : string
  ; authority_kind : string
  ; authority_actor : string
  ; started_at : float
  ; status : run_status
  }

type t =
  { runs : run list Atomic.t
  ; path : string option
  }

(* Retention bound for [Completed] reviews. [Running] reviews are never evicted
   — active state must stay accurate, and their count is bounded by the number
   of tasks in [AwaitingVerification]. This is a log-retention bound, not a
   symptom cap. *)
let max_completed_retained = 64

let create ?path () : t = { runs = Atomic.make []; path }

let is_running (r : run) =
  match r.status with
  | Running -> true
  | Completed _ -> false
;;

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
    (try Fs_compat.append_jsonl path (Verification_run_registry_event.to_yojson event) with
     | exn ->
       Log.Misc.warn
         "verification_run_registry: append failed for %s: %s"
         path
         (Printexc.to_string exn))
;;

let register_running
      t
      ~verification_id
      ~task_id
      ~producer
      ~authority_kind
      ~authority_actor
      ~started_at
  =
  append_event
    t
    (Verification_run_registry_event.Register
       { verification_id; task_id; producer; authority_kind; authority_actor; started_at });
  update t (fun runs ->
    let run =
      { verification_id
      ; task_id
      ; producer
      ; authority_kind
      ; authority_actor
      ; started_at
      ; status = Running
      }
    in
    (* A deferred review is retried under a fresh authority actor; the newest
       attempt replaces the prior entry so the table names the live one. *)
    let without_dup =
      List.filter (fun r -> not (String.equal r.verification_id verification_id)) runs
    in
    prune (run :: without_dup))
;;

let mark_completed (t : t) ~verification_id ~outcome ?evaluator_runtime ~elapsed_s () =
  append_event
    t
    (Verification_run_registry_event.Complete
       { verification_id; outcome; evaluator_runtime; elapsed_s });
  update t (fun runs ->
    runs
    |> List.map (fun r ->
      if String.equal r.verification_id verification_id
      then { r with status = Completed { outcome; evaluator_runtime; elapsed_s } }
      else r)
    |> prune)
;;

let list_runs (t : t) : run list =
  Atomic.get t.runs |> List.sort (fun a b -> Float.compare b.started_at a.started_at)
;;

let get (t : t) ~verification_id : run option =
  List.find_opt
    (fun r -> String.equal r.verification_id verification_id)
    (Atomic.get t.runs)
;;

(* One status vocabulary for every surface. A completed review reports its
   outcome label directly rather than collapsing to "completed"/"failed": the
   distinction between a rejection, a deferral and a raise is the thing an
   operator opens this surface to see. *)
let status_label = function
  | Running -> "running"
  | Completed { outcome; _ } -> Verification_run_registry_event.outcome_label outcome
;;

(* Outcome detail travels as additive fields so a consumer reading only the
   base set keeps working when a new outcome constructor lands. *)
let outcome_detail_fields (outcome : Verification_run_registry_event.outcome) =
  match outcome with
  | Approved -> []
  | Rejected { reason } -> [ ("reason", `String reason) ]
  | Contract_rejected { detail } | Commit_failed { detail } | Raised { detail } ->
    [ ("detail", `String detail) ]
  | Not_reviewed { gate; detail } ->
    [ ("gate", `String gate); ("detail", `String detail) ]
;;

let run_to_yojson (r : run) : Yojson.Safe.t =
  let base =
    [ ("verification_id", `String r.verification_id)
    ; ("task_id", `String r.task_id)
    ; ("producer", `String r.producer)
    ; ("authority_kind", `String r.authority_kind)
    ; ("authority_actor", `String r.authority_actor)
    ; ("started_at", `Float r.started_at)
    ; ("status", `String (status_label r.status))
    ]
  in
  let completion_fields =
    match r.status with
    | Running -> []
    | Completed { outcome; evaluator_runtime; elapsed_s } ->
      [ ("elapsed_s", `Float elapsed_s) ]
      @ outcome_detail_fields outcome
      @
      (match evaluator_runtime with
       | None -> []
       | Some runtime -> [ ("evaluator_runtime", `String runtime) ])
  in
  `Assoc (base @ completion_fields)
;;

(* Replay helpers — hydrate the in-memory table from disk at boot. *)
let apply_event runs = function
  | Verification_run_registry_event.Register
      { verification_id; task_id; producer; authority_kind; authority_actor; started_at }
    ->
    let run =
      { verification_id
      ; task_id
      ; producer
      ; authority_kind
      ; authority_actor
      ; started_at
      ; status = Running
      }
    in
    let without_dup =
      List.filter (fun r -> not (String.equal r.verification_id verification_id)) runs
    in
    run :: without_dup
  | Verification_run_registry_event.Complete
      { verification_id; outcome; evaluator_runtime; elapsed_s } ->
    List.map
      (fun r ->
         if String.equal r.verification_id verification_id
         then { r with status = Completed { outcome; evaluator_runtime; elapsed_s } }
         else r)
      runs
;;

(* A [Running] entry cannot survive a restart: the review fiber dies with the
   process, and [Completion_authority_agent] rescans every [AwaitingVerification]
   task at boot, so the work is re-registered under a fresh authority actor.
   Keeping the replayed entry would name a review that is not happening. *)
let drop_replayed_running runs =
  let running, completed = List.partition is_running runs in
  (match running with
   | [] -> ()
   | stale ->
     Log.Misc.warn
       "verification_run_registry: dropped %d replayed running review(s); review fibers \
        do not survive server restart"
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
       (match Verification_run_registry_event.of_yojson json with
        | Ok event -> Ok (Some event)
        | Error msg -> Error msg))
    |> Result.map_error (fun msg -> Printf.sprintf "%s:%d: %s" path line_no msg)
;;

let events_of_run (run : run) =
  let register =
    Verification_run_registry_event.Register
      { verification_id = run.verification_id
      ; task_id = run.task_id
      ; producer = run.producer
      ; authority_kind = run.authority_kind
      ; authority_actor = run.authority_actor
      ; started_at = run.started_at
      }
  in
  match run.status with
  | Running -> [ register ]
  | Completed { outcome; evaluator_runtime; elapsed_s } ->
    [ register
    ; Verification_run_registry_event.Complete
        { verification_id = run.verification_id; outcome; evaluator_runtime; elapsed_s }
    ]
;;

let compact_replay_log path runs =
  let events =
    runs
    |> List.sort (fun a b -> Float.compare a.started_at b.started_at)
    |> List.concat_map events_of_run
  in
  let content =
    events |> List.map Verification_run_registry_event.to_jsonl |> String.concat ""
  in
  try
    match Fs_compat.save_file_atomic path content with
    | Ok () -> ()
    | Error msg ->
      Log.Misc.warn
        "verification_run_registry: replay compaction failed for %s: %s"
        path
        msg
  with
  | exn ->
    Log.Misc.warn
      "verification_run_registry: replay compaction raised for %s: %s"
      path
      (Printexc.to_string exn)
;;

let fold_replay_events path =
  if not (Fs_compat.file_exists path)
  then [], [], false
  else (
    try
      let (events, malformed, _line_no), boundary =
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
      (* Compaction rewrites the file, so it must not run when the stream stopped
         short of the end — an unterminated tail would be truncated away. *)
      let should_compact =
        match Fs_compat.file_size path with
        | Some size when boundary < size ->
          Log.Misc.warn
            "verification_run_registry: replay left unterminated tail in %s (%d/%d bytes \
             consumed)"
            path
            boundary
            size;
          false
        | Some _ -> true
        | None ->
          Log.Misc.warn
            "verification_run_registry: replay stat failed after streaming %s"
            path;
          false
      in
      List.rev events, List.rev malformed, should_compact
    with
    | exn ->
      Log.Misc.warn
        "verification_run_registry: replay stream failed for %s: %s"
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
       "verification_run_registry: skipped %d malformed replay line(s); first=%s"
       (List.length errors)
       first);
  let runs = List.fold_left apply_event [] events |> drop_replayed_running |> prune in
  if should_compact then compact_replay_log path runs;
  { runs = Atomic.make runs; path = Some path }
;;

(* Process-wide registry the completion authority writes to (server-lifetime).
   Tests use a fresh [create ()] for state isolation, avoiding a reset backdoor.
   The backing path is set at server boot via [set_global] after replay. *)
let global_atomic : t Atomic.t = Atomic.make (create ())
let global () : t = Atomic.get global_atomic
let set_global (t : t) = Atomic.set global_atomic t

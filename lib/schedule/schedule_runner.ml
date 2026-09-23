(* TEL-OK: this library returns structured [dispatch_result] values and persists
   generic wake records through [Schedule_store]. The server maintenance
   loop owns runtime Log telemetry when it installs a concrete consumer. *)

type signal_kind =
  | Due_candidate

type wake_signal =
  { occurrence_id : Schedule_occurrence_id.t
  ; kind : signal_kind
  ; schedule_instance_id : string
  ; schedule_id : string
  ; emitted_at : float
  ; due_at : float
  ; payload_digest : string
  ; payload : Yojson.Safe.t
  }

type tick_result =
  { due_changed : int
  ; emitted : wake_signal list
  ; rescheduled : int
  ; dispatches : dispatch_result list
  ; held : wake_signal list
  }

and dispatch_status =
  | Dispatch_succeeded
  | Dispatch_failed
  | Dispatch_unsupported
  | Dispatch_start_rejected

and dispatch_result =
  { occurrence_id : Schedule_occurrence_id.t
  ; schedule_id : string
  ; status : dispatch_status
  ; detail : Yojson.Safe.t option
  ; error : string option
  }

type consumer_dispatch_error =
  | Retryable_dispatch_failure of string
  | Terminal_dispatch_rejection of string

type acceptance_commit = Acceptance_committed

type consumer_dispatch_result =
  | Work_accepted of
      { detail : Yojson.Safe.t
      ; acceptance_commit : acceptance_commit
      }

type consumer =
  { accepts : Schedule_domain.schedule_request -> (unit, string) result
  ; dispatch :
      Workspace_utils.config ->
      now:float ->
      wake_signal ->
      Schedule_domain.schedule_request ->
      commit_acceptance:
        (Yojson.Safe.t ->
         (acceptance_commit, consumer_dispatch_error) result) ->
      (consumer_dispatch_result, consumer_dispatch_error) result
  ; defer_wake :
      Workspace_utils.config ->
      occurrence_id:Schedule_occurrence_id.t ->
      Schedule_domain.schedule_request -> bool
      (** Self-clock: [true] leaves this due schedule unfired this tick — no
          signal, no dispatch, no advance — because its target still holds the
          previous, unconsumed occurrence. The current [occurrence_id] is a
          retry, not a new wake, and must remain eligible for reconciliation.
          Emission then tracks consumption
          rather than wall-clock, bounding a slow keeper to one pending
          occurrence per instance. The consumer decides which schedules
          self-clock; a schedule whose every occurrence is distinct work returns
          [false] and fires on every due. *)
  }

type runner_error =
  | Service_error of Schedule_service.service_error
  | Signal_store_error of string

let ( let* ) = Result.bind

let runner_error_to_string = function
  | Service_error err -> Schedule_service.service_error_to_string err
  | Signal_store_error msg -> "signal store error: " ^ msg
;;

let signal_kind_to_string = function
  | Due_candidate -> Schedule_occurrence_id.protocol_tag
;;

let signal_kind_of_string value =
  if String.equal value Schedule_occurrence_id.protocol_tag
  then Ok Due_candidate
  else Error ("unknown schedule signal kind: " ^ value)
;;

let dispatch_status_to_string = function
  | Dispatch_succeeded -> "succeeded"
  | Dispatch_failed -> "failed"
  | Dispatch_unsupported -> "unsupported"
  | Dispatch_start_rejected -> "start_rejected"
;;

let schedules_dir config =
  Filename.concat (Workspace_utils.masc_dir config) "schedules"
;;

let signals_dir config = Filename.concat (schedules_dir config) "signals"

let signal_seen_path config =
  Filename.concat (schedules_dir config) "signal_keys.json"
;;

let signal_store config = Dated_jsonl.create ~base_dir:(signals_dir config) ()

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error ("expected string field: " ^ name)
  | None -> Error ("missing field: " ^ name)
;;

let wake_signal_to_yojson signal =
  `Assoc
    [ "event_type", `String (signal_kind_to_string signal.kind)
    ; "occurrence_id", `String (Schedule_occurrence_id.to_string signal.occurrence_id)
    ; "schedule_instance_id", `String signal.schedule_instance_id
    ; "schedule_id", `String signal.schedule_id
    ; "emitted_at", `Float signal.emitted_at
    ; "due_at", `Float signal.due_at
    ; "payload_digest", `String signal.payload_digest
    ; "payload", signal.payload
    ]
;;

let wake_signal_of_yojson = function
  | `Assoc fields ->
    let* kind_name = string_field "event_type" fields in
    let* kind = signal_kind_of_string kind_name in
    let* occurrence_id = string_field "occurrence_id" fields in
    let* schedule_instance_id = string_field "schedule_instance_id" fields in
    let* schedule_id = string_field "schedule_id" fields in
    let* emitted_at = Schedule_domain.float_field "emitted_at" fields in
    let* due_at = Schedule_domain.float_field "due_at" fields in
    let* payload_digest = string_field "payload_digest" fields in
    let* payload = Schedule_domain.assoc_field "payload" fields in
    let* decoded_payload = Schedule_domain.payload_of_yojson payload in
    let actual_payload_digest = Schedule_domain.payload_digest decoded_payload in
    let* () =
      if String.equal payload_digest actual_payload_digest
      then Ok ()
      else Error "payload_digest does not match schedule occurrence payload"
    in
    let expected_occurrence_id =
      Schedule_occurrence_id.make
        ~schedule_instance_id
        ~schedule_id
        ~due_at
        ~payload_digest
    in
    if String.equal occurrence_id (Schedule_occurrence_id.to_string expected_occurrence_id)
    then
      Ok
        { occurrence_id = expected_occurrence_id
        ; kind
        ; schedule_instance_id
        ; schedule_id
        ; emitted_at
        ; due_at
        ; payload_digest
        ; payload
        }
    else Error "occurrence_id does not match schedule occurrence facts"
  | _ -> Error "expected schedule wake_signal object"
;;

let occurrence_id (request : Schedule_domain.schedule_request) =
  let payload_digest = Schedule_domain.payload_digest request.payload in
  Schedule_occurrence_id.make
    ~schedule_instance_id:request.schedule_instance_id
    ~schedule_id:request.schedule_id
    ~due_at:request.due_at
    ~payload_digest
;;

let make_signal ~now kind (request : Schedule_domain.schedule_request) =
  let payload_digest = Schedule_domain.payload_digest request.payload in
  { occurrence_id = occurrence_id request
  ; kind
  ; schedule_instance_id = request.schedule_instance_id
  ; schedule_id = request.schedule_id
  ; emitted_at = now
  ; due_at = request.due_at
  ; payload_digest
  ; payload = Schedule_domain.payload_to_yojson request.payload
  }
;;

let signal_seen_recovery_path config = signal_seen_path config ^ ".last-good"

let parse_seen_json = function
  | `List rows ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | `String key :: rest -> loop (key :: acc) rest
      | _ :: _ -> Error "signal_keys.json must be a string list"
    in
    loop [] rows
  | _ -> Error "signal_keys.json must be a JSON list"
;;

(* [Seen_absent]: no primary file exists — nothing has ever been observed,
   and the empty list is correct with no data loss. [Seen_unparseable]: the
   primary exists but its bytes (or the read itself) do not yield a key
   list; the caller must not treat this as "nothing seen", because that
   would re-fire every occurrence this store has ever signalled. *)
type seen_primary_failure =
  | Seen_absent
  | Seen_unparseable of string

let load_seen_primary config =
  let path = signal_seen_path config in
  if not (Workspace_utils.path_exists config path)
  then Error Seen_absent
  else (
    match Workspace_utils.read_json_result config path with
    | Error msg -> Error (Seen_unparseable msg)
    | Ok json ->
      (match parse_seen_json json with
       | Ok keys -> Ok keys
       | Error msg -> Error (Seen_unparseable msg)))
;;

let load_seen_recovery config =
  let path = signal_seen_recovery_path config in
  if not (Workspace_utils.path_exists config path)
  then None
  else (
    match Workspace_utils.read_json_result config path with
    | Error _ -> None
    | Ok json ->
      (match parse_seen_json json with
       | Ok keys -> Some keys
       | Error _ -> None))
;;

(* Self-recovering read (#26686 item 1). An absent primary is a fresh store:
   the empty list loses nothing. A primary that exists but will not parse is
   corruption; the previous version of this function returned [Error]
   straight from here, and [append_new_signals] binds that with [let*], so
   every future tick failed the same way with no writer able to replace the
   broken file — the whole scheduler stopped dispatching until an operator
   edited it by hand.
   RFC-0234 already solved this for [schedules.json] with a [.last-good]
   mirror (schedule_store.ml); this store gets the same recovery source. A
   corrupt primary with no usable mirror still reports [Error] rather than
   silently discarding whatever the bytes may hold, and this function does
   not retry — retrying an unchanged file cannot change the outcome. The
   primary heals itself on the next tick that emits a signal, because
   [write_seen] below always writes both files together. *)
let read_seen config =
  match load_seen_primary config with
  | Ok keys -> Ok keys
  | Error Seen_absent -> Ok []
  | Error (Seen_unparseable primary_err) ->
    (match load_seen_recovery config with
     | Some keys -> Ok keys
     | None -> Error primary_err)
;;

(* Commits the primary, then mirrors to [.last-good] so a later corrupt-primary
   read (above) has a recovery source. Returning a result (#26686 item 2) lets
   the caller refuse to report a tick that lost this write as successful,
   instead of the failure only reaching [Log.Misc.warn] the way [write_json]
   reports it — this module's own header keeps it telemetry-free, the caller
   installs the concrete consumer. A mirror write that fails after the
   primary succeeds does not fail the commit: the primary write stands, and
   only the recovery copy is stale until the next write. *)
let write_seen config keys =
  Workspace_utils.mkdir_p (schedules_dir config);
  let json = `List (List.map (fun key -> `String key) keys) in
  let* () = Workspace_utils.write_json_result config (signal_seen_path config) json in
  (* The primary already committed above; a failed mirror write only means
     the next corrupt-primary read has no recovery source. *)
  (* fire-and-forget: a mirror write failure does not fail this commit. *)
  ignore (Workspace_utils.write_json_result config (signal_seen_recovery_path config) json);
  Ok ()
;;

let append_signal config signal =
  try
    Dated_jsonl.append (signal_store config) (wake_signal_to_yojson signal);
    Ok ()
  with
  | Sys_error msg -> Error msg
  | Unix.Unix_error (err, fn, arg) ->
    Error
      (Printf.sprintf
         "%s failed for %s: %s"
         fn
         arg
         (Unix.error_message err))
;;

let append_new_signals config candidates =
  Workspace_utils.mkdir_p (schedules_dir config);
  Workspace_utils.with_file_lock config (signal_seen_path config) (fun () ->
    let* seen = read_seen config in
    let seen_tbl = Hashtbl.create (List.length seen + List.length candidates) in
    List.iter (fun key -> Hashtbl.replace seen_tbl key ()) seen;
    let emitted_rev = ref [] in
    let seen_rev = ref (List.rev seen) in
    (* The key list only grows when a signal is emitted, and it holds every
       occurrence the store has ever signalled (6,242 keys, 430 KB on a live
       root). A tick that emits nothing would rewrite the same list, so it
       writes nothing.
       This same write also closes #26686 item 3: [loop]'s [Error] arm below
       calls it before returning, so a signal whose JSONL row already landed
       (its [append_signal] succeeded) is recorded seen even when a later
       signal in the same tick fails. The previous version only reached this
       write from the clean end of the candidate list, so a mid-list failure
       discarded [seen_rev] entirely and the next tick re-appended every
       signal this one had already committed to the JSONL store. *)
    let persist_progress () =
      match !emitted_rev with
      | [] -> Ok ()
      | _ :: _ -> write_seen config (List.rev !seen_rev)
    in
    let rec loop = function
      | [] ->
        let* () = persist_progress () in
        Ok (List.rev !emitted_rev)
      | (signal : wake_signal) :: rest ->
        let occurrence_id = Schedule_occurrence_id.to_string signal.occurrence_id in
        if Hashtbl.mem seen_tbl occurrence_id then loop rest
        else (
          match append_signal config signal with
          | Error msg ->
            (* Best-effort persistence of the progress made before this
               failure; this module stays telemetry-free (see the header),
               so a secondary failure here has nowhere to go. *)
            (* fire-and-forget: does not change which error is returned. *)
            ignore (persist_progress ());
            Error msg
          | Ok () ->
            Hashtbl.replace seen_tbl occurrence_id ();
            seen_rev := occurrence_id :: !seen_rev;
            emitted_rev := signal :: !emitted_rev;
            loop rest)
    in
    loop candidates)
  |> function
  | Ok emitted -> Ok emitted
  | Error msg -> Error (Signal_store_error msg)
;;

let candidates ~now state =
  Schedule_store.due_wake_candidates state
  |> List.map (fun request -> request, make_signal ~now Due_candidate request)
;;

let dispatch_result ?detail ?error occurrence_id schedule_id status =
  { occurrence_id; schedule_id; status; detail; error }
;;

let finish_terminal_dispatch config ~now ~clock ~occurrence_id ~schedule_id error =
  match
    Schedule_store.fail_running ~finished_at:(clock ()) config ~now ~schedule_id ~error
  with
  | Ok _ -> dispatch_result ~error occurrence_id schedule_id Dispatch_failed
  | Error err ->
    let error =
      Printf.sprintf
        "%s; failed to mark schedule failed: %s"
        error
        (Schedule_store.store_error_to_string err)
    in
    dispatch_result ~error occurrence_id schedule_id Dispatch_failed
;;

let finish_retryable_dispatch config ~now ~clock ~occurrence_id ~schedule_id detail =
  let reason = Schedule_store.Retryable_dispatch_failure detail in
  let error = Schedule_store.running_recovery_reason_to_string reason in
  match
    Schedule_store.retry_running ~finished_at:(clock ()) config ~now ~schedule_id ~reason
  with
  | Ok _ -> dispatch_result ~error occurrence_id schedule_id Dispatch_failed
  | Error err ->
    let error =
      Printf.sprintf
        "%s; failed to return schedule to due: %s"
        error
        (Schedule_store.store_error_to_string err)
    in
    dispatch_result ~error occurrence_id schedule_id Dispatch_failed
;;

let safe_consumer_dispatch config ~now ~clock consumer signal request =
  Cancel_safe.protect
    ~on_exn:(fun exn ->
      Error
        (Retryable_dispatch_failure
           ("consumer dispatch raised: " ^ Printexc.to_string exn)))
    (fun () ->
       consumer.dispatch
         config
         ~now
         signal
         request
         ~commit_acceptance:(fun detail ->
           match
             Schedule_store.accept_running
               ~finished_at:(clock ())
               config
               ~now
               ~schedule_id:request.Schedule_domain.schedule_id
               ~detail
               ()
           with
           | Ok _ -> Ok Acceptance_committed
           | Error error ->
             Error
               (Retryable_dispatch_failure
                  ("schedule acceptance commit failed: "
                   ^ Schedule_store.store_error_to_string error))))
;;

let dispatch_candidate
      config
      ~now
      ~clock
      consumer
      (signal : wake_signal)
      (request : Schedule_domain.schedule_request)
  =
  let schedule_id = request.Schedule_domain.schedule_id in
  let occurrence_id = signal.occurrence_id in
  match consumer.accepts request with
  | Error reason ->
    (match
       Schedule_store.fail_due_candidate
         ~attempted_at:(clock ())
         config
         ~now
         ~schedule_id
         ~error:reason
     with
     | Ok _ ->
       dispatch_result ~error:reason occurrence_id schedule_id Dispatch_unsupported
     | Error err ->
       let error =
         Printf.sprintf
           "%s; failed to mark schedule failed: %s"
           reason
           (Schedule_store.store_error_to_string err)
       in
       dispatch_result ~error occurrence_id schedule_id Dispatch_unsupported)
  | Ok () ->
    (match
       Schedule_store.start_due_candidate
         ~started_at:(clock ())
         config
         ~now
         ~schedule_id
     with
     | Error err ->
       dispatch_result ~error:(Schedule_store.store_error_to_string err) occurrence_id
         schedule_id Dispatch_start_rejected
     | Ok running_request ->
       (match
          safe_consumer_dispatch config ~now ~clock consumer signal running_request
        with
        | Error (Retryable_dispatch_failure detail) ->
          finish_retryable_dispatch config ~now ~clock ~occurrence_id ~schedule_id detail
        | Error (Terminal_dispatch_rejection detail) ->
          finish_terminal_dispatch config ~now ~clock ~occurrence_id ~schedule_id detail
        | Ok (Work_accepted { detail; acceptance_commit = Acceptance_committed }) ->
          dispatch_result ~detail occurrence_id schedule_id Dispatch_succeeded))
;;

let dispatch_candidates config ~now ~clock consumer candidates =
  List.map
    (fun (request, signal) ->
       dispatch_candidate config ~now ~clock consumer signal request)
    candidates
;;

let tick ?consumer ?clock config ~now ~retention_days =
  (* Without a clock every wake stamp copies [now], which is the tick start:
     the store then records a dispatch that took fourteen seconds as one
     that took none. The production caller passes its wall clock; tests that
     reason about a fixed [now] pass nothing and keep their determinism. *)
  let clock =
    match clock with
    | Some clock -> clock
    | None -> fun () -> now
  in
  match Schedule_store.refresh_due config ~now ~retention_days with
  | Error err -> Error (Service_error (Schedule_service.Store_error err))
  | Ok (state, due_changed) ->
    let all_candidates = candidates ~now state in
    (* Self-clock (#36213): a consumer may hold a due schedule back when its
       target still carries the previous unconsumed occurrence. Held candidates
       emit no signal and are not dispatched or advanced — they stay due and are
       reconsidered next tick, so emission tracks consumption instead of the
       wall clock. Without a consumer the runner is keeper-agnostic and holds
       nothing. *)
    let deferred, active =
      match consumer with
      | Some consumer ->
        List.partition
          (fun (request, (signal : wake_signal)) ->
             consumer.defer_wake config ~occurrence_id:signal.occurrence_id request)
          all_candidates
      | None -> [], all_candidates
    in
    let candidate_signals = List.map snd active in
    let* emitted = append_new_signals config candidate_signals in
    let held = List.map snd deferred in
    (match consumer with
     | Some consumer ->
       let dispatches = dispatch_candidates config ~now ~clock consumer active in
       Ok { due_changed; emitted; rescheduled = 0; dispatches; held }
     | None ->
       let schedule_ids =
         List.map (fun (signal : wake_signal) -> signal.schedule_id) candidate_signals
       in
       (match Schedule_store.reschedule_due_recurring config ~now ~schedule_ids with
        | Error err -> Error (Service_error (Schedule_service.Store_error err))
        | Ok (_, rescheduled) ->
          Ok { due_changed; emitted; rescheduled; dispatches = []; held }))
;;

let newly_held ~previous held =
  let was_held (signal : wake_signal) =
    List.exists
      (fun (earlier : wake_signal) ->
         String.equal
           (Schedule_occurrence_id.to_string earlier.occurrence_id)
           (Schedule_occurrence_id.to_string signal.occurrence_id))
      previous
  in
  List.filter (fun signal -> not (was_held signal)) held
;;

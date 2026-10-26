open Alcotest

module Queue = Keeper_event_queue
module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence
module Ledger = Masc.Keeper_reaction_ledger

let require_ok label = function
  | Ok value -> value
  | Error detail -> failf "%s: %s" label detail
;;

let require_some label = function
  | Some value -> value
  | None -> failf "%s: expected a value" label
;;

let stimulus post_id arrived_at : Queue.stimulus =
  { post_id; urgency = Queue.Normal; arrived_at; payload = Queue.Bootstrap }
;;

let post_ids pending =
  Queue.to_list pending
  |> List.map (fun (source : Queue.stimulus) -> source.post_id)
;;

let with_temp_dir f =
  let base_path = Filename.temp_file "keeper-queue-cancellation" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () -> f base_path)
;;

let read_state ~base_path ~keeper_name =
  Persistence.load_state_result ~base_path ~keeper_name |> require_ok "read durable state"
;;

let fresh_process ~base_path ~keeper_name ?projection () =
  let executable = Unix.realpath Sys.executable_name in
  let arguments =
    match projection with
    | None -> [ executable; "--read-state"; base_path; keeper_name ]
    | Some (transition_id, post_id) ->
      [ executable; "--project-state"; base_path; keeper_name; transition_id; post_id ]
  in
  let output = Filename.temp_file "keeper-queue-fresh-process" ".json" in
  Fun.protect ~finally:(fun () -> Sys.remove output) (fun () ->
    let fd = Unix.openfile output [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
    let pid =
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
        Unix.create_process executable (Array.of_list arguments) Unix.stdin fd Unix.stderr)
    in
    (match snd (Unix.waitpid [] pid) with
     | Unix.WEXITED 0 -> ()
     | Unix.WEXITED code -> failf "fresh reader exited %d" code
     | Unix.WSIGNALED signal -> failf "fresh reader received signal %d" signal
     | Unix.WSTOPPED signal -> failf "fresh reader stopped with signal %d" signal);
    let json = Yojson.Safe.from_file output in
    let open Yojson.Safe.Util in
    check int "witness came from the spawned process" pid (json |> member "pid" |> to_int);
    check bool "reader is a fresh process" true (pid <> Unix.getpid ());
    json)
;;

let restored_state json =
  let open Yojson.Safe.Util in
  State.of_yojson (json |> member "state") |> require_ok "decode fresh-process state"
;;

let seed ~base_path ~keeper_name =
  Persistence.update_result ~base_path ~keeper_name (fun pending ->
    Queue.enqueue (Queue.enqueue pending (stimulus "selected" 1.0)) (stimulus "sibling" 2.0))
  |> require_ok "seed two durable sources";
  let selected =
    Persistence.select_when_result ~base_path ~keeper_name ~now:3.0 ~ready:(fun _ -> true)
    |> require_ok "durable peek" |> require_some "selected source"
  in
  selected, read_state ~base_path ~keeper_name
;;

let await ~clock ~label promise =
  match Eio.Time.with_timeout clock 30.0 (fun () -> Ok (Eio.Promise.await promise)) with
  | Ok value -> value
  | Error `Timeout -> failf "%s did not reach its fixture boundary" label
;;

let run_eio f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env ~sw ~clock ~net:(Eio.Stdenv.net env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
  @@ fun () -> f ~sw ~clock
;;

let cancelled_commit operation =
  run_eio @@ fun ~sw ~clock ->
  let context_ready, resolve_context_ready = Eio.Promise.create () in
  let boundary, resolve_boundary = Eio.Promise.create () in
  let release, resolve_release = Eio.Promise.create () in
  let finished, resolve_finished = Eio.Promise.create () in
  let returned = ref None in
  let published = ref None in
  let reason = Failure "cancel during the durable queue transaction" in
  Eio.Fiber.fork ~sw (fun () ->
    (try
       Eio.Cancel.sub (fun context ->
         Eio.Promise.resolve resolve_context_ready context;
         let result =
           operation
             ~before_write:(fun () ->
               Eio.Promise.resolve resolve_boundary ();
               Eio.Promise.await release)
             ~after_commit:(fun pending -> published := Some (post_ids pending))
         in
         check bool "projection published before the committed result returns" true
           (Option.is_some !published);
         returned := Some result;
         Eio.Fiber.check ();
         fail "pending cancellation did not surface at the caller's next cancellation point")
     with
     | Eio.Cancel.Cancelled observed ->
       check bool "the original cancellation reason survives commit" true (observed == reason);
       check bool "commit returned before cancellation surfaced" true (Option.is_some !returned));
    Eio.Promise.resolve resolve_finished ());
  Fun.protect
    ~finally:(fun () -> ignore (Eio.Promise.try_resolve resolve_release ()))
    (fun () ->
       let context = await ~clock ~label:"transaction context" context_ready in
       await ~clock ~label:"encoded write" boundary;
       Eio.Cancel.cancel context reason;
       check bool "held publication has not returned a result" true (Option.is_none !returned);
       check bool "held publication has not projected pending" true (Option.is_none !published);
       Eio.Promise.resolve resolve_release ();
       await ~clock ~label:"cancelled transaction completion" finished);
  require_some "committed operation result" !returned,
  require_some "committed pending projection" !published
;;

let test_snapshot_ack_defers_cancellation_and_survives_fresh_read () =
  with_temp_dir @@ fun base_path ->
  let keeper_name = "snapshot-owner" in
  let selected, before = seed ~base_path ~keeper_name in
  let result, published =
    cancelled_commit (fun ~before_write ~after_commit ->
      Persistence.For_testing.ack_pending_with_before_write
        ~before_write ~after_commit ~base_path ~keeper_name ~selection:selected ())
  in
  require_ok "committed ACK" result;
  check (list string) "pending publication retains the unrelated source" [ "sibling" ] published;
  let restored = fresh_process ~base_path ~keeper_name () |> restored_state in
  check (list string) "fresh reader sees only the unacknowledged source"
    [ "sibling" ] (post_ids (State.pending restored));
  check int64 "ACK committed exactly one revision"
    (Int64.succ (State.revision before)) (State.revision restored);
  check int "raw ACK invents no transition outbox" 0 (List.length (State.transition_outbox restored))
;;

let test_terminal_ack_preserves_wal_outbox_and_projects_once_after_restart () =
  with_temp_dir @@ fun base_path ->
  let keeper_name = "wal-owner" in
  let selected, _before = seed ~base_path ~keeper_name in
  Ledger.record_event_queue_stimulus ~base_path ~keeper_name selected.source;
  let source_terminal : Persistence.accepted_source_terminal =
    { source = selected.source
    ; source_incarnation = selected.admitted_revision
    ; operator_operation_id = "completed-operation"
    ; source_receipt = State.Turn_completed
    }
  in
  let result, published =
    cancelled_commit (fun ~before_write ~after_commit ->
      Persistence.For_testing.ack_source_terminal_with_before_write
        ~before_write ~after_commit ~base_path ~keeper_name ~acked_at:4.0 ~source_terminal ())
  in
  let receipt =
    match require_ok "committed source-terminal ACK" result with
    | Persistence.Transition_applied receipt -> receipt
    | Persistence.Transition_already_applied _ -> fail "new ACK was reported as a replay"
    | Persistence.Transition_committed_followup_failed { detail; _ } -> fail detail
  in
  check (list string) "WAL commit publishes only the sibling" [ "sibling" ] published;
  let before_projection = fresh_process ~base_path ~keeper_name () |> restored_state in
  check (list string) "fresh WAL replay retains sibling and does not requeue completed work"
    [ "sibling" ] (post_ids (State.pending before_projection));
  (match State.transition_outbox before_projection with
   | [ entry ] ->
     check string "fresh reader retains the exact transition identity"
       receipt.transition_id entry.receipt.transition_id;
     check bool "fresh reader retains the full exact source transition" true
       (entry.receipt.transition = State.Ack_source_terminal source_terminal)
   | _ -> fail "fresh reader lost or duplicated the unprojected terminal outbox");
  let projection = receipt.transition_id, selected.source.post_id in
  let projected = fresh_process ~base_path ~keeper_name ~projection () in
  let state = restored_state projected in
  check (list string) "real projector preserves unrelated pending work"
    [ "sibling" ] (post_ids (State.pending state));
  check int "real projector retires the exact outbox" 0 (List.length (State.transition_outbox state));
  let open Yojson.Safe.Util in
  check bool "real reaction ledger contains the terminal ACK" true
    (projected |> member "ack_seen" |> to_bool);
  let replayed = fresh_process ~base_path ~keeper_name ~projection () in
  check int "fresh-process projection retry appends no duplicate reaction"
    (projected |> member "matched_rows" |> to_int)
    (replayed |> member "matched_rows" |> to_int);
  check (list string) "projection retry cannot requeue completed work"
    [ "sibling" ] (post_ids (State.pending (restored_state replayed)))
;;

let test_cancellation_while_waiting_for_owner_lock_writes_nothing () =
  with_temp_dir @@ fun base_path ->
  let keeper_name = "waiting-owner" in
  let selected, before = seed ~base_path ~keeper_name in
  (* The holder's after-read boundary must perform an actual decode. This cache
     reset is only setup for that barrier; fresh-process reads below prove reload. *)
  Persistence.For_testing.reset_snapshot_cache_for_testing ();
  run_eio (fun ~sw ~clock ->
    let held, resolve_held = Eio.Promise.create () in
    let release, resolve_release = Eio.Promise.create () in
    let holder_done, resolve_holder_done = Eio.Promise.create () in
    let context_ready, resolve_context_ready = Eio.Promise.create () in
    let cancelled, resolve_cancelled = Eio.Promise.create () in
    let write_started = ref false in
    let reason = Failure "cancel the lock waiter" in
    Eio.Fiber.fork ~sw (fun () ->
      Persistence.For_testing.load_state_with_read_interleave
        ~after_read:(fun () ->
          Eio.Promise.resolve resolve_held ();
          Eio.Promise.await release)
        ~base_path ~keeper_name
      |> require_ok "owner lock holder read" |> ignore;
      Eio.Promise.resolve resolve_holder_done ());
    Fun.protect
      ~finally:(fun () -> ignore (Eio.Promise.try_resolve resolve_release ()))
      (fun () ->
        await ~clock ~label:"durable owner lock holder" held;
        Eio.Fiber.fork ~sw (fun () ->
          (try
             Eio.Cancel.sub (fun context ->
               Eio.Promise.resolve resolve_context_ready context;
               Persistence.For_testing.ack_pending_with_before_write
                 ~before_write:(fun () -> write_started := true)
                 ~base_path ~keeper_name ~selection:selected ()
               |> require_ok "waiting ACK";
               fail "cancelled lock waiter acquired the transaction")
           with
           | Eio.Cancel.Cancelled observed ->
             check bool "lock waiter preserves its cancellation reason" true (observed == reason));
          Eio.Promise.resolve resolve_cancelled ());
        let context = await ~clock ~label:"lock waiter context" context_ready in
        Eio.Cancel.cancel context reason;
        await ~clock ~label:"cancelled lock waiter" cancelled;
        check bool "cancelled waiter never reached the writer" false !write_started;
        Eio.Promise.resolve resolve_release ();
        await ~clock ~label:"released lock holder" holder_done));
  let restored = fresh_process ~base_path ~keeper_name () |> restored_state in
  check (list string) "cancelled acquisition leaves both sources pending"
    [ "selected"; "sibling" ] (post_ids (State.pending restored));
  check int64 "cancelled acquisition does not change the revision"
    (State.revision before) (State.revision restored)
;;

let child_read ~base_path ~keeper_name ?projection () =
  let before = read_state ~base_path ~keeper_name in
  let extra =
    match projection with
    | None -> []
    | Some (transition_id, post_id) ->
      Ledger.project_event_queue_transition_outbox_result
        ~base_path ~keeper_name ~expected_transition_id:transition_id
      |> require_ok "fresh-process production projector";
      let stimulus_id = Ledger.stimulus_id_of_event_queue (stimulus post_id 1.0) in
      let evidence =
        match Ledger.event_queue_reaction_evidence_result ~base_path ~keeper_name ~stimulus_id with
        | Ok (Ledger.Evidence_complete evidence) -> evidence
        | Ok (Ledger.Evidence_quarantined _) -> fail "projected reaction evidence is quarantined"
        | Error error -> fail (Ledger.event_queue_reaction_evidence_error_to_string error)
      in
      [ "ack_seen", `Bool evidence.event_queue_ack_seen
      ; "matched_rows", `Int evidence.matched_record_count
      ]
  in
  let state = read_state ~base_path ~keeper_name in
  `Assoc ([ "pid", `Int (Unix.getpid ()); "before", State.to_yojson before
          ; "state", State.to_yojson state ] @ extra)
  |> Yojson.Safe.to_string |> print_endline
;;

let () =
  match Array.to_list Sys.argv with
  | [ _; "--read-state"; base_path; keeper_name ] -> child_read ~base_path ~keeper_name ()
  | [ _; "--project-state"; base_path; keeper_name; transition_id; post_id ] ->
    child_read ~base_path ~keeper_name ~projection:(transition_id, post_id) ()
  | _ ->
    run "keeper-event-queue-cancellation"
      [ "durable transactions",
        [ test_case "snapshot ACK defers cancellation and survives fresh read" `Quick
            test_snapshot_ack_defers_cancellation_and_survives_fresh_read
        ; test_case "terminal ACK survives cancellation and projects once after restart" `Quick
            test_terminal_ack_preserves_wal_outbox_and_projects_once_after_restart
        ; test_case "cancelled owner-lock waiter writes nothing" `Quick
            test_cancellation_while_waiting_for_owner_lock_writes_nothing
        ] ]

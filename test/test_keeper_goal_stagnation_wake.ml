(** RFC-0310 §3.3 — Goal_stagnation detection and fire-once dedup.

    Two layers:
    - [stagnation_of_goal], the pure predicate that decides whether a goal
      earns a one-shot stagnation wake (phase gate, threshold, fail-closed
      parse). Pinned without a base-path fixture.
    - [enqueue_goal_stagnation_wakes], the producer whose fire-once-per-episode
      invariant depends on the reaction-ledger [turn_started_seen] gate.
      [test_episode_fires_once_across_rescans] drives it against a real
      base-path fixture to prove it re-fires while the episode is unattended
      and goes silent once the [Turn_started] reaction is on the ledger. *)

open Alcotest

module SW = Masc.Keeper_goal_stagnation_wake

(* A fixed clock so staleness is deterministic. Derived through the same
   parser the producer uses, so the test never depends on hand-computed epoch
   arithmetic. *)
let now =
  match Masc_domain.parse_iso8601_opt "2026-07-08T02:00:00Z" with
  | Some ts -> ts
  | None -> Alcotest.fail "fixture clock failed to parse"

let goal ~phase ~updated_at : Goal_store.goal =
  { Goal_store.id = "goal-1"
  ; title = "Advance the wake redesign"
  ; metric = None
  ; target_value = None
  ; due_date = None
  ; priority = 3
  ; status = Goal_store.Active
  ; phase
  ; verifier_policy = None
  ; require_completion_approval = false
  ; active_verification_request_id = None
  ; parent_goal_id = None
  ; last_review_note = None
  ; last_review_at = None
  ; created_at = "2026-07-01T00:00:00Z"
  ; updated_at
  }

let threshold_sec = 3600.0

(* 3 hours before [now]: comfortably past the 1h threshold. *)
let stale_ts = "2026-07-07T23:00:00Z"

(* 5 minutes before [now]: well inside the threshold. *)
let fresh_ts = "2026-07-08T01:55:00Z"

let is_some = function Some _ -> true | None -> false

let temp_dir () =
  let dir = Filename.temp_file "test_goal_stagnation_refire_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
  in
  try rm dir with
  | _ -> ()

let keeper_name = "goal-stagnation-keeper"

let test_stale_executing_goal_wakes () =
  let result =
    SW.stagnation_of_goal ~now ~threshold_sec
      (goal ~phase:Goal_phase.Executing ~updated_at:stale_ts)
  in
  (match result with
   | Some gs ->
     check string "stale_since carries the goal's updated_at" stale_ts
       gs.Keeper_event_queue.gs_stale_since;
     check string "goal id preserved" "goal-1" gs.gs_goal_id
   | None ->
     Alcotest.fail "a stale Executing goal must produce a stagnation episode")

let test_fresh_executing_goal_silent () =
  check bool "a freshly-touched Executing goal does not wake" false
    (is_some
       (SW.stagnation_of_goal ~now ~threshold_sec
          (goal ~phase:Goal_phase.Executing ~updated_at:fresh_ts)))

(* The phase gate: only Executing admits a self-directed stagnation wake.
   Terminal, operator-gated, and awaiting-verdict goals stay silent even when
   long stale, because waking the keeper cannot advance them. *)
let test_non_executing_phases_never_wake () =
  List.iter
    (fun phase ->
      check bool
        (Printf.sprintf "phase %s never wakes on staleness"
           (Goal_phase.to_string phase))
        false
        (is_some
           (SW.stagnation_of_goal ~now ~threshold_sec
              (goal ~phase ~updated_at:stale_ts))))
    [ Goal_phase.Awaiting_verification
    ; Goal_phase.Awaiting_approval
    ; Goal_phase.Blocked
    ; Goal_phase.Paused
    ; Goal_phase.Completed
    ; Goal_phase.Dropped
    ]

(* Fail closed: an unparseable updated_at is undecidable, so it does not wake
   (rather than treating the goal as infinitely stale). *)
let test_unparseable_timestamp_silent () =
  check bool "unparseable updated_at does not wake" false
    (is_some
       (SW.stagnation_of_goal ~now ~threshold_sec
          (goal ~phase:Goal_phase.Executing ~updated_at:"not-a-timestamp")))

(* Exhaustive witness: admits_self_directed_progress is true only for
   Executing across every declared phase. *)
let test_phase_predicate_exhaustive () =
  List.iter
    (fun phase ->
      let expected = phase = Goal_phase.Executing in
      check bool
        (Printf.sprintf "admits_self_directed_progress %s"
           (Goal_phase.to_string phase))
        expected
        (Goal_phase.admits_self_directed_progress phase))
    Goal_phase.all

(* Fire-once-per-episode (RFC-0310 §3.3) — the invariant the edge redesign
   exists to hold, and the one the pure-predicate cases above cannot reach. The
   re-fire loop lives in [enqueue_goal_stagnation_wakes], whose only durable
   fire-once gate is the reaction ledger's [turn_started_seen]. That flag is
   armed by the [Turn_started] reaction the stagnation turn records when it
   consumes the stimulus (keeper_heartbeat_stimulus_intake, Goal_stagnation
   arm — mirroring No_progress_recovery). Without that reaction the queue-level
   identity dedup collapses duplicate queue *entries* but does not stop the
   *wake*: the producer keeps returning the goal id and re-waking every scan —
   the blind cadence RFC-0303 forbids. This test drives the producer across
   scans against a real base-path fixture and asserts it re-fires while no
   reaction exists, then goes silent once the episode reaction is recorded. *)
let test_episode_fires_once_across_rescans () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
      let persisted =
        match
          Goal_store.upsert_goal config ~title:"Advance the wake redesign"
            ~phase:Goal_phase.Executing ()
        with
        | Ok (goal_rec, _) -> goal_rec
        | Error err -> Alcotest.failf "goal upsert failed: %s" err
      in
      let goal_id = persisted.Goal_store.id in
      (* [upsert_goal] stamps [updated_at] at persist time; pick a [now] past
         the threshold so the goal reads as stale without a hand-computed
         epoch. *)
      let updated_ts =
        match Masc_domain.parse_iso8601_opt persisted.Goal_store.updated_at with
        | Some ts -> ts
        | None ->
          Alcotest.failf "persisted updated_at did not parse: %s"
            persisted.Goal_store.updated_at
      in
      let now = updated_ts +. threshold_sec +. 1.0 in
      let scan () =
        SW.enqueue_goal_stagnation_wakes ~config ~keeper_name
          ~active_goal_ids:[ goal_id ] ~now ~threshold_sec ()
      in
      check (list string) "first scan fires the stale episode" [ goal_id ]
        (scan ());
      (* No turn has recorded a Turn_started reaction yet, so the producer must
         re-fire. This is the defect the intake fix closes: queue dedup alone
         does not stop the wake. *)
      check (list string)
        "re-fires while the episode has no turn_started reaction" [ goal_id ]
        (scan ());
      (* Record the reaction exactly as the fixed intake arm does: same episode
         [gs], [arrived_at] pinned to the episode timestamp so the stimulus id
         matches what the producer recomputes on the next scan. *)
      let gs =
        match SW.stagnation_of_goal ~now ~threshold_sec persisted with
        | Some gs -> gs
        | None ->
          Alcotest.fail "the persisted goal must be stale for this fixture"
      in
      let stimulus : Keeper_event_queue.stimulus =
        { post_id = Keeper_event_queue.goal_stagnation_post_id gs
        ; urgency = Keeper_event_queue.Normal
        ; arrived_at = updated_ts
        ; payload = Keeper_event_queue.Goal_stagnation gs
        }
      in
      Masc.Keeper_reaction_ledger.record_event_queue_reaction ~base_path
        ~keeper_name ~reaction_kind:Masc.Keeper_reaction_ledger.Turn_started
        stimulus;
      let evidence =
        Masc.Keeper_reaction_ledger.event_queue_reaction_evidence ~base_path
          ~keeper_name
          ~stimulus_id:
            (Masc.Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus)
      in
      check bool "turn_started_seen arms after the episode reaction" true
        evidence.Masc.Keeper_reaction_ledger.turn_started_seen;
      check (list string) "silent after the episode has been attended" []
        (scan ()))

let () =
  run
    "keeper goal stagnation wake"
    [ ( "stagnation_of_goal"
      , [ test_case "stale Executing goal wakes" `Quick
            test_stale_executing_goal_wakes
        ; test_case "fresh Executing goal stays silent" `Quick
            test_fresh_executing_goal_silent
        ; test_case "non-Executing phases never wake" `Quick
            test_non_executing_phases_never_wake
        ; test_case "unparseable timestamp stays silent" `Quick
            test_unparseable_timestamp_silent
        ; test_case "phase predicate exhaustive" `Quick
            test_phase_predicate_exhaustive
        ] )
    ; ( "enqueue_goal_stagnation_wakes"
      , [ test_case "episode fires once across re-scans" `Quick
            test_episode_fires_once_across_rescans
        ] )
    ]

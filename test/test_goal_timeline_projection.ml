(** Goal timeline projection — the normalizer and the tree field that carries it.

    [goal_events.jsonl] stores {ts, goal_id, event_type, payload}. Every
    consumer reads {ts, kind, lane, title, summary, severity}.
    [Dashboard_goals_types.goal_event_timeline_json] is the only translation
    between the two, and until #29299 the goal tree skipped it: the raw rows
    went out under [timeline_events] and the dashboard's strict decoder
    dropped all of them, so every goal read as having no history.

    These tests pin both halves — the normalizer's own output, and the fact
    that the tree field is normalized — without booting Eio or touching disk. *)

open Alcotest

module DG = Dashboard_goals
module DGT = Dashboard_goals_types

let field name json =
  match Yojson.Safe.Util.member name json with
  | `String s -> Some s
  | `Null -> None
  | other -> Some ("<non-string:" ^ Yojson.Safe.to_string other ^ ">")
;;

let goal_phase_event ?(ts = "2026-08-21T03:20:29Z") payload =
  `Assoc
    [ "ts", `String ts
    ; "goal_id", `String "goal-1"
    ; "event_type", `String "goal_phase"
    ; "payload", payload
    ]
;;

(* The exact payload shape every producer writes: [gate_event_payload] and the
   two inline payloads in workspace_goals.ml all put [actor] as a bare string. *)
let live_phase_payload ~phase ~actor =
  `Assoc [ "phase", `String phase; "actor", `String actor ]
;;

let test_normalizes_a_phase_event () =
  let json =
    DGT.goal_event_timeline_json
      (goal_phase_event (live_phase_payload ~phase:"completed" ~actor:"alpha"))
  in
  check (option string) "kind is the event type" (Some "goal_phase") (field "kind" json);
  check (option string) "lane" (Some "goal") (field "lane" json);
  check (option string) "title" (Some "Goal Phase") (field "title" json);
  check (option string) "ts survives" (Some "2026-08-21T03:20:29Z") (field "ts" json)
;;

(* Reading [payload.actor] as [actor.id] returned `Null for every event ever
   written, so the summary silently lost who moved the goal. *)
let test_summary_names_the_actor () =
  let json =
    DGT.goal_event_timeline_json
      (goal_phase_event (live_phase_payload ~phase:"blocked" ~actor:"alpha"))
  in
  check
    (option string)
    "summary carries phase and actor"
    (Some "phase=blocked by alpha")
    (field "summary" json)
;;

let test_severity_follows_the_phase () =
  let severity_of phase =
    field
      "severity"
      (DGT.goal_event_timeline_json
         (goal_phase_event (live_phase_payload ~phase ~actor:"alpha")))
  in
  check (option string) "executing" (Some "ok") (severity_of "executing");
  check (option string) "verifying" (Some "ok") (severity_of "verifying");
  check (option string) "completed" (Some "ok") (severity_of "completed");
  check (option string) "dropped" (Some "ok") (severity_of "dropped")
;;

(* A phase this build cannot parse is not healthy. The old string match sent
   every unrecognised token to "ok", so a corrupted producer event rendered
   neutral — indistinguishable from a running goal for anyone scanning the
   timeline by colour. The markers are loud in the summary text; this keeps
   them loud in the severity too. *)
let test_unparseable_phase_is_not_ok () =
  let severity_of phase =
    field
      "severity"
      (DGT.goal_event_timeline_json
         (goal_phase_event (live_phase_payload ~phase ~actor:"alpha")))
  in
  check (option string) "token no producer writes" (Some "warn") (severity_of "retired");
  check (option string) "empty token" (Some "warn") (severity_of "");
  check
    (option string)
    "missing phase falls to the marker, which is also unparseable"
    (Some "warn")
    (field "severity" (DGT.goal_event_timeline_json (goal_phase_event (`Assoc []))))
;;

(* A producer that stops writing a field must show up, not disappear: the
   bracketed markers are emitted by no producer, so a non-zero appearance is an
   unambiguous producer-side fix signal. *)
let test_missing_payload_fields_are_marked () =
  let json = DGT.goal_event_timeline_json (goal_phase_event (`Assoc [])) in
  check
    (option string)
    "both markers"
    (Some "phase=<missing payload.phase> by <missing payload.actor>")
    (field "summary" json)
;;

let test_unknown_event_type_keeps_its_token () =
  let json =
    DGT.goal_event_timeline_json
      (`Assoc
         [ "ts", `String "2026-08-05T23:03:13Z"
         ; "goal_id", `String "goal-1"
           (* Any token the projection does not know. It must not be one the
              codebase used to have -- a reader who greps for it and finds
              only this file cannot tell a fixture from a live concept. *)
         ; "event_type", `String "goal_sprouted"
         ; "payload", `Assoc [ "colour", `String "alpha" ]
         ])
  in
  check (option string) "kind" (Some "goal_sprouted") (field "kind" json);
  check (option string) "title" (Some "Goal Event") (field "title" json);
  check (option string) "summary is the token" (Some "goal_sprouted") (field "summary" json)
;;

(* {1 The tree field} *)

let goal : Goal_store.goal =
  { id = "goal-1"
  ; title = "Goal One"
  ; metric = None
  ; target_value = None
  ; due_date = None
  ; priority = 3
  ; phase = Goal_phase.Executing
  ; last_review_note = None
  ; last_review_at = None
  ; created_at = "2026-08-01T00:00:00Z"
  ; updated_at = "2026-08-21T00:00:00Z"
  }
;;

let node : DG.tree_node =
  { goal
  ; children = []
  ; tasks = []
  ; last_activity_at = "2026-08-21T00:00:00Z"
  ; stagnation_seconds = Some 0
  ; linked_keeper_names = []
  ; pending_approval_count = 0
  ; latest_keeper_ref = None
  ; latest_turn_ref = None
  ; activity_observation = "goal_metadata"
  }
;;

let test_task_snapshot_names_actor_and_handoff () =
  let handoff : Masc_domain.task_handoff_context =
    { summary = "continue from the saved checkpoint"
    ; reason = None
    ; next_step = None
    ; failure_mode = None
    ; reclaim_policy = None
    ; evidence_refs = []
    ; updated_at = Some "2026-08-21T03:00:00Z"
    ; updated_by = Some "alpha"
    }
  in
  let task : Masc_domain.task =
    { id = "task-actor"
    ; title = "Actor-visible task"
    ; description = ""
    ; task_status =
        Masc_domain.Done
          { assignee = "beta"
          ; completed_at = "2026-08-21T04:00:00Z"
          ; notes = None
          }
    ; priority = 1
    ; files = []
    ; created_at = "2026-08-21T01:00:00Z"
    ; created_by = Some "planner"
    ; predecessor_task_id = None
    ; contract = None
    ; execution_links = Masc_domain.no_execution_links
    ; handoff_context = Some handoff
    ; cycle_count = 1
    ; reclaim_policy = None
    ; do_not_reclaim_reason = None
    ; skills = []
    }
  in
  let timeline_node : DGT.tree_node =
    { goal
    ; children = []
    ; tasks = [ task ]
    ; last_activity_at = "2026-08-21T04:00:00Z"
    ; stagnation_seconds = Some 0
    ; linked_keeper_names = []
    ; pending_approval_count = 0
    ; latest_keeper_ref = None
    ; latest_turn_ref = None
    ; activity_observation = "task_status"
    }
  in
  let event =
    match DGT.build_goal_timeline timeline_node [] [] [] with
    | [ event ] -> event
    | events -> failf "expected one task event, got %d" (List.length events)
  in
  check
    (option string)
    "status, typed actor role, and handoff author survive"
    (Some
       "done · completed by beta · handoff by alpha: continue from the saved \
        checkpoint")
    (field "summary" event)
;;

(* {1 Task severity} *)

(* [build_goal_timeline] picks a task's severity by matching [task_status].
   Exhaustiveness is what a seventh constructor runs into, and it says nothing
   about which of the three answers each of the six existing constructors gets:
   editing [Cancelled] to "ok" compiles, and until this test the whole suite
   stayed green while cancelled tasks rendered as healthy on the goal timeline.
   The only other caller of [build_goal_timeline] in this file asserts
   [summary], so [severity] had no assertion anywhere. *)

let task_with_status task_status : Masc_domain.task =
  { id = "task-severity"
  ; title = "Severity fixture"
  ; description = ""
  ; task_status
  ; priority = 1
  ; files = []
  ; created_at = "2026-08-21T01:00:00Z"
  ; created_by = Some "planner"
  ; predecessor_task_id = None
  ; contract = None
  ; execution_links = Masc_domain.no_execution_links
  ; handoff_context = None
  ; cycle_count = 1
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  ; skills = []
  }
;;

let test_task_severity_follows_the_status () =
  let severity_of task_status =
    let timeline_node : DGT.tree_node =
      { goal
      ; children = []
      ; tasks = [ task_with_status task_status ]
      ; last_activity_at = "2026-08-21T04:00:00Z"
      ; stagnation_seconds = Some 0
      ; linked_keeper_names = []
      ; pending_approval_count = 0
      ; latest_keeper_ref = None
      ; latest_turn_ref = None
      ; activity_observation = "task_status"
      }
    in
    match DGT.build_goal_timeline timeline_node [] [] [] with
    | [ event ] -> field "severity" event
    | events -> failf "expected one task event, got %d" (List.length events)
  in
  check (option string) "todo" (Some "ok") (severity_of Masc_domain.Todo);
  check
    (option string)
    "done"
    (Some "ok")
    (severity_of
       (Masc_domain.Done
          { assignee = "beta"; completed_at = "2026-08-21T04:00:00Z"; notes = None }));
  check
    (option string)
    "claimed"
    (Some "warn")
    (severity_of
       (Masc_domain.Claimed { assignee = "beta"; claimed_at = "2026-08-21T02:00:00Z" }));
  check
    (option string)
    "in_progress"
    (Some "warn")
    (severity_of
       (Masc_domain.InProgress { assignee = "beta"; started_at = "2026-08-21T02:00:00Z" }));
  check
    (option string)
    "awaiting_verification"
    (Some "warn")
    (severity_of
       (Masc_domain.AwaitingVerification
          { assignee = "beta"
          ; started_at = "2026-08-21T02:00:00Z"
          ; submitted_at = "2026-08-21T03:00:00Z"
          ; intent = Masc_domain.Complete_task
          ; verification_id = "verification-1"
          }));
  check
    (option string)
    "cancelled"
    (Some "bad")
    (severity_of
       (Masc_domain.Cancelled
          { cancelled_by = "beta"
          ; cancelled_at = "2026-08-21T04:00:00Z"
          ; reason = None
          }))
;;

let timeline_events_of json =
  match Yojson.Safe.Util.member "timeline_events" json with
  | `List items -> items
  | _ -> []
;;

let test_tree_field_is_normalized () =
  let json =
    DG.tree_node_to_json
      ~events_for_goal:(fun _ ->
        [ goal_phase_event (live_phase_payload ~phase:"blocked" ~actor:"alpha") ])
      node
  in
  match timeline_events_of json with
  | [ event ] ->
    (* The raw ledger row has no [kind]; its normalized form does. Asserting
       the summary too pins that the tree runs the same normalizer as the
       detail view rather than a second, drifting copy. *)
    check (option string) "kind" (Some "goal_phase") (field "kind" event);
    check (option string) "lane" (Some "goal") (field "lane" event);
    check
      (option string)
      "summary"
      (Some "phase=blocked by alpha")
      (field "summary" event);
    check (option string) "raw event_type is gone" None (field "event_type" event)
  | items ->
    failf "expected exactly one timeline event, got %d" (List.length items)
;;

let test_tree_field_is_empty_without_events () =
  let json = DG.tree_node_to_json ~events_for_goal:(fun _ -> []) node in
  check int "no events" 0 (List.length (timeline_events_of json))
;;

let () =
  run
    "goal timeline projection"
    [ ( "normalizer"
      , [ test_case "phase event shape" `Quick test_normalizes_a_phase_event
        ; test_case "summary names the actor" `Quick test_summary_names_the_actor
        ; test_case "severity follows the phase" `Quick test_severity_follows_the_phase
        ; test_case "unparseable phase is not ok" `Quick test_unparseable_phase_is_not_ok
        ; test_case "missing fields are marked" `Quick test_missing_payload_fields_are_marked
        ; test_case
            "unknown event type keeps its token"
            `Quick
            test_unknown_event_type_keeps_its_token
        ; test_case "task snapshot names actor and handoff" `Quick
            test_task_snapshot_names_actor_and_handoff
        ; test_case
            "task severity follows the status"
            `Quick
            test_task_severity_follows_the_status
        ] )
    ; ( "tree field"
      , [ test_case "timeline_events is normalized" `Quick test_tree_field_is_normalized
        ; test_case "empty without events" `Quick test_tree_field_is_empty_without_events
        ] )
    ]
;;

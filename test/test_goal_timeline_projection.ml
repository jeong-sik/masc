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

let test_mutation_summary_names_each_actor () =
  List.iter
    (fun (kind, actor, verb) ->
      let projected =
        DGT.goal_event_timeline_json
          (`Assoc
             [ "ts", `String "2026-09-29T12:00:00Z"
             ; "goal_id", `String "goal-shared"
             ; "event_type", `String kind
             ; "payload", `Assoc [ "actor", `String actor; "title", `String "Shared goal" ]
             ])
      in
      check (option string) "the action names its actor"
        (Some (verb ^ " by " ^ actor ^ ": Shared goal")) (field "summary" projected);
      check (option string) "the event kind survives" (Some kind) (field "kind" projected))
    [ "goal_created", "creator", "created"; "goal_updated", "reviewer", "updated" ]
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

(* A due date or priority edit writes [goal_edited] with only the fields it
   changed, each as {from, to} (#39878). *)
let goal_edited_event payload =
  `Assoc
    [ "ts", `String "2026-09-29T10:00:00Z"
    ; "goal_id", `String "goal-1"
    ; "event_type", `String "goal_edited"
    ; "payload", payload
    ]
;;

let edit_change ~from_json ~to_json = `Assoc [ "from", from_json; "to", to_json ]

let test_an_edit_event_shows_what_it_replaced () =
  let summary_of payload =
    field "summary" (DGT.goal_event_timeline_json (goal_edited_event payload))
  in
  let json =
    DGT.goal_event_timeline_json
      (goal_edited_event
         (`Assoc
            [ "actor", `String "alpha"
            ; ( "due_date"
              , edit_change ~from_json:(`String "2026-09-23") ~to_json:(`String "2026-10-15") )
            ; "priority", edit_change ~from_json:(`Int 3) ~to_json:(`Int 1)
            ]))
  in
  check (option string) "kind is the event type" (Some "goal_edited") (field "kind" json);
  check (option string) "title" (Some "Goal Edit") (field "title" json);
  check (option string) "severity" (Some "ok") (field "severity" json);
  check
    (option string)
    "both fields and the editor"
    (Some "due_date 2026-09-23 -> 2026-10-15, priority 3 -> 1 by alpha")
    (field "summary" json);
  check
    (option string)
    "a due date that was not set"
    (Some "due_date (none) -> 2026-10-15 by alpha")
    (summary_of
       (`Assoc
          [ "actor", `String "alpha"
          ; "due_date", edit_change ~from_json:`Null ~to_json:(`String "2026-10-15")
          ]));
  check
    (option string)
    "a payload with no changed field is marked"
    (Some "<missing payload.due_date and payload.priority> by <missing payload.actor>")
    (summary_of (`Assoc []));
  check
    (option string)
    "a field that is present but unreadable is marked"
    (Some "priority <missing payload.priority.from> -> 1 by alpha")
    (summary_of
       (`Assoc
          [ "actor", `String "alpha"
          ; "priority", `Assoc [ "to", `Int 1 ]
          ]))
;;

(* A row this build cannot read is marked in the summary and is `warn`, so the
   marker is not the only sign of it. The producer writes objects and nothing
   else, so these rows come from a damaged file or from another writer. *)
let test_an_edit_row_that_cannot_be_read_is_marked_and_warned () =
  let read payload =
    let json = DGT.goal_event_timeline_json (goal_edited_event payload) in
    field "summary" json, field "severity" json
  in
  let summary_and_severity = pair (option string) (option string) in
  let priority_moved = edit_change ~from_json:(`Int 3) ~to_json:(`Int 1) in
  check
    summary_and_severity
    "a field that is not an object"
    (Some "due_date <unreadable payload.due_date>, priority 3 -> 1 by a", Some "warn")
    (read
       (`Assoc
          [ "actor", `String "a"
          ; "due_date", `String "2026-10-15"
          ; "priority", priority_moved
          ]));
  check
    summary_and_severity
    "a value that is neither text, a number nor null"
    (Some "priority <unreadable payload.priority.from> -> 1 by a", Some "warn")
    (read
       (`Assoc
          [ "actor", `String "a"
          ; "priority", edit_change ~from_json:(`Bool true) ~to_json:(`Int 1)
          ]));
  check
    summary_and_severity
    "a key that is missing"
    (Some "priority <missing payload.priority.from> -> 1 by a", Some "warn")
    (read (`Assoc [ "actor", `String "a"; "priority", `Assoc [ "to", `Int 1 ] ]));
  check
    summary_and_severity
    "no changed field"
    (Some "<missing payload.due_date and payload.priority> by a", Some "warn")
    (read (`Assoc [ "actor", `String "a" ]));
  check
    summary_and_severity
    "no editor"
    (Some "priority 3 -> 1 by <missing payload.actor>", Some "warn")
    (read (`Assoc [ "priority", priority_moved ]));
  check
    summary_and_severity
    "a row that reads whole is not flagged"
    (Some "priority 3 -> 1 by a", Some "ok")
    (read (`Assoc [ "actor", `String "a"; "priority", priority_moved ]))
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
  ; criterion_revision = "fixture-goal-1"
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

(* [goals.json] holds only the current set, so what the log says about a goal
   that left it is the only record it existed (#35359). *)
let history_row ?(ts = "2026-09-10T00:00:00Z") ~goal_id ~event_type payload =
  `Assoc
    [ "ts", `String ts
    ; "goal_id", `String goal_id
    ; "event_type", `String event_type
    ; "payload", payload
    ]
;;

let unlisted json =
  Yojson.Safe.Util.member "unlisted" json |> Yojson.Safe.Util.to_list
;;

let coverage json name =
  Yojson.Safe.Util.member "coverage" json |> Yojson.Safe.Util.member name
;;

let test_unlisted_history_reconstructs_a_departed_goal () =
  let rows =
    [ history_row ~ts:"2026-09-10T00:00:00Z" ~goal_id:"goal-gone"
        ~event_type:"goal_created"
        (`Assoc [ "store_version", `Int 1; "title", `String "Shipped and gone" ])
    ; history_row ~ts:"2026-09-10T03:00:00Z" ~goal_id:"goal-gone"
        ~event_type:"goal_updated"
        (`Assoc [ "store_version", `Int 2; "title", `String "Reviewed and shipped"; "actor", `String "reviewer" ])
    ; history_row ~ts:"2026-09-10T06:00:00Z" ~goal_id:"goal-gone"
        ~event_type:"goal_phase"
        (live_phase_payload ~phase:"completed" ~actor:"alpha")
      (* A goal the store still lists is already on every goal surface. *)
    ; history_row ~goal_id:"goal-listed" ~event_type:"goal_created"
        (`Assoc [ "store_version", `Int 1; "title", `String "Still here" ])
    ]
  in
  let json =
    DG.unlisted_goal_history_of_rows ~listed:[ "goal-listed" ] ~rows ~malformed_lines:0
  in
  let rows_out = unlisted json in
  check int "a goal the store still lists is not history" 1 (List.length rows_out);
  let row = List.hd rows_out in
  check (option string) "the goal is named" (Some "goal-gone") (field "goal_id" row);
  check (option string) "the updated title outlived the store" (Some "Reviewed and shipped")
    (field "title" row);
  check (option string) "opening comes from the creation row"
    (Some "2026-09-10T00:00:00Z") (field "opened_at" row);
  check (option string) "a terminal phase closes the goal"
    (Some "2026-09-10T06:00:00Z") (field "closed_at" row);
  check (option string) "the final phase is reported" (Some "completed")
    (field "final_phase" row);
  check (float 0.001) "lifetime spans the two rows" 6.0
    (Yojson.Safe.Util.member "lifetime_hours" row |> Yojson.Safe.Util.to_float)
;;

(* A due date or priority edit changes neither when the goal opened nor the
   phase it reached, and it is a type this reader knows, so it is not listed as
   one it could not read. *)
let test_unlisted_history_uses_committed_snapshot_order () =
  let snapshot title version = `Assoc
    [ "title", `String title; "store_version", `Int version;
      "updated_at", `String "2026-09-10T00:00:00Z" ] in
  let created = history_row ~goal_id:"goal-gone" ~event_type:"goal_created"
    (snapshot "Initial" 1) in
  let older = history_row ~ts:"2026-09-10T04:00:00Z" ~goal_id:"goal-gone"
    ~event_type:"goal_updated" (snapshot "Older" 2) in
  let newer = history_row ~ts:"2026-09-10T03:00:00Z" ~goal_id:"goal-gone"
    ~event_type:"goal_updated" (snapshot "Current" 3) in
  List.iter (fun rows ->
    let json = DG.unlisted_goal_history_of_rows ~listed:[] ~rows ~malformed_lines:0 in
    let row = List.hd (unlisted json) in
    check (option string) "title follows committed revision despite tied snapshot times" (Some "Current")
      (field "title" row))
    [[created; newer; older]; [older; newer; created]; [created; older; newer]]
;;

let test_unlisted_history_knows_the_edit_event () =
  let rows =
    [ history_row ~ts:"2026-09-10T00:00:00Z" ~goal_id:"goal-gone"
        ~event_type:"goal_created"
        (`Assoc [ "store_version", `Int 1; "title", `String "Edited then gone" ])
    ; history_row ~ts:"2026-09-10T03:00:00Z" ~goal_id:"goal-gone"
        ~event_type:"goal_edited"
        (`Assoc
           [ "actor", `String "alpha"
           ; "priority", edit_change ~from_json:(`Int 3) ~to_json:(`Int 1)
           ])
    ; history_row ~ts:"2026-09-10T06:00:00Z" ~goal_id:"goal-gone"
        ~event_type:"goal_phase"
        (live_phase_payload ~phase:"completed" ~actor:"alpha")
    ]
  in
  let json = DG.unlisted_goal_history_of_rows ~listed:[] ~rows ~malformed_lines:0 in
  check (list string) "the edit event is recognised" []
    (coverage json "unrecognised_event_types"
     |> Yojson.Safe.Util.to_list
     |> List.map Yojson.Safe.Util.to_string);
  match unlisted json with
  | [ row ] ->
    check (option string) "opening still comes from the creation row"
      (Some "2026-09-10T00:00:00Z") (field "opened_at" row);
    check (option string) "the final phase still comes from the phase row"
      (Some "completed") (field "final_phase" row)
  | rows_out -> fail (Printf.sprintf "expected one goal, got %d" (List.length rows_out))
;;

let test_unlisted_history_does_not_invent_an_outcome () =
  let rows =
    [ history_row ~ts:"2026-09-01T00:00:00Z" ~goal_id:"goal-open"
        ~event_type:"goal_phase"
        (live_phase_payload ~phase:"verifying" ~actor:"alpha")
      (* No creation row: this goal predates goal_created. *)
    ; history_row ~ts:"2026-09-02T00:00:00Z" ~goal_id:"goal-old"
        ~event_type:"goal_phase"
        (live_phase_payload ~phase:"dropped" ~actor:"alpha")
    ]
  in
  let json = DG.unlisted_goal_history_of_rows ~listed:[] ~rows ~malformed_lines:0 in
  let row id =
    List.find (fun r -> field "goal_id" r = Some id) (unlisted json)
  in
  let still_open = row "goal-open" in
  check (option string) "a non-terminal phase is still reported" (Some "verifying")
    (field "final_phase" still_open);
  check (option string) "but it closes nothing" None (field "closed_at" still_open);
  check bool "and spans nothing" true
    (Yojson.Safe.Util.member "lifetime_hours" still_open = `Null);
  let old_goal = row "goal-old" in
  check (option string) "a goal with no creation row has no opening" None
    (field "opened_at" old_goal);
  check (option string) "nor a title" None (field "title" old_goal);
  check (option string) "its ending is still known" (Some "2026-09-02T00:00:00Z")
    (field "closed_at" old_goal);
  check bool "an ending alone spans nothing" true
    (Yojson.Safe.Util.member "lifetime_hours" old_goal = `Null)
;;

let test_unlisted_history_reports_what_it_could_not_read () =
  let rows =
    [ `Assoc [ "ts", `String "2026-09-01T00:00:00Z"; "event_type", `String "goal_phase" ]
    ; history_row ~goal_id:"goal-x" ~event_type:"goal_retired_somehow" (`Assoc [])
    ; history_row ~goal_id:"goal-x" ~event_type:"goal_created"
        (`Assoc [ "store_version", `Int 1; "title", `String "X" ])
    ]
  in
  let json = DG.unlisted_goal_history_of_rows ~listed:[] ~rows ~malformed_lines:3 in
  check int "malformed lines are carried through" 3
    (coverage json "malformed_event_lines" |> Yojson.Safe.Util.to_int);
  check int "a row naming no goal is counted" 1
    (coverage json "rows_without_goal_id" |> Yojson.Safe.Util.to_int);
  check (list string) "an unknown event type is named, not dropped"
    [ "goal_retired_somehow" ]
    (coverage json "unrecognised_event_types"
     |> Yojson.Safe.Util.to_list
     |> List.map Yojson.Safe.Util.to_string);
  check int "the goal still appears from the rows that were understood" 1
    (List.length (unlisted json))
;;

let snapshot_row version title =
  history_row ~goal_id:"goal-gone" ~event_type:"goal_updated"
    (`Assoc ["store_version", `Int version; "title", `String title;
      "updated_at", `String "2026-09-10T00:00:00Z"])

let test_snapshot_titles_follow_commits_not_append_or_time () =
  let created = history_row ~goal_id:"goal-gone" ~event_type:"goal_created"
    (`Assoc ["store_version", `Int 1; "title", `String "created"] ) in
  List.iter (fun rows ->
    let json = DG.unlisted_goal_history_of_rows ~listed:[] ~rows ~malformed_lines:0 in
    let row = List.hd (unlisted json) in
    check (option string) "last committed title wins even with tied timestamps"
      (Some "last update") (field "title" row);
    check (option string) "the title has committed ordering" (Some "committed") (field "title_ordering" row))
    [[created; snapshot_row 3 "last update"; snapshot_row 2 "first update"];
     [snapshot_row 2 "first update"; snapshot_row 3 "last update"; created]]
;;

let test_snapshot_ordering_refuses_unknown_and_conflicting_witnesses () =
  List.iter (fun payload ->
    let unknown = history_row ~goal_id:"goal-gone" ~event_type:"goal_updated" payload in
    let json = DG.unlisted_goal_history_of_rows ~listed:[]
      ~rows:[unknown; snapshot_row 2 "known"] ~malformed_lines:0 in
    let row = List.hd (unlisted json) in
    check (option string) "unknown order cannot claim a latest title" None (field "title" row);
    check (option string) "unknown snapshot ordering is visible" (Some "unknown") (field "title_ordering" row);
    check int "the unordered snapshot is counted" 1
      (coverage json "unordered_snapshot_rows" |> Yojson.Safe.Util.to_int))
    [`Assoc ["title", `String "missing version"];
     `Assoc ["store_version", `Int 0; "title", `String "zero"];
     `Assoc ["store_version", `String "3"; "title", `String "string version"];
     `Assoc ["store_version", `Int 3; "store_version", `Int 4; "title", `String "duplicate"]];
  List.iter (fun rows ->
    let row = DG.unlisted_goal_history_of_rows ~listed:[] ~rows ~malformed_lines:0 |> unlisted |> List.hd in
    check (option string) "conflicting same-commit titles have no guessed winner" None (field "title" row);
    check (option string) "conflicting latest version is visible" (Some "conflicting") (field "title_ordering" row))
    [[snapshot_row 2 "left"; snapshot_row 2 "right"];
     [snapshot_row 2 "right"; snapshot_row 2 "left"]];
  let row = DG.unlisted_goal_history_of_rows ~listed:[]
    ~rows:[snapshot_row 2 "left"; snapshot_row 2 "right"; snapshot_row 3 "later"; snapshot_row 2 "left"]
    ~malformed_lines:0 |> unlisted |> List.hd in
  check (option string) "a later committed version resolves earlier ambiguity"
    (Some "later") (field "title" row)
;;

let () =
  run
    "goal timeline projection"
    [ ( "normalizer"
      , [ test_case "phase event shape" `Quick test_normalizes_a_phase_event
        ; test_case "summary names the actor" `Quick test_summary_names_the_actor
        ; test_case "creation and update actors" `Quick test_mutation_summary_names_each_actor
        ; test_case "severity follows the phase" `Quick test_severity_follows_the_phase
        ; test_case "unparseable phase is not ok" `Quick test_unparseable_phase_is_not_ok
        ; test_case "missing fields are marked" `Quick test_missing_payload_fields_are_marked
        ; test_case
            "an edit event shows what it replaced"
            `Quick
            test_an_edit_event_shows_what_it_replaced
        ; test_case
            "an edit row that cannot be read is marked and warned"
            `Quick
            test_an_edit_row_that_cannot_be_read_is_marked_and_warned
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
    ; ( "unlisted history"
      , [ test_case "snapshot titles follow commit order" `Quick test_snapshot_titles_follow_commits_not_append_or_time
        ; test_case "unknown and conflicting snapshot witnesses are explicit" `Quick test_snapshot_ordering_refuses_unknown_and_conflicting_witnesses
        ; test_case "a departed goal is reconstructed" `Quick
            test_unlisted_history_reconstructs_a_departed_goal
        ; test_case "snapshots follow committed revisions" `Quick
            test_unlisted_history_uses_committed_snapshot_order
        ; test_case "the edit event is recognised" `Quick
            test_unlisted_history_knows_the_edit_event
        ; test_case "no outcome is invented" `Quick
            test_unlisted_history_does_not_invent_an_outcome
        ; test_case "what it could not read is reported" `Quick
            test_unlisted_history_reports_what_it_could_not_read
        ] )
    ]
;;

(* Keeper lifecycle control on the TUI Keepers surface: which actions a
   reading offers, what the operator sees as its status, and the request
   sequence each action takes. *)

module Control = Masc_tui_keeper_control
module Status = Masc.Keeper_status_runtime
module Decode = Masc.Tui_decode

let phase raw =
  match Decode.keeper_phase_of_string raw with
  | Some value -> value
  | None -> invalid_arg ("unknown test Keeper phase: " ^ raw)

let health raw =
  match Decode.keeper_health_of_string raw with
  | Some value -> value
  | None -> invalid_arg ("unknown test Keeper health: " ^ raw)

let runtime ?(keepalive_running = true) ?(health = health "healthy") ?(paused = false)
    ?(next_action = None) ?(activation_mode = Decode.Activation_autonomous)
    ?(runtime_id = "anthropic.claude-opus-5-5") ?(phase = phase "running")
    ?(sandbox_profile = "docker") ?(last_failure = None) name :
    Decode.keeper_runtime =
  { kr_name = name
  ; kr_identity = Ok { k_trace_id = "trace-" ^ name;
      k_created_at = "2026-09-30T00:00:00Z"; k_updated_at = "2026-09-30T00:00:00Z" }
  ; kr_portrait = Decode.Ready Keeper_portrait_look.bare
  ; kr_candle_account_revision = Ok None
  ; kr_health = health
  ; kr_paused = paused
  ; kr_next_action = next_action
  ; kr_keepalive_running = keepalive_running
  ; kr_activation_mode = activation_mode
  ; kr_runtime_id = runtime_id
  ; kr_phase = phase
  ; kr_sandbox_profile = sandbox_profile
  ; kr_runtime_blocker_summary = None
  ; kr_last_failure = last_failure
  ; kr_runtime_blocker_signature = None
  ; kr_runtime_lane_observation = None
  ; kr_runtime_path_rest = Ok None
  ; kr_operator_disposition = Ok None
  ; kr_failing_since = None
  ; kr_recent_turns = None
  }

let complete rows = Control.roster_of_reading
    ~errors:[] ~rows ~truncated:false ~total:(List.length rows)

(* RFC-0481 §3.3: a signal names one Keeper, and its read replaces that row. *)
let row_names rows = List.map (fun (row : Decode.keeper_runtime) -> row.kr_name) rows

let spliced roster ~keeper_name reading =
  match Control.replace_row roster ~keeper_name reading with
  | Some roster -> Control.roster_view roster
  | None -> Alcotest.failf "a complete roster refused the row for %s" keeper_name

let test_one_row_takes_its_place_in_a_complete_roster () =
  let roster = complete [ runtime "alpha"; runtime "gamma" ] in
  (match spliced roster ~keeper_name:"beta" (Control.Row (runtime "beta")) with
   | Control.Roster_complete rows ->
     Alcotest.(check (list string)) "a new name joins in name order"
       [ "alpha"; "beta"; "gamma" ] (row_names rows)
   | Control.Roster_unobserved | Control.Roster_partial _ | Control.Roster_invalid _ ->
     Alcotest.fail "an added row left the roster incomplete");
  (match spliced roster ~keeper_name:"gamma" Control.No_row with
   | Control.Roster_complete rows ->
     Alcotest.(check (list string)) "no row removes the Keeper" [ "alpha" ] (row_names rows)
   | Control.Roster_unobserved | Control.Roster_partial _ | Control.Roster_invalid _ ->
     Alcotest.fail "a removed row left the roster incomplete");
  let broken =
    match Control.replace_row roster ~keeper_name:"alpha" (Control.Row_invalid "unreadable") with
    | Some broken -> broken
    | None -> Alcotest.fail "a complete roster refused an error row"
  in
  (match Control.roster_view broken with
   | Control.Roster_invalid { observed; errors; complete } ->
     Alcotest.(check (list string)) "the broken Keeper leaves the rows" [ "gamma" ] (row_names observed);
     Alcotest.(check (list (pair string string))) "and joins the errors"
       [ "alpha", "unreadable" ] errors;
     Alcotest.(check bool) "the roster stays complete" true complete
   | Control.Roster_unobserved | Control.Roster_partial _ | Control.Roster_complete _ ->
     Alcotest.fail "an error row did not mark the roster invalid");
  (match spliced broken ~keeper_name:"alpha" (Control.Row (runtime "alpha")) with
   | Control.Roster_complete rows ->
     Alcotest.(check (list string)) "a repaired row clears the error"
       [ "alpha"; "gamma" ] (row_names rows)
   | Control.Roster_unobserved | Control.Roster_partial _ | Control.Roster_invalid _ ->
     Alcotest.fail "a repaired row left the roster invalid")
;;

let test_an_incomplete_roster_does_not_take_one_row () =
  let clamped =
    Control.roster_of_reading ~errors:[] ~rows:[ runtime "alpha" ] ~truncated:true ~total:2
  in
  Alcotest.(check bool) "an unread roster asks for a whole read" true
    (Option.is_none
       (Control.replace_row Control.unobserved_roster ~keeper_name:"alpha" Control.No_row));
  Alcotest.(check bool) "a clamped roster asks for a whole read" true
    (Option.is_none (Control.replace_row clamped ~keeper_name:"beta" (Control.Row (runtime "beta"))))
;;

let test_a_row_read_answers_only_its_keeper () =
  let read ~rows ~errors = Control.row_reading_of_reading ~keeper_name:"alpha" ~rows ~errors in
  (match read ~rows:[ runtime "alpha" ] ~errors:[] with
   | Ok (Control.Row row) -> Alcotest.(check string) "its row" "alpha" row.kr_name
   | Ok (Control.Row_invalid _ | Control.No_row) | Error _ -> Alcotest.fail "its row was not read");
  (match read ~rows:[] ~errors:[ "alpha", "unreadable" ] with
   | Ok (Control.Row_invalid detail) -> Alcotest.(check string) "its error" "unreadable" detail
   | Ok (Control.Row _ | Control.No_row) | Error _ -> Alcotest.fail "its error row was not read");
  (match read ~rows:[] ~errors:[] with
   | Ok Control.No_row -> ()
   | Ok (Control.Row _ | Control.Row_invalid _) | Error _ -> Alcotest.fail "no row was not read");
  List.iter (fun (label, rows, errors) ->
      match read ~rows ~errors with
      | Error _ -> ()
      | Ok (Control.Row _ | Control.Row_invalid _ | Control.No_row) -> Alcotest.fail label)
    [ "another Keeper's row is refused", [ runtime "beta" ], []
    ; "another Keeper's error is refused", [], [ "beta", "unreadable" ]
    ; "two rows are refused", [ runtime "alpha"; runtime "alpha" ], [] ]
;;

(* The builder above creates every Keeper at this time. *)
let created_at = "2026-09-30T00:00:00Z"

let test_a_starting_keeper_is_read_when_probe_ends () =
  let created =
    match Workspace_resilience.Time.parse_iso8601_opt created_at with
    | Some created -> created
    | None -> Alcotest.fail "the builder's creation time does not parse"
  in
  let until ?health:(health_state = health "idle") ?(identity = true) next_action =
    let row = runtime ~health:health_state ~next_action "alpha" in
    let row =
      if identity then row
      else { row with kr_identity = Error "identity unreadable" }
    in
    Control.starting_up_until row
  in
  let at = Some (created +. Status.agent_staleness_threshold_s) in
  Alcotest.(check (option (float 0.0))) "idle and probing" at (until (Some Status.Probe));
  Alcotest.(check (option (float 0.0))) "healthy and probing" at
    (until ~health:(health "healthy") (Some Status.Probe));
  Alcotest.(check (option (float 0.0))) "a failing Keeper probes with no end" None
    (until ~health:(health "failing") (Some Status.Probe));
  Alcotest.(check (option (float 0.0))) "a Keeper past starting" None
    (until (Some Status.Direct_message));
  Alcotest.(check (option (float 0.0))) "no next action" None (until None);
  Alcotest.(check (option (float 0.0))) "no creation time to count from" None
    (until ~identity:false (Some Status.Probe))
;;

let reading ?(paused = false) ?(liveness = Control.Unobserved) name :
    Control.reading =
  { name; paused; liveness }

let identity_absence =
  Alcotest.testable
    (fun ppf absence ->
      Format.pp_print_string ppf (Decode.keeper_identity_absence_text ~ko:false absence))
    ( = )

let action_testable =
  Alcotest.testable
    (fun fmt action -> Format.pp_print_string fmt (Control.action_label ~ko:false action))
    ( = )

let check_actions label expected actual =
  Alcotest.(check (list action_testable)) label expected actual

(* An unobserved roster is the case that matters most: the durable metadata is
   still readable, so a reading built only from it looks complete while saying
   nothing about whether a fiber is alive. Offering boot there starts a second
   fiber on a keeper that is already running. *)
let test_unobserved_offers_confirmed_delete () =
  let r = reading "analyst" in
  check_actions "only confirmed delete without a roster" [ Control.Delete ] (Control.available r);
  Alcotest.(check (option action_testable))
    "no primary without a roster" None (Control.primary r);
  Alcotest.(check string) "health is unread" "unread" (Control.health_label ~ko:false r)

let test_absent_offers_boot () =
  let r = reading ~liveness:Control.Absent "analyst" in
  check_actions "boot, then delete"
      [ Control.Boot; Control.Delete ]
      (Control.available r);
  Alcotest.(check string) "an absent keeper reads absent, not unread" "absent from live roster"
    (Control.health_label ~ko:false r)

(* A keeper the operator paused and then shut down is absent from the roster.
   Pause is its own field, so it still reads even where health cannot. *)
let test_absent_and_paused_reads_paused () =
  let r = reading ~paused:true ~liveness:Control.Absent "analyst" in
  Alcotest.(check bool) "pause survives an absent roster" true r.Control.paused;
  check_actions "boot, then delete"
      [ Control.Boot; Control.Delete ]
      (Control.available r)

let test_live_running_offers_pause () =
  let r = reading ~liveness:(Control.Present (runtime "analyst")) "analyst" in
  check_actions "pause first"
    [ Control.Pause; Control.Wakeup; Control.Shutdown; Control.Delete ]
    (Control.available r);
  Alcotest.(check (option action_testable))
    "primary is pause" (Some Control.Pause) (Control.primary r);
  Alcotest.(check string) "healthy" "healthy" (Control.health_label ~ko:false r)

let test_live_paused_offers_resume () =
  let r =
    reading ~paused:true
      ~liveness:(Control.Present (runtime "analyst"))
      "analyst"
  in
  check_actions "resume first"
    [ Control.Resume; Control.Wakeup; Control.Shutdown; Control.Delete ]
    (Control.available r);
  Alcotest.(check (option action_testable))
    "primary is resume" (Some Control.Resume) (Control.primary r);
  (* On the live roster, Paused publishes keepalive_running = false because
     can_execute_turn is false while the fiber sleeps on its condition. *)
  let server_paused =
    reading ~paused:true
      ~liveness:
        (Control.Present
           (runtime ~keepalive_running:false ~paused:true
              ~phase:(phase "paused") ~health:(health "offline") "analyst"))
      "analyst"
  in
  check_actions "server paused phase still offers resume, not boot"
    [ Control.Resume; Control.Wakeup; Control.Shutdown; Control.Delete ]
    (Control.available server_paused);
  Alcotest.(check (option action_testable))
    "primary stays resume in paused phase" (Some Control.Resume)
    (Control.primary server_paused)

(* Pause is a person's decision and health is an observation, so neither
   replaces the other: a paused keeper whose keepalive is gone reads offline
   and paused, not one word for both. *)
let test_pause_and_health_are_read_separately () =
  let live = runtime ~health:(health "offline") "analyst" in
  let resting = reading ~liveness:(Control.Present live) "analyst" in
  let stopped = reading ~paused:true ~liveness:(Control.Present live) "analyst" in
  Alcotest.(check string)
    "health reads the same either way" "offline"
    (Control.health_label ~ko:false resting);
  Alcotest.(check string)
    "pause does not overwrite it" "offline" (Control.health_label ~ko:false stopped);
  Alcotest.(check bool) "and pause is still readable" true stopped.Control.paused

(* A row can be in the roster with its keepalive fiber stopped. Pause has
   nothing to pause there, so the fiber pair is what applies. *)
let test_registered_without_fiber_offers_boot () =
  let live =
    runtime ~keepalive_running:false "analyst"
  in
  let r = reading ~liveness:(Control.Present live) "analyst" in
  check_actions "boot, not pause; delete too"
    [ Control.Boot; Control.Delete ]
    (Control.available r)

(* The roster is the only witness that a fiber runs a keeper; a pause is the
   metadata's, and does not stop the fiber. *)
let test_runs_follows_the_roster_and_not_the_pause () =
  let check label expected r =
    Alcotest.(check (option bool)) label expected (Control.runs r)
  in
  check "roster not read" None (reading "analyst");
  check "roster unreadable" None (reading ~liveness:(Control.Invalid "bad") "analyst");
  check "absent from the roster" (Some false) (reading ~liveness:Control.Absent "analyst");
  check "registered without a fiber" (Some false)
    (reading ~liveness:(Control.Present (runtime ~keepalive_running:false "analyst")) "analyst");
  check "a fiber runs it" (Some true)
    (reading ~liveness:(Control.Present (runtime "analyst")) "analyst");
  check "paused, and its fiber runs" (Some true)
    (reading ~paused:true ~liveness:(Control.Present (runtime "analyst")) "analyst");
  check "paused phase keeps its sleeping fiber even with keepalive_running false"
    (Some true)
    (reading ~paused:true
       ~liveness:
         (Control.Present
            (runtime ~keepalive_running:false ~paused:true
               ~phase:(phase "paused") ~health:(health "offline") "analyst"))
       "analyst");
  check "paused metadata with offline phase has no fiber" (Some false)
    (reading ~paused:true
       ~liveness:
         (Control.Present
            (runtime ~keepalive_running:false ~paused:true
               ~phase:(phase "offline") ~health:(health "offline") "analyst"))
       "analyst");
  List.iter
    (fun transitioning_phase ->
       let r =
         reading
           ~liveness:
             (Control.Present
                (runtime ~keepalive_running:false
                   ~phase:(phase transitioning_phase)
                   ~health:(health "offline") "analyst"))
           "analyst"
       in
       check (transitioning_phase ^ " phase is transitioning, not bootable") None r;
       check_actions
         (transitioning_phase ^ " phase offers only delete")
         [ Control.Delete ]
         (Control.available r);
       Alcotest.(check (option action_testable))
         (transitioning_phase ^ " phase has no primary toggle action")
         None
         (Control.primary r))
    [ "draining"; "restarting" ]

let test_only_shutdown_confirms () =
  List.iter
    (fun (action, expected) ->
       Alcotest.(check bool)
         (Control.action_label ~ko:false action)
         expected
         (Control.requires_confirmation action))
    [ (Control.Pause, false)
    ; (Control.Resume, false)
    ; (Control.Boot, false)
    ; (Control.Wakeup, false)
    ; (Control.Shutdown, true)
    ]

let test_reversible_action_submits_on_first_press () =
  match
    Control.gate_transition ~inflight:false ~pending:None ~keeper:"analyst"
      Control.Pause
  with
  | Control.Gate_submit -> ()
  | Control.Gate_arm _ -> Alcotest.fail "pause must not need a second press"
  | Control.Gate_blocked_inflight -> Alcotest.fail "nothing is in flight"

let test_shutdown_arms_then_submits () =
  match
    Control.gate_transition ~inflight:false ~pending:None ~keeper:"analyst"
      Control.Shutdown
  with
  | Control.Gate_arm armed -> (
      Alcotest.(check string) "armed keeper" "analyst" armed.pending_keeper;
      match
        Control.gate_transition ~inflight:false ~pending:(Some armed)
          ~keeper:"analyst" Control.Shutdown
      with
      | Control.Gate_submit -> ()
      | Control.Gate_arm _ ->
          Alcotest.fail "second press on the same keeper must submit"
      | Control.Gate_blocked_inflight ->
          Alcotest.fail "nothing is in flight")
  | Control.Gate_submit ->
      Alcotest.fail "shutdown must not submit on the first press"
  | Control.Gate_blocked_inflight -> Alcotest.fail "nothing is in flight"

(* Moving the cursor between the arm and the submit is the accident the gate
   exists for: the armed confirmation must not carry over to whichever keeper
   the cursor now sits on. *)
let test_arming_does_not_carry_to_another_keeper () =
  let armed =
    { Control.pending_keeper = "analyst"; pending_action = Control.Shutdown }
  in
  match
    Control.gate_transition ~inflight:false ~pending:(Some armed)
      ~keeper:"bandleader" Control.Shutdown
  with
  | Control.Gate_arm rearmed ->
      Alcotest.(check string)
        "re-armed on the keeper under the cursor" "bandleader"
        rearmed.pending_keeper
  | Control.Gate_submit ->
      Alcotest.fail "another keeper's arming must not submit this one"
  | Control.Gate_blocked_inflight -> Alcotest.fail "nothing is in flight"

let test_arming_does_not_carry_to_another_action () =
  let armed =
    { Control.pending_keeper = "analyst"; pending_action = Control.Shutdown }
  in
  match
    Control.gate_transition ~inflight:false ~pending:(Some armed)
      ~keeper:"analyst" Control.Pause
  with
  | Control.Gate_submit -> ()
  | Control.Gate_arm _ -> Alcotest.fail "pause needs no confirmation"
  | Control.Gate_blocked_inflight -> Alcotest.fail "nothing is in flight"

let test_inflight_blocks_every_action () =
  List.iter
    (fun action ->
       match
         Control.gate_transition ~inflight:true ~pending:None ~keeper:"analyst"
           action
       with
       | Control.Gate_blocked_inflight -> ()
       | Control.Gate_submit | Control.Gate_arm _ ->
           Alcotest.fail
             (Printf.sprintf "%s must not start while one is in flight"
                (Control.action_label ~ko:false action)))
    [ Control.Pause
    ; Control.Resume
    ; Control.Boot
    ; Control.Shutdown
    ; Control.Wakeup
    ]

let step_testable =
  Alcotest.testable
    (fun fmt step ->
       match step with
       | Control.Lifecycle action -> Format.fprintf fmt "lifecycle:%s" action
       | Control.Directive action -> Format.fprintf fmt "directive:%s" action
       | Control.Purge -> Format.fprintf fmt "purge")
    ( = )

let test_plans_name_their_endpoints () =
  Alcotest.(check (list step_testable))
    "pause is a directive"
    [ Control.Directive "pause" ]
    (Control.plan Control.Pause);
  Alcotest.(check (list step_testable))
    "resume is a directive"
    [ Control.Directive "resume" ]
    (Control.plan Control.Resume);
  Alcotest.(check (list step_testable))
    "wake is a directive"
    [ Control.Directive "wakeup" ]
    (Control.plan Control.Wakeup);
  Alcotest.(check (list step_testable))
    "boot is a lifecycle post"
    [ Control.Lifecycle "boot" ]
    (Control.plan Control.Boot);
  Alcotest.(check (list step_testable))
    "shutdown is a lifecycle post"
    [ Control.Lifecycle "shutdown" ]
    (Control.plan Control.Shutdown);
  (* Not a lifecycle step. The route is a dashboard action outside
     /api/v1/keepers/ and takes the keeper in the body, so spelling it as one
     would post to a path that does not exist. *)
  Alcotest.(check (list step_testable))
    "delete is the purge post"
    [ Control.Purge ]
    (Control.plan Control.Delete)

(* Delete is the only action with no inverse: boot undoes a shutdown, and
   nothing undoes a purge. *)
let test_delete_is_confirmed_and_irreversible () =
  Alcotest.(check bool) "delete arms before it submits" true
    (Control.requires_confirmation Control.Delete);
  Alcotest.(check (option (list step_testable)))
    "and a conflict on it is a rejection, not a detour" None
    (Control.recovers_from_conflict Control.Delete);
  (* Not "d": masc_tui.ml binds that on this surface to repository changes. *)
  Alcotest.(check string) "delete takes x" "x"
    (Control.action_key Control.Delete);
  Alcotest.(check bool) "and the arm has a list to name" true
    (List.length Control.purge_artifacts > 0)

(* Delete remains a confirmed action and delegates live-lane shutdown to the
   durable server operation. An unread roster still offers confirmed deletion. *)
let test_delete_is_offered_with_shutdown_confirmation () =
  let live = reading ~liveness:(Control.Present (runtime "analyst")) "analyst" in
  Alcotest.(check bool) "confirmed delete available while a fiber runs" true
    (List.mem Control.Delete (Control.available live));
  let paused =
    reading ~paused:true ~liveness:(Control.Present (runtime "analyst")) "analyst"
  in
  Alcotest.(check bool) "also for a paused lane" true
    (List.mem Control.Delete (Control.available paused));
  (* An unread roster cannot say the fiber is gone. *)
  Alcotest.(check bool) "also without a roster; server resolves ownership" true
    (List.mem Control.Delete (Control.available (reading "analyst")));
  (* An absent lane still offers boot as the primary action. *)
  let absent = reading ~liveness:Control.Absent "analyst" in
  Alcotest.(check bool) "offered once the fiber is gone" true
    (List.mem Control.Delete (Control.available absent));
  Alcotest.(check (option action_testable))
    "the toggle key still means boot" (Some Control.Boot)
    (Control.primary absent)

(* /boot answers 409 while the owner is operator-paused, and the durable pause
   only clears through the directive endpoint. Without the recovery steps, the
   keeper an operator just stopped from this surface is the one keeper the
   play key cannot start. *)
let test_boot_recovers_a_paused_owner () =
  Alcotest.(check (option (list step_testable)))
    "resume then boot"
    (Some [ Control.Directive "resume"; Control.Lifecycle "boot" ])
    (Control.recovers_from_conflict Control.Boot);
  List.iter
    (fun action ->
       Alcotest.(check (option (list step_testable)))
         (Control.action_label ~ko:false action)
         None
         (Control.recovers_from_conflict action))
    [ Control.Pause; Control.Resume; Control.Shutdown; Control.Wakeup ]

let directive_workspace : Decode.server_identity = {
  sid_version = "test"; sid_binary_commit = "test"; sid_binary_commit_age_s = None; sid_runtime_instance_id = None;
  sid_base_path = Masc.Tui_decode.Canonical_path.of_path "/workspace"; sid_masc_root = Masc.Tui_decode.Canonical_path.of_path "/workspace/.masc";
  sid_executable_in_worktree = None; sid_state_ready = Some true;
  sid_uptime = None; sid_sse_clients = None; sid_gc = None; sid_scheduler = None; sid_operator_action = None;
}

let check_directive_workspace fields =
  Alcotest.(check bool) "directive binds both workspace paths" true
    (List.assoc_opt "expected_workspace" fields = Some (`Assoc
      [ "base_path", `String (Decode.Canonical_path.to_string directive_workspace.sid_base_path)
      ; "masc_root", `String (Decode.Canonical_path.to_string directive_workspace.sid_masc_root) ]))

let test_purge_body_carries_keeper_and_workspace () =
  let body = Control.purge_body ~expected_workspace:directive_workspace "analyst" in
  match Yojson.Safe.from_string body with
  | `Assoc fields ->
      check_directive_workspace fields;
      Alcotest.(check bool) "the purge names its target" true
        (List.assoc_opt "agent_name" fields = Some (`String "analyst"))
  | _ -> Alcotest.fail "purge body must be a JSON object"

let test_deletion_retry_body_carries_keeper_operation_and_workspace () =
  let body =
    Control.deletion_retry_body ~expected_workspace:directive_workspace
      ~keeper_name:"analyst" ~operation_id:"op-123"
  in
  match Yojson.Safe.from_string body with
  | `Assoc fields ->
      check_directive_workspace fields;
      Alcotest.(check bool) "the retry names its keeper" true
        (List.assoc_opt "keeper_name" fields = Some (`String "analyst"));
      Alcotest.(check bool) "the retry names its operation" true
        (List.assoc_opt "operation_id" fields = Some (`String "op-123"))
  | _ -> Alcotest.fail "deletion retry body must be a JSON object"

let test_resume_body_carries_the_operation_id () =
  let operation_id = Control.mint_operation_id () in
  let body =
    Control.directive_body ~expected_workspace:directive_workspace ~operator_operation_id:operation_id
      "resume"
  in
  match Yojson.Safe.from_string body with
  | `Assoc fields ->
      check_directive_workspace fields;
      Alcotest.(check (option string))
        "action" (Some "resume")
        (match List.assoc_opt "action" fields with
         | Some (`String v) -> Some v
         | _ -> None);
      Alcotest.(check (option string))
        "operation id" (Some operation_id)
        (match List.assoc_opt "operator_operation_id" fields with
         | Some (`String v) -> Some v
         | _ -> None)
  | _ -> Alcotest.fail "resume body must be a JSON object"

let test_non_resume_directive_omits_the_operation_id () =
  let body = Control.directive_body ~expected_workspace:directive_workspace ~operator_operation_id:"ignored" "pause" in
  match Yojson.Safe.from_string body with
  | `Assoc fields ->
      check_directive_workspace fields;
      Alcotest.(check bool)
        "no operation id" false
        (List.mem_assoc "operator_operation_id" fields)
  | _ -> Alcotest.fail "pause body must be a JSON object"

(* One attempt retains its id in every resume body. A new attempt, including
   the first attempt after reopening the TUI, must not name the old receipt. *)
let test_operation_id_is_per_attempt () =
  let operation_id = Control.mint_operation_id () in
  let next_operation_id = Control.mint_operation_id () in
  let resume_body operation_id =
    Control.directive_body ~expected_workspace:directive_workspace
      ~operator_operation_id:operation_id "resume"
  in
  Alcotest.(check bool) "operation id is nonempty" true
    (String.trim operation_id <> "");
  Alcotest.(check bool) "a fresh attempt names a different receipt" false
    (String.equal operation_id next_operation_id);
  Alcotest.(check string) "the attempt reuses its id in a retry"
    (resume_body operation_id) (resume_body operation_id);
  Alcotest.(check bool) "a new attempt sends a different request" false
    (String.equal (resume_body operation_id) (resume_body next_operation_id))

(* {1 Roster completeness} *)

(* The route reports how many rows it returned and how many exist. When it
   returns fewer, the missing rows are missing for a reason it does not name --
   a clamped limit, or a keeper whose metadata it could not read -- and the
   keeper's fiber may be running either way.

   This is not hypothetical. On 2026-08-23 the live route answered
   [count: 0, total: 10] for ten keepers with running fibers, because the
   server could not parse their metadata. Reading that as a complete roster
   showed all ten as offline and offered to boot every one of them. *)
let test_short_roster_is_partial () =
  match
    Control.roster_view
      (Control.roster_of_reading ~errors:[] ~rows:[] ~truncated:false ~total:10)
  with
  | Control.Roster_partial { observed; total } ->
      Alcotest.(check int) "nothing observed" 0 (List.length observed);
      Alcotest.(check int) "ten exist" 10 total
  | Control.Roster_invalid _ | Control.Roster_complete _ ->
      Alcotest.fail "a roster short of its own total is not complete"
  | Control.Roster_unobserved -> Alcotest.fail "the route did answer"

let test_short_roster_reads_unread_not_offline () =
  let roster = Control.roster_of_reading ~errors:[] ~rows:[] ~truncated:false ~total:10 in
  let r = { Control.name = "analyst"; paused = false
          ; liveness = Control.liveness_of_roster roster "analyst" }
  in
  Alcotest.(check string) "unread, not offline" "unread"
    (Control.health_label ~ko:false r);
  check_actions "only deletion on an unread keeper" [ Control.Delete ] (Control.available r)

(* A refusal is two situations. Only one of them is fixed by providing a
   token, and the roster line used to give that advice for both. *)
let test_refusal_distinguishes_absent_from_rejected () =
  let has needle line = String_util.string_contains_substring ~needle line in
  let absent =
    Control.roster_failure_message ~credential_sent:false
      (Control.Roster_unauthorized Masc_tui_credential.Rejected)
  in
  let rejected =
    Control.roster_failure_message ~credential_sent:true
      (Control.Roster_unauthorized Masc_tui_credential.Rejected)
  in
  Alcotest.(check bool) "no bearer is named absent" true
    (has "holds no operator token" absent);
  Alcotest.(check bool) "no bearer is not called refused" false
    (has "was refused" absent);
  Alcotest.(check bool) "a sent bearer is named refused" true
    (has "was refused" rejected);
  Alcotest.(check bool) "a sent bearer is not called absent" false
    (has "holds no operator token" rejected);
  Alcotest.(check bool) "both name the command that mints one" true
    (has "masc login" absent && has "masc login" rejected);
  Alcotest.(check bool) "both keep the surface's own subject" true
    (has "live keeper status" absent && has "live keeper status" rejected);
  (* The server's typed code survives from the body to the line: an expired
     bearer is not reported as a generic refusal. *)
  (match
     Control.roster_failure_of_status ~status:401
       ~body:{|{"error":"[AuthError] Token expired","auth_error_code":"token_expired"}|}
   with
   | Control.Roster_unauthorized reason ->
       Alcotest.(check bool) "an expired bearer is said to have expired" true
         (has "has expired"
            (Control.roster_failure_message ~credential_sent:true
               (Control.Roster_unauthorized reason)))
   | Control.Roster_unreachable _ | Control.Roster_malformed _ ->
       Alcotest.fail "a 401 is a refusal");
  (match
     Control.roster_failure_of_status ~status:403
       ~body:{|{"error":"only your own queued message can be prioritized"}|}
   with
   | Control.Roster_unreachable detail ->
       Alcotest.(check bool) "a 403 without an auth code keeps the server's words" true
         (has "only your own" detail);
       Alcotest.(check bool) "and says the server answered with a 403" true
         (has "HTTP 403" detail)
   | Control.Roster_unauthorized _ | Control.Roster_malformed _ ->
       Alcotest.fail "a 403 without an auth code is not a credential refusal");
  (* The other failures say nothing about credentials either way. *)
  List.iter
    (fun credential_sent ->
      let line =
        Control.roster_failure_message ~credential_sent
          (Control.Roster_unreachable "connection refused")
      in
      Alcotest.(check bool) "an unreachable route keeps its own detail" true
        (has "connection refused" line);
      Alcotest.(check bool) "an unreachable route blames no credential" false
        (has "token" line))
    [ true; false ]

let test_truncated_roster_is_partial () =
  match
    Control.roster_view
      (Control.roster_of_reading ~errors:[] ~rows:[ runtime "analyst" ] ~truncated:true
        ~total:1)
  with
  | Control.Roster_partial { observed; _ } ->
      Alcotest.(check int) "the row it did return is kept" 1
        (List.length observed)
  | Control.Roster_invalid _ | Control.Roster_complete _ ->
      Alcotest.fail "a clamped roster is not complete"
  | Control.Roster_unobserved -> Alcotest.fail "the route did answer"

(* A row the incomplete roster did return still answers for its own keeper. *)
let test_partial_roster_still_confirms_what_it_holds () =
  let roster =
    Control.roster_of_reading ~errors:[] ~rows:[ runtime "analyst" ] ~truncated:false
      ~total:10
  in
  let present =
    { Control.name = "analyst"; paused = false
    ; liveness = Control.liveness_of_roster roster "analyst" }
  in
  Alcotest.(check string) "the observed keeper reports its health" "healthy"
    (Control.health_label ~ko:false present);
  check_actions "and it can be paused"
    [ Control.Pause; Control.Wakeup; Control.Shutdown; Control.Delete ]
    (Control.available present)

let test_full_roster_is_complete () =
  match
    Control.roster_view
      (Control.roster_of_reading ~errors:[] ~rows:[ runtime "analyst" ] ~truncated:false
        ~total:1)
  with
  | Control.Roster_complete rows ->
      Alcotest.(check int) "one row" 1 (List.length rows);
      let absent =
        { Control.name = "bandleader"; paused = false
        ; liveness = Control.liveness_of_roster (complete rows) "bandleader" }
      in
      (* "absent", not "unread": the roster answered and this keeper was not
         in it, which says no fiber is running it. *)
      Alcotest.(check string) "a name a complete roster omits is absent"
        "absent from live roster" (Control.health_label ~ko:false absent)
  | Control.Roster_invalid _ | Control.Roster_partial _ ->
      Alcotest.fail "a roster matching its own total is complete"
  | Control.Roster_unobserved -> Alcotest.fail "the route did answer"

let test_prepared_roster_first_duplicate_keeps_lifecycle () =
  let first = runtime ~keepalive_running:true ~runtime_id:"first-runtime" "analyst" in
  let later = runtime ~keepalive_running:false ~runtime_id:"later-runtime" "analyst" in
  let roster = complete [first; later] in
  let liveness = Control.liveness_of_roster roster "analyst" in
  (match liveness with
   | Control.Present observed ->
       Alcotest.(check string) "first runtime supplies the reading"
         first.kr_runtime_id observed.kr_runtime_id
   | Control.Absent | Control.Unobserved | Control.Invalid _ ->
       Alcotest.fail "the first observed runtime must remain present");
  check_actions "a later stopped duplicate cannot offer boot"
    [Control.Pause; Control.Wakeup; Control.Shutdown; Control.Delete]
    (Control.available (reading ~liveness "analyst"))

let test_prepared_roster_first_error_overrides_present_lifecycle () =
  let roster = Control.roster_of_reading
      ~errors:["analyst", "first error"; "analyst", "later error"]
      ~rows:[runtime "analyst"] ~truncated:false ~total:1 in
  let liveness = Control.liveness_of_roster roster "analyst" in
  (match liveness with
   | Control.Invalid detail ->
       Alcotest.(check string) "first source error is preserved" "first error" detail
   | Control.Absent | Control.Unobserved | Control.Present _ ->
       Alcotest.fail "configuration errors take precedence over observed rows");
  check_actions "an invalid runtime cannot authorize lifecycle changes"
    [Control.Delete] (Control.available (reading ~liveness "analyst"))

let test_prepared_roster_replacement_withdraws_live_decisions () =
  let previous = complete [runtime "analyst"] in
  let current = Control.roster_of_reading
      ~errors:[] ~rows:[] ~truncated:true ~total:1 in
  List.iter
    (fun roster ->
      let liveness = Control.liveness_of_roster roster "analyst" in
      Alcotest.(check bool) "a new unread observation borrows no old runtime" true
        (liveness = Control.Unobserved);
      check_actions "unconfirmed presence cannot offer boot or live control"
        [Control.Delete] (Control.available (reading ~liveness "analyst")))
    [current; Control.unobserved_roster];
  check_actions "the previous value still belongs to its original observation"
    [Control.Pause; Control.Wakeup; Control.Shutdown; Control.Delete]
    (Control.available (reading
       ~liveness:(Control.liveness_of_roster previous "analyst") "analyst"))

(* {1 Response classification} *)

let test_success_is_accepted () =
  match
    Control.classify_response ~status:200
      ~body:{|{"ok":true,"action":"shutdown","name":"analyst"}|}
  with
  | Control.Accepted { already_live } ->
      Alcotest.(check bool) "not already live" false already_live
  | Control.Purge_accepted _
  | Control.Committed_followup_failed _
  | Control.Paused_owner_conflict _
  | Control.Rejected _ ->
      Alcotest.fail "200 must be accepted"

let test_already_live_is_carried () =
  match
    Control.classify_response ~status:200
      ~body:{|{"ok":true,"action":"boot","name":"analyst","already_live":true}|}
  with
  | Control.Accepted { already_live } ->
      Alcotest.(check bool) "already live" true already_live
  | Control.Purge_accepted _
  | Control.Committed_followup_failed _
  | Control.Paused_owner_conflict _
  | Control.Rejected _ ->
      Alcotest.fail "200 must be accepted"

let test_committed_followup_failed_is_distinguished_from_accepted () =
  match
    Control.classify_response ~status:202
      ~body:
        {|{"ok":false,"action":"resume","operation":"resume_owner","name":"analyst","committed":true,"commit_status":"committed","projection":"committed_followup_failed","error":"live Keeper registry entry is missing"}|}
  with
  | Control.Committed_followup_failed detail ->
      Alcotest.(check string)
        "carries the server's followup failure detail"
        "live Keeper registry entry is missing"
        detail
  | Control.Accepted _
  | Control.Purge_accepted _
  | Control.Paused_owner_conflict _
  | Control.Rejected _ ->
      Alcotest.fail "202 committed_followup_failed must not be classified as Accepted"

let test_conflict_is_its_own_outcome () =
  match
    Control.classify_response ~status:409
      ~body:
        {|{"ok":false,"error":"keeper is operator-paused; commit Resume_owner through the directive endpoint"}|}
  with
  | Control.Paused_owner_conflict detail ->
      Alcotest.(check bool)
        "detail is the server's" true
        (String.length detail > 0
        && not (String.equal detail "HTTP 409"))
  | Control.Accepted _ | Control.Purge_accepted _
  | Control.Committed_followup_failed _ ->
      Alcotest.fail "409 is not an acceptance"
  | Control.Rejected _ -> Alcotest.fail "409 has its own outcome"

let test_workspace_conflict_is_rejected_not_paused_owner () =
  match
    Control.classify_response ~status:409
      ~body:
        {|{"ok":false,"code":"workspace_precondition_failed","error":"workspace precondition failed"}|}
  with
  | Control.Rejected { status; detail } ->
      Alcotest.(check int) "status" 409 status;
      Alcotest.(check string) "detail" "workspace precondition failed" detail
  | Control.Accepted _
  | Control.Purge_accepted _
  | Control.Committed_followup_failed _
  | Control.Paused_owner_conflict _ ->
      Alcotest.fail "workspace mismatch 409 must not trigger paused-owner recovery"

let test_boot_phase_conflict_is_rejected_not_paused_owner () =
  match
    Control.classify_response ~status:409
      ~body:
        {|{"ok":false,"code":"keeper_boot_phase_conflict","error":"keeper is currently draining; wait for the transition to settle before booting"}|}
  with
  | Control.Rejected { status; detail } ->
      Alcotest.(check int) "status" 409 status;
      Alcotest.(check string)
        "detail"
        "keeper is currently draining; wait for the transition to settle before booting"
        detail
  | Control.Accepted _
  | Control.Purge_accepted _
  | Control.Committed_followup_failed _
  | Control.Paused_owner_conflict _ ->
      Alcotest.fail "boot phase conflict 409 must not trigger paused-owner recovery"

(* A 400 whose prose mentions pausing must stay a rejection. Routing on the
   words instead of the status is how a rejected request gets retried as a
   resume. *)
let test_rejection_prose_does_not_become_a_conflict () =
  match
    Control.classify_response ~status:400
      ~body:{|{"ok":false,"error":"resume requires string \"operator_operation_id\""}|}
  with
  | Control.Rejected { status; detail } ->
      Alcotest.(check int) "status" 400 status;
      Alcotest.(check bool)
        "detail is the server's error" true
        (String.length detail > 0 && not (String.equal detail "HTTP 400"))
  | Control.Accepted _
  | Control.Purge_accepted _
  | Control.Committed_followup_failed _
  | Control.Paused_owner_conflict _ ->
      Alcotest.fail "400 is a rejection"

let test_non_json_error_keeps_its_text () =
  match
    Control.classify_response ~status:502 ~body:"upstream closed the connection"
  with
  | Control.Rejected { status; detail } ->
      Alcotest.(check int) "status" 502 status;
      Alcotest.(check string)
        "text survives" "upstream closed the connection" detail
  | Control.Accepted _
  | Control.Purge_accepted _
  | Control.Committed_followup_failed _
  | Control.Paused_owner_conflict _ ->
      Alcotest.fail "502 is a rejection"

let test_empty_error_body_names_the_status () =
  match Control.classify_response ~status:503 ~body:"" with
  | Control.Rejected { detail; _ } ->
      Alcotest.(check string) "status stands in" "HTTP 503" detail
  | Control.Accepted _
  | Control.Purge_accepted _
  | Control.Committed_followup_failed _
  | Control.Paused_owner_conflict _ ->
      Alcotest.fail "503 is a rejection"

(* {1 Roster decode} *)

(* [meta] carries the keeper's own declaration, and the roster row reads the
   sandbox profile out of it. The fixture shipped without [meta] while nothing
   read it; leaving it out now would only mean the decoder had learned to do
   without a field the server always sends. *)
let gate_row ?(health = "healthy") ?(paused = false)
    ?(next_action = "\"direct_message\"") ?(phase = "running")
    ?(sandbox_profile = "docker") name =
  Printf.sprintf
    {|{"runtime_class":"keeper","name":%S,"agent_name":"keeper-%s-agent",
       "meta":{"name":%S,"trace_id":"trace-1","created_at":"2026-08-21T17:32:29Z",
               "updated_at":"2026-08-23T06:53:43Z","sandbox_profile":%S},
       "health":%S,"paused":%b,"next_action":%s,"runtime_blocker_summary":null,
       "candle_balance_milli":null,"candle_account_revision":null,"portrait":{"state":"ready","equipment":{"face":"bare_face","neck":"bare_neck","head":"bare_head","hand":"empty_hand","base":"no_dish"}},
       "phase":%S,"keepalive_running":true,"activation_mode":"autonomous","runtime_id":"anthropic.claude-opus-5-5",
       "created_at":"2026-08-21T17:32:29Z","updated_at":"2026-08-23T06:53:43Z"}|}
    name name name sandbox_profile health paused next_action phase

(* The roster is where an operator compares keepers, so the sandbox each one is
   declared for has to survive the decode. Reading it per keeper from a detail
   pane was the thing this replaced. *)
let test_remote_identity_failure_preserves_observed_controls () =
  let row = Yojson.Safe.from_string (gate_row "analyst") in
  let fields = match row with `Assoc fields -> fields | _ -> assert false in
  let metadata = match List.assoc "meta" fields with
    | `Assoc fields -> fields | _ -> assert false in
  let decode metadata =
    let row = `Assoc (("meta", `Assoc metadata) :: List.remove_assoc "meta" fields) in
    match Decode.decode_keeper_runtime_list (`Assoc [
      "candle", `Assoc ["status", `String "off"]; "keepers", `List [row];
      "total", `Int 1; "truncated", `Bool false]) with
    | Ok ([runtime], [], false, 1, _) -> runtime
    | Ok _ -> Alcotest.fail "remote row was hidden"
    | Error reason -> Alcotest.fail reason
  in
  let runtime = decode metadata in
  let keeper = Decode.keeper_of_runtime runtime in
  Alcotest.(check (result string identity_absence)) "canonical server trace" (Ok "trace-1")
    (Decode.keeper_trace_id keeper);
  Alcotest.(check bool) "public roster never invents activity" true
    (Option.is_none keeper.k_activity);
  List.iter (fun metadata ->
    let runtime = decode metadata in
    let keeper = Decode.keeper_of_runtime runtime in
    Alcotest.(check bool) "invalid identity is explicit" true
      (Result.is_error keeper.k_identity);
    let reason = match keeper.k_identity with
      | Error (Decode.Identity_unreadable _ as reason) -> reason
      | Error Decode.Keeper_not_started ->
          Alcotest.fail "a roster row is not a Keeper that has not started"
      | Ok _ -> Alcotest.fail "invalid identity unexpectedly succeeded" in
    Alcotest.(check (result string identity_absence)) "original identity failure survives"
      (Error reason) (Decode.keeper_trace_id keeper);
    let projection = Decode.keeper_trace_projection [keeper] in
    Alcotest.(check (list (pair string string))) "invalid identity cannot bind events" [] projection.bindings;
    Alcotest.(check (list (pair string identity_absence))) "named failure remains readable"
      [keeper.k_name, reason] projection.unavailable;
    let valid = Decode.keeper_of_runtime (decode (match row with
      | `Assoc fields -> (match List.assoc "meta" fields with
          | `Assoc fields -> fields
          | _ -> Alcotest.fail "metadata fixture is not an object")
      | _ -> Alcotest.fail "roster fixture is not an object")) in
    let mixed = Decode.keeper_trace_projection [valid; keeper] in
    Alcotest.(check (list (pair string string))) "valid correlation survives beside failure"
      [valid.k_name, "trace-1"] mixed.bindings;
    Alcotest.(check (list (pair string identity_absence))) "failure not hidden by valid correlation"
      [keeper.k_name, reason] mixed.unavailable;
    let reading = reading ~liveness:(Control.Present runtime) keeper.k_name in
    check_actions "independently valid lifecycle remains actionable"
      [Control.Pause; Control.Wakeup; Control.Shutdown; Control.Delete]
      (Control.available reading))
    [ List.remove_assoc "trace_id" metadata;
      ("trace_id", `String "../other") :: List.remove_assoc "trace_id" metadata;
      ("name", `String "other") :: List.remove_assoc "name" metadata ]

let test_roster_equipment_is_required_and_failures_stay_per_keeper () =
  let row = Yojson.Safe.from_string (gate_row "analyst") in
  let with_portrait portrait = match row with
    | `Assoc fields -> `Assoc (("portrait",portrait) :: List.remove_assoc "portrait" fields)
    | _ -> Alcotest.fail "bad row fixture" in
  let decode row = Decode.decode_keeper_runtime_list (`Assoc ["candle",`Assoc ["status",`String "off"];"keepers",`List [row];"total",`Int 1;"truncated",`Bool false]) in
  let equipped = {Keeper_portrait_look.bare with head=Keeper_portrait_look.Crown} in
  let ready = Keeper_portrait_equipment.reading_to_json (Keeper_portrait_equipment.Ready equipped) in
  (match decode (with_portrait ready) with
   | Ok ([runtime],_,_,_, _) -> Alcotest.(check bool) "actual server gear survives" true (runtime.Decode.kr_portrait=Decode.Ready equipped)
   | _ -> Alcotest.fail "equipped row failed");
  let unavailable = Keeper_portrait_equipment.reading_to_json (Keeper_portrait_equipment.Unavailable "ledger unreadable") in
  (match decode (with_portrait unavailable) with
   | Ok ([runtime],[],_,_, _) -> Alcotest.(check bool) "portrait failure does not discard Keeper" true
       (runtime.Decode.kr_portrait=Decode.Unavailable "ledger unreadable")
   | _ -> Alcotest.fail "portrait failure hid Keeper");
  List.iter (fun invalid -> Alcotest.(check bool) "malformed portrait is never synthesized from name" true
    (Result.is_error (decode (with_portrait invalid)))) [`Null;`Assoc ["state",`String "ready"];
      `Assoc ["state",`String "ready";"equipment",`Assoc ["head",`String "unknown"]]];
  match row with
  | `Assoc fields -> Alcotest.(check bool) "missing snapshot rejected" true
      (Result.is_error (decode (`Assoc (List.remove_assoc "portrait" fields))))
  | _ -> Alcotest.fail "bad row fixture"

(* An empty fold: a ready Candle with no wallet yet. *)
let empty_basis =
  `Assoc ["issued_milli", `String "0"; "burned_milli", `String "0";
    "half_life", `Null; "keepers", `List []]

let candle_envelope ?decay candle rows =
  let decay = match decay, Yojson.Safe.Util.member "status" candle with
    | Some decay, _ -> decay
    | None, `String "ready" -> empty_basis
    | None, _ -> `Null in
  `Assoc ["candle", candle; "candle_decay", decay; "keepers", `List rows;
    "total", `Int (List.length rows); "truncated", `Bool false]

let test_item_revision_hint_preserves_keeper_observation () =
  let row = Yojson.Safe.from_string (gate_row "analyst") in
  let decode ~candle value =
    let row = match row with
      | `Assoc fields -> `Assoc (("candle_account_revision", value)
          :: List.remove_assoc "candle_account_revision" fields)
      | _ -> Alcotest.fail "bad Keeper fixture" in
    match Decode.decode_keeper_runtime_list (candle_envelope candle [row]) with
    | Ok ([runtime], [], false, 1, _) -> runtime
    | _ -> Alcotest.fail "Item revision reading hid the Keeper"
  in
  let ready = `Assoc ["status", `String "ready"; "issued_milli", `String "0";
    "burned_milli", `String "0"; "circulating_milli", `String "0"] in
  let off = `Assoc ["status", `String "off"] in
  let digest = String.make 64 'a' in
  Alcotest.(check bool) "canonical ready revision decoded" true
    ((decode ~candle:ready (`String digest)).kr_candle_account_revision = Ok (Some digest));
  let disabled = `Assoc ["status", `String "disabled";
    "reason", `String "fixture ledger unavailable"] in
  Alcotest.(check bool) "disabled revision decoded" true
    ((decode ~candle:disabled (`String digest)).kr_candle_account_revision = Ok (Some digest));
  Alcotest.(check bool) "null authorizes only observed Off" true
    ((decode ~candle:off `Null).kr_candle_account_revision = Ok None);
  List.iter (fun (runtime : Decode.keeper_runtime) ->
    Alcotest.(check bool) "invalid authority reported independently" true
      (Result.is_error runtime.kr_candle_account_revision);
    let roster = complete [runtime] in
    Alcotest.(check bool) "invalid authority retains lifecycle controls" true
      (List.mem Control.Shutdown
        (Control.available (reading ~liveness:(Control.liveness_of_roster roster "analyst") "analyst"))))
    (decode ~candle:off (`String digest)
     :: List.map (decode ~candle:ready)
          [`Null; `Int 1; `String "short"; `String (String.make 64 'A')])

(* RFC-0481 §3.7: a ready Candle comes with the fold's basis and the other two
   come without one. Any other pairing is a Candle failure that keeps the
   Keeper rows and their lifecycle actions. *)
let test_roster_candle_reading_pairs_status_and_basis () =
  let ready = `Assoc ["status",`String "ready"; "issued_milli",`String "1000";
    "burned_milli",`String "200"; "circulating_milli",`String "800"] in
  let disabled = `Assoc ["status",`String "disabled";"reason",`String "ledger unreadable"] in
  let off = `Assoc ["status",`String "off"] in
  let wallet = `Assoc ["issued_milli",`String "1000"; "burned_milli",`String "200";
    "half_life",`Int 24; "keepers",`List [`Assoc ["name",`String "analyst";
      "since",`String "2026-09-29T00:00:00Z"; "amount_milli",`String "800"]]] in
  let row candle = match Yojson.Safe.from_string (gate_row "analyst") with
    | `Assoc fields ->
      let revision = match Yojson.Safe.Util.member "status" candle with
        | `String "off" -> `Null | _ -> `String (String.make 64 'a') in
      `Assoc (("candle_account_revision",revision)::List.remove_assoc "candle_account_revision" fields)
    | _ -> Alcotest.fail "bad Keeper fixture" in
  let decode ?decay candle = Decode.decode_keeper_runtime_list (candle_envelope ?decay candle [row candle]) in
  (match decode ~decay:wallet ready with
   | Ok ([_],[],false,1,Ok (Decode.Candle_ready basis)) ->
     Alcotest.(check bool) "the basis holds the wallet" true
       (match basis.Candle_decay_basis.decay with
        | Candle_decay_basis.Decaying { keepers = [ ("analyst", held) ]; _ } ->
          held.Candle_decay_basis.amount_milli = 800
        | Candle_decay_basis.Decaying _ | Candle_decay_basis.No_decaying_balance -> false)
   | _ -> Alcotest.fail "a ready Candle with its basis was rejected");
  (match decode disabled with
   | Ok ([_],[],_,_,Ok (Decode.Candle_disabled reason)) ->
     Alcotest.(check string) "failure survives" "ledger unreadable" reason
   | _ -> Alcotest.fail "disabled Candle hid the Keeper");
  (match decode off with
   | Ok ([_],[],_,_,Ok Decode.Candle_off) -> ()
   | _ -> Alcotest.fail "Candle off was not read");
  List.iter (fun (label, json) ->
      match Decode.decode_keeper_runtime_list json with
      | Ok (rows, errors, truncated, total, Error detail) ->
        Alcotest.(check bool) (label ^ ": the failure says why") true (String.length detail > 0);
        let roster = Control.roster_of_reading ~rows ~errors ~truncated ~total in
        Alcotest.(check bool) (label ^ ": the Keeper keeps its actions") true
          (List.mem Control.Shutdown
             (Control.available (reading ~liveness:(Control.liveness_of_roster roster "analyst") "analyst")))
      | Ok (_,_,_,_,Ok _) -> Alcotest.fail (label ^ ": became a valid Candle reading")
      | Error detail -> Alcotest.failf "%s: hid the Keeper roster: %s" label detail)
    [ "ready without its basis", candle_envelope ~decay:`Null ready [row ready]
    ; "off with a basis", candle_envelope ~decay:wallet off [row off]
    ; "a basis that is not an object", candle_envelope ~decay:(`String "basis") ready [row ready]
    ; "a malformed basis", candle_envelope ~decay:(`Assoc ["issued_milli",`String "01"]) ready [row ready] ]

let test_roster_decode_reads_the_sandbox_profile () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{"candle":{"status":"off"},"count":2,"total":2,"truncated":false,"keepers":[%s,%s]}|}
         (gate_row ~sandbox_profile:"docker" "contained")
         (gate_row ~sandbox_profile:"local" "on-the-host"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Error detail -> Alcotest.failf "roster must decode: %s" detail
  | Ok (rows, _, _, _, _) ->
      Alcotest.(check (list string))
        "each row keeps its own declaration"
        [ "docker"; "local" ]
        (List.map (fun (r : Decode.keeper_runtime) -> r.kr_sandbox_profile) rows)

(* Paused and phase are two readings, not one word said twice, and the roster
   cell now draws the first in place of the second. On the live gate two of
   sixteen keepers report phase offline with paused true while a third
   reports offline with paused false -- the difference between a keeper a
   person stopped and one that fell over, which "offline" alone cannot say.
   The decode has to keep them apart for the cell to have anything to draw. *)
let test_roster_decode_keeps_paused_apart_from_phase () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{"candle":{"status":"off"},"count":2,"total":2,"truncated":false,"keepers":[%s,%s]}|}
         (gate_row ~paused:true ~phase:"offline" "stopped-by-a-person")
         (gate_row ~paused:false ~phase:"offline" "fell-over"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Error detail -> Alcotest.failf "roster must decode: %s" detail
  | Ok (rows, _, _, _, _) ->
      Alcotest.(check (list bool))
        "the pause reading is per row"
        [ true; false ]
        (List.map (fun (r : Decode.keeper_runtime) -> r.kr_paused) rows);
      Alcotest.(check (list string))
        "and the phase agrees on both, which is the point"
        [ "offline"; "offline" ]
        (List.map
           (fun (r : Decode.keeper_runtime) ->
             Decode.keeper_phase_to_string r.kr_phase)
           rows)

(* A row without the field is a server that stopped sending it, which is worth
   a loud decode failure rather than a row that silently reads as local. The
   boundary is the thing being reported; guessing it defeats the report. *)
let test_a_row_without_a_sandbox_profile_is_rejected () =
  let json =
    Yojson.Safe.from_string
      {|{"candle":{"status":"off"},"count":1,"total":1,"truncated":false,"keepers":[
         {"runtime_class":"keeper","name":"n","agent_name":"keeper-n-agent",
          "meta":{"name":"n","trace_id":"t","created_at":"c","updated_at":"u"},
          "candle_balance_milli":null,"candle_account_revision":null,"portrait":{"state":"ready","equipment":{"face":"bare_face","neck":"bare_neck","head":"bare_head","hand":"empty_hand","base":"no_dish"}},
          "health":"healthy","paused":false,"next_action":null,
          "phase":"running","keepalive_running":true,"activation_mode":"autonomous","runtime_id":"r",
          "created_at":"c","updated_at":"u"}]}|}
  in
  match Decode.decode_keeper_runtime_list json with
  | Ok _ -> Alcotest.fail "a row with no sandbox_profile must not decode"
  | Error detail ->
      Alcotest.(check bool)
        "and the failure names the field" true
        (let needle = "sandbox_profile" in
         let n = String.length needle and l = String.length detail in
         let rec go i = i + n <= l && (String.sub detail i n = needle || go (i + 1)) in
         go 0)

let test_roster_decode_reads_rows () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"candle":{"status":"off"},"count":2,"total":2,"truncated":false,"keepers":[%s,%s]}|}
         (gate_row "analyst")
         (gate_row ~health:"idle" "bandleader"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Error err -> Alcotest.fail ("roster must decode: " ^ err)
  | Ok (rows, _, truncated, total, _) ->
      Alcotest.(check int) "two rows" 2 (List.length rows);
      Alcotest.(check bool) "not truncated" false truncated;
      Alcotest.(check int) "total" 2 total;
      Alcotest.(check (list string))
        "names in order" [ "analyst"; "bandleader" ]
        (List.map (fun (row : Decode.keeper_runtime) -> row.kr_name) rows);
      Alcotest.(check bool)
        "health parsed" true
        (match rows with
         | [ _; second ] ->
           Decode.keeper_health_reading second.Decode.kr_health = Decode.Health_idle
         | _ -> false);
      Alcotest.(check bool)
        "phase parsed" true
        (match rows with
         | first :: _ ->
           Decode.keeper_phase_to_string first.Decode.kr_phase = "running"
         | [] -> false)

(* A producer that grows a health reading this build does not know must fail
   the reading. A default would render the new state as one of the known ones
   and offer the action that belongs to that one instead. *)
let test_roster_decode_rejects_an_unknown_status () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"candle":{"status":"off"},"keepers":[%s]}|}
         (gate_row ~health:"quarantined" "analyst"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Ok _ -> Alcotest.fail "an unknown health must not decode"
  | Error err ->
      Alcotest.(check bool)
        "error names the health" true
        (let contains needle =
           let n = String.length needle and h = String.length err in
           let rec scan i = i + n <= h && (String.sub err i n = needle || scan (i + 1)) in
           scan 0
         in
         contains "quarantined")

let test_roster_decode_rejects_an_unknown_phase () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"candle":{"status":"off"},"keepers":[%s]}|}
         (gate_row ~phase:"teleporting" "analyst"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Ok _ -> Alcotest.fail "an unknown phase must not decode"
  | Error err ->
      Alcotest.(check string)
        "error names keeper and phase"
        {|keepers[0]: keeper "analyst" has unknown lifecycle phase "teleporting"|}
        err

(* A detail-less error is retained as unavailable, never a runtime snapshot. *)
let error_row name = Printf.sprintf
    {|{"status":"error","runtime_class":"keeper","name":%S,
       "keepalive_running":false,"candle_balance_milli":null,"candle_account_revision":null,
       "meta":null,"created_at":null,"updated_at":null}|}
    name

let test_roster_decodes_an_error_row_without_refusing_the_rest () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"candle":{"status":"off"},"keepers":[%s,%s]}|}
         (gate_row "healthy-one")
         (error_row "broken-meta"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Error detail -> Alcotest.failf "roster must decode past an error row: %s" detail
  | Ok (rows, errors, _, _, _) ->
      Alcotest.(check int) "only observed runtime rows survive" 1 (List.length rows);
      Alcotest.(check (list (pair string string))) "missing metadata stays an error"
        ["broken-meta", "Keeper metadata unavailable; the server supplied no error detail"] errors;
      Alcotest.(check string) "healthy row retained" "healthy-one" (List.hd rows).Decode.kr_name

(* The row's [runtime_path_rest] is the walk the heartbeat waits on. A
   resting walk keeps the time it releases and who set it. A malformed rest is
   an error beside a row that still decodes. *)
let test_roster_decodes_the_walk_rest_beside_the_row () =
  let decode rest =
    let fields =
      match Yojson.Safe.from_string (gate_row "rester") with
      | `Assoc fields -> fields
      | _ -> Alcotest.fail "the fixture row is an object"
    in
    let row = `Assoc (fields @ [ "runtime_path_rest", rest ]) in
    match
      Decode.decode_keeper_runtime_list
        (`Assoc
           [ "candle", `Assoc [ "status", `String "off" ]; "keepers", `List [ row ]
           ; "total", `Int 1; "truncated", `Bool false ])
    with
    | Ok ([ runtime ], [], false, 1, _) -> runtime.Decode.kr_runtime_path_rest
    | Ok _ -> Alcotest.fail "the row was hidden"
    | Error reason -> Alcotest.fail reason
  in
  let path = "glm.glm-5" in
  let resting fields =
    `Assoc ([ "status", `String "resting"; "runtime_id", `String path ] @ fields)
  in
  let release_at at = "release_at", at in
  let stated = "release_basis", `String "stated_by_provider" in
  Alcotest.(check bool) "a serving walk names its head" true
    (decode (`Assoc [ "status", `String "serving"; "runtime_id", `String path ])
     = Ok (Some (Decode.Path_rest_serving { runtime_id = path })));
  Alcotest.(check bool) "a resting walk keeps its release and who set it" true
    (decode (resting [ release_at (`Float 1_790_000_000.5); stated ])
     = Ok
         (Some
            (Decode.Path_rest_resting
               { runtime_id = path
               ; release_at = 1_790_000_000.5
               ; release_basis = Decode.Stated_by_provider
               })));
  Alcotest.(check bool) "a whole-second release is read as a time" true
    (decode
       (resting [ release_at (`Int 1_790_000_000); "release_basis", `String "bounded_by_masc" ])
     = Ok
         (Some
            (Decode.Path_rest_resting
               { runtime_id = path
               ; release_at = 1_790_000_000.
               ; release_basis = Decode.Bounded_by_masc
               })));
  Alcotest.(check bool) "a null rest is no reading" true (decode `Null = Ok None);
  List.iter
    (fun (label, rest) -> Alcotest.(check bool) label true (Result.is_error (decode rest)))
    [ "a rest that is not an object is an error", `String "resting"
    ; "an unknown status is an error", `Assoc [ "status", `String "asleep"; "runtime_id", `String path ]
    ; "a resting walk without a release is an error", resting [ stated ]
    ; "a release that is not a number is an error", resting [ release_at (`String "soon"); stated ]
    ; "a release that is not finite is an error", resting [ release_at (`Float infinity); stated ]
    ; "a release that is not a number at all is an error", resting [ release_at (`Float nan); stated ]
    ; ( "a finite release no local calendar holds is an error"
      , resting [ release_at (`Float 1e300); stated ] )
    ; "a resting walk without a basis is an error", resting [ release_at (`Float 1_790_000_000.) ]
    ; ( "an unknown basis is an error"
      , resting [ release_at (`Float 1_790_000_000.); "release_basis", `String "guessed" ] )
    ]
;;

let test_roster_decodes_operator_disposition_beside_the_row () =
  let decode disp reason =
    let fields =
      match Yojson.Safe.from_string (gate_row "disposition_keeper") with
      | `Assoc fields -> fields
      | _ -> Alcotest.fail "the fixture row is an object"
    in
    let row =
      `Assoc
        (fields
        @ [ "operator_disposition", disp; "operator_disposition_reason", reason ])
    in
    match
      Decode.decode_keeper_runtime_list
        (`Assoc
           [ "candle", `Assoc [ "status", `String "off" ]; "keepers", `List [ row ]
           ; "total", `Int 1; "truncated", `Bool false ])
    with
    | Ok ([ runtime ], [], false, 1, _) -> runtime.Decode.kr_operator_disposition
    | Ok _ -> Alcotest.fail "the row was hidden"
    | Error reason -> Alcotest.fail reason
  in
  Alcotest.(check bool) "null pair decodes to Ok None" true
    (decode `Null `Null = Ok None);
  Alcotest.(check bool) "valid typed pair decodes to Ok (Some (kind, reason))" true
    (decode (`String "operator_action_required") (`String "config_invalid")
     = Ok
         (Some
            ( Masc.Keeper_execution_receipt.Disp_operator_action_required
            , Masc.Keeper_execution_receipt.Reason_config_invalid )));
  Alcotest.(check bool) "unknown disposition kind is Error" true
    (Result.is_error (decode (`String "magic_action") (`String "config_invalid")));
  Alcotest.(check bool) "unknown reason is Error" true
    (Result.is_error (decode (`String "operator_action_required") (`String "magic_reason")));
  Alcotest.(check bool) "asymmetric null/string is Error" true
    (Result.is_error (decode `Null (`String "config_invalid")))
;;

let test_roster_decodes_failing_since () =
  let decode failing_since =
    let fields =
      match Yojson.Safe.from_string (gate_row "failing_keeper") with
      | `Assoc fields -> fields
      | _ -> Alcotest.fail "the fixture row is an object"
    in
    let row = `Assoc (fields @ [ "failing_since", failing_since ]) in
    match
      Decode.decode_keeper_runtime_list
        (`Assoc
           [ "candle", `Assoc [ "status", `String "off" ]; "keepers", `List [ row ]
           ; "total", `Int 1; "truncated", `Bool false ])
    with
    | Ok ([ runtime ], [], false, 1, _) -> runtime.Decode.kr_failing_since
    | Ok _ -> Alcotest.fail "the row was hidden"
    | Error reason -> Alcotest.fail reason
  in
  Alcotest.(check (option (float 0.001))) "null failing_since is None" None (decode `Null);
  Alcotest.(check (option (float 0.001))) "numeric failing_since is Some" (Some 1794050000.0)
    (decode (`Float 1794050000.0))
;;

let test_roster_decodes_recent_turns () =
  let decode recent_turns =
    let fields =
      match Yojson.Safe.from_string (gate_row "pulse_keeper") with
      | `Assoc fields -> fields
      | _ -> Alcotest.fail "the fixture row is an object"
    in
    let row = `Assoc (fields @ [ "recent_turns", recent_turns ]) in
    match
      Decode.decode_keeper_runtime_list
        (`Assoc
           [ "candle", `Assoc [ "status", `String "off" ]; "keepers", `List [ row ]
           ; "total", `Int 1; "truncated", `Bool false ])
    with
    | Ok ([ runtime ], [], false, 1, _) -> runtime.Decode.kr_recent_turns
    | Ok _ -> Alcotest.fail "the row was hidden"
    | Error reason -> Alcotest.fail reason
  in
  Alcotest.(check bool) "null recent_turns is None" true (decode `Null = None);
  let slot starts_at ok rested failed = `List [ `Int starts_at; `Int ok; `Int rested; `Int failed ] in
  let wire ?(known_since = `Float 1794030000.0) slots =
    `Assoc [ "known_since", known_since; "slots", `List slots ]
  in
  (match decode (wire [ slot 1794036600 2 0 1; slot 1794034800 0 1 0 ]) with
   | None -> Alcotest.fail "expected decoded recent_turns"
   | Some pulse ->
     Alcotest.(check (float 0.001)) "known since" 1794030000.0 pulse.known_since;
     Alcotest.(check (list (pair int (triple int int int))))
       "slots newest first with their counts"
       [ 1794036600, (2, 0, 1); 1794034800, (0, 1, 0) ]
       (List.map
          (fun ({ starts_at; tally = { ok; rested; failed } } : Masc.Keeper_turn_pulse.slot) ->
            starts_at, (ok, rested, failed))
          pulse.slots));
  Alcotest.(check bool) "a slot that does not decode drops the pulse" true
    (decode (wire [ slot 1794036600 1 0 0; `List [ `Int 1794034800; `String "ok" ] ]) = None);
  Alcotest.(check bool) "a negative count drops the pulse" true
    (decode (wire [ slot 1794036600 (-1) 0 0 ]) = None);
  Alcotest.(check bool) "a missing known_since drops the pulse" true
    (decode (`Assoc [ "slots", `List [] ]) = None);
  Alcotest.(check bool) "the old turns shape is not read" true
    (decode (`Assoc [ "truncated", `Bool false; "turns", `List [] ]) = None)
;;

let test_actual_producer_error_is_isolated () =
  let producer_row = Yojson.Safe.from_string
    {|{"status":"error","runtime_class":"keeper","name":"broken-meta",
       "keepalive_running":false,"candle_balance_milli":null,"candle_account_revision":null,"meta":null,"created_at":null,"updated_at":null,
       "effective_meta_error":{"keeper":"broken-meta","message":"metadata unreadable",
       "terminal_reason":"effective_meta_read_failed","severity":"error",
       "operator_action_required":true,"next_action":"fix_keeper_toml_or_keeper_instructions"}}|} in
  let json = `Assoc ["candle",`Assoc ["status",`String "off"];"keepers", `List [Yojson.Safe.from_string (gate_row "healthy-one"); producer_row]] in
  match Decode.decode_keeper_runtime_list json with
  | Error message -> Alcotest.fail message
  | Ok (rows, errors, _, _, _) ->
    Alcotest.(check int) "healthy Keeper remains visible" 1 (List.length rows);
    Alcotest.(check (list (pair string string))) "producer error retained verbatim"
      ["broken-meta", "metadata unreadable"] errors

(* Present-but-unknown health stays a refusal even though an absent one now
   falls back: the fallback is for readings that do not exist, not for
   vocabulary this build has not learned. *)
let test_roster_decode_rejects_present_unknown_health_on_error_row () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"candle":{"status":"off"},"keepers":[%s]}|} (error_row "broken-meta"))
  in
  let json_with_bad_health =
    match json with
    | `Assoc fields ->
        let keepers =
          List.find (fun (k, _) -> String.equal k "keepers") fields
          |> snd
        in
        (match keepers with
         | `List [ `Assoc row ] ->
             `Assoc
               (("keepers", `List [ `Assoc (("health", `String "quarantined") :: row) ])
                :: List.filter (fun (k, _) -> not (String.equal k "keepers")) fields)
         | _ -> json)
    | _ -> json
  in
  match Decode.decode_keeper_runtime_list json_with_bad_health with
  | Ok _ -> Alcotest.fail "a present unknown health must not decode"
  | Error _ -> ()

let present ?(health = health "healthy") ?(paused = false) name =
  { Control.name
  ; paused
  ; liveness = Control.Present (runtime ~health name)
  }

(* Pausing is a person's decision and health is an observation. Folding one
   into the other is what [status_label] does, and it would make a paused
   keeper whose keepalive is gone read the same as one that is resting. *)
let test_pause_does_not_hide_health () =
  let paused_offline =
    present ~health:(health "offline") ~paused:true "stopped-and-gone"
  in
  Alcotest.(check string)
    "a paused keeper still reports the health underneath"
    "offline"
    (Control.health_label ~ko:false paused_offline);
  Alcotest.(check bool) "and still reports being paused" true
    paused_offline.Control.paused

(* The row publishes four separate readings, and the decoder has to keep them
   separate. A null action is the runtime naming none, which is not an action
   meaning "nothing to do"; an unknown one is this build not being able to
   spell it, which is not the same as none either. *)
let test_roster_decode_keeps_the_axes_apart () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"candle":{"status":"off"},"count":1,"total":1,"truncated":false,"keepers":[%s]}|}
         (gate_row ~health:"offline" ~paused:true
            ~next_action:{|"recover"|} "wreck"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Error err -> Alcotest.fail ("roster must decode: " ^ err)
  | Ok ([ row ], _, _, _, _) ->
      Alcotest.(check bool) "health survives the surface fold" true
        (Decode.keeper_health_reading row.Decode.kr_health = Decode.Health_offline);
      Alcotest.(check bool) "pause is its own field" true row.Decode.kr_paused;
      Alcotest.(check bool) "the action is carried" true
        (row.Decode.kr_next_action
         = Some Masc.Keeper_status_runtime.Recover)
  | Ok (rows, _, _, _, _) ->
      Alcotest.failf "expected one row, got %d" (List.length rows)

(* A keeper in the Failing phase publishes health "failing". The roster reads
   it as its own reading rather than rejecting the row, the column says
   failing, and the action the server derived for it is probe. Its keepalive
   still runs, so it offers what a running keeper offers. *)
let test_roster_decode_reads_a_failing_keeper () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"candle":{"status":"off"},"count":1,"total":1,"truncated":false,"keepers":[%s]}|}
         (gate_row ~health:"failing" ~phase:"failing"
            ~next_action:{|"probe"|} "retro"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Error err -> Alcotest.fail ("a failing keeper's row must decode: " ^ err)
  | Ok ([ row ], _, _, _, _) ->
      Alcotest.(check bool) "health is the failing reading" true
        (Decode.keeper_health_reading row.Decode.kr_health
         = Decode.Health_failing);
      Alcotest.(check bool) "the action is probe" true
        (row.Decode.kr_next_action
         = Some Masc.Keeper_status_runtime.Probe);
      let r =
        { Control.name = "retro"; paused = false; liveness = Control.Present row }
      in
      Alcotest.(check string) "the column says failing" "failing"
        (Control.health_label ~ko:false r);
      check_actions "a running keeper's actions"
        [ Control.Pause; Control.Wakeup; Control.Shutdown; Control.Delete ]
        (Control.available r)
  | Ok (rows, _, _, _, _) ->
      Alcotest.failf "expected one row, got %d" (List.length rows)

let test_roster_decode_null_action_is_none () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"candle":{"status":"off"},"count":1,"total":1,"truncated":false,"keepers":[%s]}|}
         (gate_row ~next_action:"null" "quiet"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Error err -> Alcotest.fail ("roster must decode: " ^ err)
  | Ok ([ row ], _, _, _, _) ->
      Alcotest.(check bool) "null decodes to None" true
        (row.Decode.kr_next_action = None)
  | Ok (rows, _, _, _, _) ->
      Alcotest.failf "expected one row, got %d" (List.length rows)

let test_roster_decode_rejects_unknown_action () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"candle":{"status":"off"},"count":1,"total":1,"truncated":false,"keepers":[%s]}|}
         (gate_row ~next_action:{|"reboot_the_universe"|} "odd"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Ok _ -> Alcotest.fail "an action this build cannot spell must be rejected"
  | Error err ->
      Alcotest.(check bool)
        (Printf.sprintf "the error names the action: %s" err)
        true
        (String_util.contains_substring err "reboot_the_universe")

let test_purge_response_binds_exact_operation () =
  let body name operation_id = Yojson.Safe.to_string (`Assoc [
    "ok", `Bool true; "accepted", `Bool true; "target_kind", `String "keeper";
    "keeper_name", `String name; "operation_id", `String operation_id]) in
  (match Control.classify_purge_response ~keeper_name:"alpha" ~status:202 ~body:(body "alpha" "operation-alpha") with
   | Control.Purge_accepted {operation_id} -> Alcotest.(check string) "durable operation retained" "operation-alpha" operation_id
   | _ -> Alcotest.fail "valid purge receipt rejected");
  List.iter (fun raw ->
    match Control.classify_purge_response ~keeper_name:"alpha" ~status:202 ~body:raw with
    | Control.Rejected _ -> ()
    | _ -> Alcotest.fail "unbound purge receipt accepted")
    ["{}"; "{not-json"; body "another" "operation-alpha"; body "alpha" ""]

let test_configuration_error_isolated_and_deletable () =
  let json = Yojson.Safe.from_string
      (Printf.sprintf
         {|{"candle":{"status":"off"},"total":2,"truncated":false,"keepers":[%s,{"name":"probe","candle_balance_milli":null,"candle_account_revision":null,"effective_meta_error":{"keeper":"probe","message":"sandbox_profile is required"}}]}|}
         (gate_row "analyst")) in
  match Decode.decode_keeper_runtime_list json with
  | Error detail -> Alcotest.fail detail
  | Ok (rows, errors, truncated, total, _) ->
      let roster = Control.roster_of_reading ~rows ~errors ~truncated ~total in
      let healthy = reading ~liveness:(Control.liveness_of_roster roster "analyst") "analyst" in
      Alcotest.(check bool) "valid keeper retains live actions" true
        (List.mem Control.Shutdown (Control.available healthy));
      let broken = reading ~liveness:(Control.liveness_of_roster roster "probe") "probe" in
      check_actions "broken configuration remains deletable" [ Control.Delete ]
        (Control.available broken);
      Alcotest.(check (option action_testable)) "p never becomes delete" None
        (Control.primary broken);
      Alcotest.(check string) "configuration failure is visible" "config error"
        (Control.health_label ~ko:false broken);
      Alcotest.(check (list (pair string string))) "exact error retained"
        [ "probe", "sandbox_profile is required" ] errors

(* The nested error names the keeper it describes. A response whose row name and
   error identity disagree describes two keepers at once, and taking the row
   name would mark the wrong one misconfigured and offer its deletion. *)
let test_configuration_error_identity_must_match_the_row () =
  let roster keeper_field =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{"candle":{"status":"off"},"total":2,"truncated":false,"keepers":[%s,{"name":"probe","candle_balance_milli":null,"candle_account_revision":null,"effective_meta_error":{%s"message":"sandbox_profile is required"}}]}|}
         (gate_row "analyst") keeper_field)
  in
  let names_field detail affix =
    let n = String.length affix in
    let rec scan i =
      i + n <= String.length detail
      && (String.equal (String.sub detail i n) affix || scan (i + 1))
    in
    scan 0
  in
  (match Decode.decode_keeper_runtime_list (roster {|"keeper":"analyst",|}) with
   | Ok _ -> Alcotest.fail "a mismatched error identity was accepted"
   | Error detail ->
       Alcotest.(check bool) "the rejection names the field" true
         (names_field detail "effective_meta_error.keeper"));
  (match Decode.decode_keeper_runtime_list (roster "") with
   | Ok _ -> Alcotest.fail "an error without its keeper identity was accepted"
   | Error detail ->
       Alcotest.(check bool) "the rejection names the missing field" true
         (names_field detail "'keeper'"))

let () =
  Alcotest.run "tui-keeper-control"
    [ ( "health"
      , [ Alcotest.test_case "pause does not hide health" `Quick
            test_pause_does_not_hide_health
        ] )
    ; ( "reading"
      , [ Alcotest.test_case "roster keeps the axes apart" `Quick
            test_roster_decode_keeps_the_axes_apart
        ; Alcotest.test_case "a failing keeper reads failing" `Quick
            test_roster_decode_reads_a_failing_keeper
        ; Alcotest.test_case "a null action decodes to None" `Quick
            test_roster_decode_null_action_is_none
        ; Alcotest.test_case "an unknown action is rejected" `Quick
            test_roster_decode_rejects_unknown_action
        ; Alcotest.test_case "configuration error isolated and deletable" `Quick
            test_configuration_error_isolated_and_deletable
        ; Alcotest.test_case "a mismatched error identity is rejected" `Quick
            test_configuration_error_identity_must_match_the_row
        ; Alcotest.test_case "unobserved roster offers confirmed delete" `Quick
            test_unobserved_offers_confirmed_delete
        ; Alcotest.test_case "absent keeper offers boot" `Quick
            test_absent_offers_boot
        ; Alcotest.test_case "absent and paused reads paused" `Quick
            test_absent_and_paused_reads_paused
        ; Alcotest.test_case "live keeper offers pause" `Quick
            test_live_running_offers_pause
        ; Alcotest.test_case "live paused keeper offers resume" `Quick
            test_live_paused_offers_resume
        ; Alcotest.test_case "pause and health are read separately" `Quick
            test_pause_and_health_are_read_separately
        ; Alcotest.test_case "registered without a fiber offers boot" `Quick
            test_registered_without_fiber_offers_boot
        ; Alcotest.test_case "runs follows the roster and not the pause" `Quick
            test_runs_follows_the_roster_and_not_the_pause
        ] )
    ; ( "confirmation"
      , [ Alcotest.test_case "only shutdown confirms" `Quick
            test_only_shutdown_confirms
        ; Alcotest.test_case "reversible action submits at once" `Quick
            test_reversible_action_submits_on_first_press
        ; Alcotest.test_case "shutdown arms then submits" `Quick
            test_shutdown_arms_then_submits
        ; Alcotest.test_case "arming stays with its keeper" `Quick
            test_arming_does_not_carry_to_another_keeper
        ; Alcotest.test_case "arming stays with its action" `Quick
            test_arming_does_not_carry_to_another_action
        ; Alcotest.test_case "an action in flight blocks the rest" `Quick
            test_inflight_blocks_every_action
        ] )
    ; ( "requests"
      , [ Alcotest.test_case "plans name their endpoints" `Quick
            test_plans_name_their_endpoints
        ; Alcotest.test_case "delete is confirmed and irreversible" `Quick
            test_delete_is_confirmed_and_irreversible
        ; Alcotest.test_case "purge body carries the observed workspace" `Quick
            test_purge_body_carries_keeper_and_workspace
        ; Alcotest.test_case "deletion retry body carries the observed workspace" `Quick
            test_deletion_retry_body_carries_keeper_operation_and_workspace
        ; Alcotest.test_case "delete is not offered to a live fiber" `Quick
            test_delete_is_offered_with_shutdown_confirmation
        ; Alcotest.test_case "boot recovers a paused owner" `Quick
            test_boot_recovers_a_paused_owner
        ; Alcotest.test_case "resume body carries the operation id" `Quick
            test_resume_body_carries_the_operation_id
        ; Alcotest.test_case "other directives omit the operation id" `Quick
            test_non_resume_directive_omits_the_operation_id
        ; Alcotest.test_case "operation id is per attempt" `Quick
            test_operation_id_is_per_attempt
        ] )
    ; ( "refusal"
      , [ Alcotest.test_case "absent and rejected credentials read apart" `Quick
            test_refusal_distinguishes_absent_from_rejected
        ] )
    ; ( "roster completeness"
      , [ Alcotest.test_case "a roster short of its total is partial" `Quick
            test_short_roster_is_partial
        ; Alcotest.test_case "a missing row reads unread, not offline" `Quick
            test_short_roster_reads_unread_not_offline
        ; Alcotest.test_case "a clamped roster is partial" `Quick
            test_truncated_roster_is_partial
        ; Alcotest.test_case "a partial roster still confirms its rows" `Quick
            test_partial_roster_still_confirms_what_it_holds
        ; Alcotest.test_case "a full roster is complete" `Quick
            test_full_roster_is_complete
        ; Alcotest.test_case "duplicate runtime preserves lifecycle decisions" `Quick
            test_prepared_roster_first_duplicate_keeps_lifecycle
        ; Alcotest.test_case "first error overrides a live duplicate" `Quick
            test_prepared_roster_first_error_overrides_present_lifecycle
        ; Alcotest.test_case "replacement withdraws old live decisions" `Quick
            test_prepared_roster_replacement_withdraws_live_decisions
        ] )
    ; ( "responses"
      , [ Alcotest.test_case "purge binds exact operation" `Quick test_purge_response_binds_exact_operation
        ; Alcotest.test_case "a success is accepted" `Quick
            test_success_is_accepted
        ; Alcotest.test_case "already-live is carried" `Quick
            test_already_live_is_carried
        ; Alcotest.test_case "202 committed_followup_failed is not accepted" `Quick
            test_committed_followup_failed_is_distinguished_from_accepted
        ; Alcotest.test_case "409 is its own outcome" `Quick
            test_conflict_is_its_own_outcome
        ; Alcotest.test_case "workspace 409 is rejected, not paused-owner conflict" `Quick
            test_workspace_conflict_is_rejected_not_paused_owner
        ; Alcotest.test_case "boot phase 409 is rejected, not paused-owner conflict" `Quick
            test_boot_phase_conflict_is_rejected_not_paused_owner
        ; Alcotest.test_case "rejection prose stays a rejection" `Quick
            test_rejection_prose_does_not_become_a_conflict
        ; Alcotest.test_case "non-JSON error keeps its text" `Quick
            test_non_json_error_keeps_its_text
        ; Alcotest.test_case "empty error body names the status" `Quick
            test_empty_error_body_names_the_status
        ] )
    ; ( "roster"
      , [ Alcotest.test_case "remote identity failures preserve observed controls" `Quick
            test_remote_identity_failure_preserves_observed_controls
        ; Alcotest.test_case "the sandbox profile survives the decode" `Quick
            test_roster_decode_reads_the_sandbox_profile
        ; Alcotest.test_case "server equipment required; failures preserve Keeper" `Quick test_roster_equipment_is_required_and_failures_stay_per_keeper
        ; Alcotest.test_case "Candle reading pairs status and basis" `Quick test_roster_candle_reading_pairs_status_and_basis
        ; Alcotest.test_case "Item revision hints preserve lifecycle observations" `Quick
            test_item_revision_hint_preserves_keeper_observation
        ; Alcotest.test_case "paused stays apart from phase" `Quick
            test_roster_decode_keeps_paused_apart_from_phase
        ; Alcotest.test_case "a row without a sandbox profile is rejected" `Quick
            test_a_row_without_a_sandbox_profile_is_rejected
        ; Alcotest.test_case "one row takes its place in a complete roster" `Quick
            test_one_row_takes_its_place_in_a_complete_roster
        ; Alcotest.test_case "an incomplete roster does not take one row" `Quick
            test_an_incomplete_roster_does_not_take_one_row
        ; Alcotest.test_case "a row read answers only its Keeper" `Quick
            test_a_row_read_answers_only_its_keeper
        ; Alcotest.test_case "a starting Keeper is read when its probe ends" `Quick
            test_a_starting_keeper_is_read_when_probe_ends
        ; Alcotest.test_case "rows decode in order" `Quick
            test_roster_decode_reads_rows
        ; Alcotest.test_case "unknown health is rejected" `Quick
            test_roster_decode_rejects_an_unknown_status
        ; Alcotest.test_case "unknown phase is rejected" `Quick
            test_roster_decode_rejects_an_unknown_phase
        ; Alcotest.test_case "an error row decodes without refusing the rest" `Quick
            test_roster_decodes_an_error_row_without_refusing_the_rest
        ; Alcotest.test_case "the walk rest decodes beside the row" `Quick
            test_roster_decodes_the_walk_rest_beside_the_row
        ; Alcotest.test_case "operator disposition decodes beside the row" `Quick
            test_roster_decodes_operator_disposition_beside_the_row
        ; Alcotest.test_case "failing_since decodes beside the row" `Quick
            test_roster_decodes_failing_since
        ; Alcotest.test_case "recent_turns decodes beside the row" `Quick
            test_roster_decodes_recent_turns
        ; Alcotest.test_case "actual producer error stays isolated" `Quick
            test_actual_producer_error_is_isolated
        ; Alcotest.test_case "present unknown health on an error row is rejected" `Quick
            test_roster_decode_rejects_present_unknown_health_on_error_row
        ] )
    ]

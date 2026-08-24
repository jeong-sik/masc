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

let runtime ?(keepalive_running = true) ?(status = Status.Surface_active)
    ?(autoboot_enabled = true) ?(proactive_enabled = true)
    ?(runtime_id = "anthropic.claude-opus-5") ?(phase = phase "running") name :
    Decode.keeper_runtime =
  { kr_name = name
  ; kr_status = status
  ; kr_keepalive_running = keepalive_running
  ; kr_autoboot_enabled = autoboot_enabled
  ; kr_proactive_enabled = proactive_enabled
  ; kr_runtime_id = runtime_id
  ; kr_phase = phase
  }

let complete rows = Control.Roster_complete rows

let reading ?(paused = false) ?(liveness = Control.Unobserved) name :
    Control.reading =
  { name; paused; liveness }

let action_testable =
  Alcotest.testable
    (fun fmt action -> Format.pp_print_string fmt (Control.action_label action))
    ( = )

let check_actions label expected actual =
  Alcotest.(check (list action_testable)) label expected actual

(* An unobserved roster is the case that matters most: the durable metadata is
   still readable, so a reading built only from it looks complete while saying
   nothing about whether a fiber is alive. Offering boot there starts a second
   fiber on a keeper that is already running. *)
let test_unobserved_offers_nothing () =
  let r = reading "analyst" in
  check_actions "no action without a roster" [] (Control.available r);
  Alcotest.(check (option action_testable))
    "no primary without a roster" None (Control.primary r);
  Alcotest.(check string) "status is unread" "unread" (Control.status_label r)

let test_absent_offers_boot () =
  let r = reading ~liveness:Control.Absent "analyst" in
  check_actions "boot" [ Control.Boot ] (Control.available r);
  Alcotest.(check string) "offline" "offline" (Control.status_label r)

(* A keeper the operator paused and then shut down is absent from the roster.
   Reading it as plain "offline" hides why a boot alone will not start it. *)
let test_absent_and_paused_reads_paused () =
  let r = reading ~paused:true ~liveness:Control.Absent "analyst" in
  Alcotest.(check string) "paused" "paused" (Control.status_label r);
  check_actions "boot" [ Control.Boot ] (Control.available r)

let test_live_running_offers_pause () =
  let r = reading ~liveness:(Control.Present (runtime "analyst")) "analyst" in
  check_actions "pause first"
    [ Control.Pause; Control.Wakeup; Control.Shutdown ]
    (Control.available r);
  Alcotest.(check (option action_testable))
    "primary is pause" (Some Control.Pause) (Control.primary r);
  Alcotest.(check string) "active" "active" (Control.status_label r)

let test_live_paused_offers_resume () =
  let r =
    reading ~paused:true
      ~liveness:(Control.Present (runtime "analyst"))
      "analyst"
  in
  check_actions "resume first"
    [ Control.Resume; Control.Wakeup; Control.Shutdown ]
    (Control.available r);
  Alcotest.(check (option action_testable))
    "primary is resume" (Some Control.Resume) (Control.primary r)

(* Pause is durable metadata and overrides the surface status the roster
   reports, the same composition the operator snapshot publishes. Without the
   override a paused keeper whose fiber is sleeping still reads "active". *)
let test_pause_overrides_surface_status () =
  let live = runtime ~status:Status.Surface_idle "analyst" in
  Alcotest.(check string)
    "idle when not paused" "idle"
    (Control.status_label (reading ~liveness:(Control.Present live) "analyst"));
  Alcotest.(check string)
    "paused wins" "paused"
    (Control.status_label
       (reading ~paused:true ~liveness:(Control.Present live) "analyst"))

(* A row can be in the roster with its keepalive fiber stopped. Pause has
   nothing to pause there, so the fiber pair is what applies. *)
let test_registered_without_fiber_offers_boot () =
  let live =
    runtime ~keepalive_running:false ~status:Status.Surface_offline "analyst"
  in
  let r = reading ~liveness:(Control.Present live) "analyst" in
  check_actions "boot, not pause" [ Control.Boot ] (Control.available r)

let test_only_shutdown_confirms () =
  List.iter
    (fun (action, expected) ->
       Alcotest.(check bool)
         (Control.action_label action)
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
      ~keeper:"taskmaster" Control.Shutdown
  with
  | Control.Gate_arm rearmed ->
      Alcotest.(check string)
        "re-armed on the keeper under the cursor" "taskmaster"
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
                (Control.action_label action)))
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
       | Control.Directive action -> Format.fprintf fmt "directive:%s" action)
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
    (Control.plan Control.Shutdown)

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
         (Control.action_label action)
         None
         (Control.recovers_from_conflict action))
    [ Control.Pause; Control.Resume; Control.Shutdown; Control.Wakeup ]

let test_resume_body_carries_the_operation_id () =
  let body =
    Control.directive_body ~operator_operation_id:"masc-tui-resume-analyst-3"
      "resume"
  in
  match Yojson.Safe.from_string body with
  | `Assoc fields ->
      Alcotest.(check (option string))
        "action" (Some "resume")
        (match List.assoc_opt "action" fields with
         | Some (`String v) -> Some v
         | _ -> None);
      Alcotest.(check (option string))
        "operation id" (Some "masc-tui-resume-analyst-3")
        (match List.assoc_opt "operator_operation_id" fields with
         | Some (`String v) -> Some v
         | _ -> None)
  | _ -> Alcotest.fail "resume body must be a JSON object"

let test_non_resume_directive_omits_the_operation_id () =
  let body = Control.directive_body ~operator_operation_id:"ignored" "pause" in
  match Yojson.Safe.from_string body with
  | `Assoc fields ->
      Alcotest.(check bool)
        "no operation id" false
        (List.mem_assoc "operator_operation_id" fields)
  | _ -> Alcotest.fail "pause body must be a JSON object"

(* The id has to be the same for both requests of one boot recovery, and
   different from the next attempt's, or a retry either looks like fresh work
   or collides with the previous one. *)
let test_operation_id_is_per_attempt () =
  Alcotest.(check string)
    "stable within an attempt"
    (Control.mint_operation_id ~keeper:"analyst" ~serial:7)
    (Control.mint_operation_id ~keeper:"analyst" ~serial:7);
  Alcotest.(check bool)
    "distinct across attempts" false
    (String.equal
       (Control.mint_operation_id ~keeper:"analyst" ~serial:7)
       (Control.mint_operation_id ~keeper:"analyst" ~serial:8));
  Alcotest.(check bool)
    "distinct across keepers" false
    (String.equal
       (Control.mint_operation_id ~keeper:"analyst" ~serial:7)
       (Control.mint_operation_id ~keeper:"taskmaster" ~serial:7))

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
    Control.roster_of_reading ~rows:[] ~truncated:false ~total:10
  with
  | Control.Roster_partial { observed; total } ->
      Alcotest.(check int) "nothing observed" 0 (List.length observed);
      Alcotest.(check int) "ten exist" 10 total
  | Control.Roster_complete _ ->
      Alcotest.fail "a roster short of its own total is not complete"
  | Control.Roster_unobserved -> Alcotest.fail "the route did answer"

let test_short_roster_reads_unread_not_offline () =
  let roster = Control.roster_of_reading ~rows:[] ~truncated:false ~total:10 in
  let r = { Control.name = "analyst"; paused = false
          ; liveness = Control.liveness_of_roster roster "analyst" }
  in
  Alcotest.(check string) "unread, not offline" "unread"
    (Control.status_label r);
  check_actions "no action on an unread keeper" [] (Control.available r)

(* A refusal is two situations. Only one of them is fixed by providing a
   token, and the roster line used to give that advice for both. *)
let test_refusal_distinguishes_absent_from_rejected () =
  let has needle line = String_util.string_contains_substring ~needle line in
  let absent =
    Control.roster_failure_message ~credential_sent:false
      Control.Roster_unauthorized
  in
  let rejected =
    Control.roster_failure_message ~credential_sent:true
      Control.Roster_unauthorized
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
    Control.roster_of_reading ~rows:[ runtime "analyst" ] ~truncated:true
      ~total:1
  with
  | Control.Roster_partial { observed; _ } ->
      Alcotest.(check int) "the row it did return is kept" 1
        (List.length observed)
  | Control.Roster_complete _ ->
      Alcotest.fail "a clamped roster is not complete"
  | Control.Roster_unobserved -> Alcotest.fail "the route did answer"

(* A row the incomplete roster did return still answers for its own keeper. *)
let test_partial_roster_still_confirms_what_it_holds () =
  let roster =
    Control.roster_of_reading ~rows:[ runtime "analyst" ] ~truncated:false
      ~total:10
  in
  let present =
    { Control.name = "analyst"; paused = false
    ; liveness = Control.liveness_of_roster roster "analyst" }
  in
  Alcotest.(check string) "the observed keeper is active" "active"
    (Control.status_label present);
  check_actions "and it can be paused"
    [ Control.Pause; Control.Wakeup; Control.Shutdown ]
    (Control.available present)

let test_full_roster_is_complete () =
  match
    Control.roster_of_reading ~rows:[ runtime "analyst" ] ~truncated:false
      ~total:1
  with
  | Control.Roster_complete rows ->
      Alcotest.(check int) "one row" 1 (List.length rows);
      let absent =
        { Control.name = "taskmaster"; paused = false
        ; liveness = Control.liveness_of_roster (complete rows) "taskmaster" }
      in
      Alcotest.(check string) "a name a complete roster omits is offline"
        "offline" (Control.status_label absent)
  | Control.Roster_partial _ ->
      Alcotest.fail "a roster matching its own total is complete"
  | Control.Roster_unobserved -> Alcotest.fail "the route did answer"

(* {1 Response classification} *)

let test_success_is_accepted () =
  match
    Control.classify_response ~status:200
      ~body:{|{"ok":true,"action":"shutdown","name":"analyst"}|}
  with
  | Control.Accepted { already_live } ->
      Alcotest.(check bool) "not already live" false already_live
  | Control.Paused_owner_conflict _ | Control.Rejected _ ->
      Alcotest.fail "200 must be accepted"

let test_already_live_is_carried () =
  match
    Control.classify_response ~status:200
      ~body:{|{"ok":true,"action":"boot","name":"analyst","already_live":true}|}
  with
  | Control.Accepted { already_live } ->
      Alcotest.(check bool) "already live" true already_live
  | Control.Paused_owner_conflict _ | Control.Rejected _ ->
      Alcotest.fail "200 must be accepted"

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
  | Control.Accepted _ -> Alcotest.fail "409 is not an acceptance"
  | Control.Rejected _ -> Alcotest.fail "409 has its own outcome"

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
  | Control.Accepted _ | Control.Paused_owner_conflict _ ->
      Alcotest.fail "400 is a rejection"

let test_non_json_error_keeps_its_text () =
  match
    Control.classify_response ~status:502 ~body:"upstream closed the connection"
  with
  | Control.Rejected { status; detail } ->
      Alcotest.(check int) "status" 502 status;
      Alcotest.(check string)
        "text survives" "upstream closed the connection" detail
  | Control.Accepted _ | Control.Paused_owner_conflict _ ->
      Alcotest.fail "502 is a rejection"

let test_empty_error_body_names_the_status () =
  match Control.classify_response ~status:503 ~body:"" with
  | Control.Rejected { detail; _ } ->
      Alcotest.(check string) "status stands in" "HTTP 503" detail
  | Control.Accepted _ | Control.Paused_owner_conflict _ ->
      Alcotest.fail "503 is a rejection"

(* {1 Roster decode} *)

let gate_row ?(status = "active") ?(phase = "running") name =
  Printf.sprintf
    {|{"runtime_class":"keeper","name":%S,"agent_name":"keeper-%s-agent",
       "status":%S,"phase":%S,"keepalive_running":true,"autoboot_enabled":true,
       "proactive_enabled":true,"runtime_id":"anthropic.claude-opus-5",
       "created_at":"2026-08-21T17:32:29Z","updated_at":"2026-08-23T06:53:43Z"}|}
    name name status phase

let test_roster_decode_reads_rows () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"count":2,"total":2,"truncated":false,"keepers":[%s,%s]}|}
         (gate_row "analyst")
         (gate_row ~status:"idle" "taskmaster"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Error err -> Alcotest.fail ("roster must decode: " ^ err)
  | Ok (rows, truncated, total) ->
      Alcotest.(check int) "two rows" 2 (List.length rows);
      Alcotest.(check bool) "not truncated" false truncated;
      Alcotest.(check int) "total" 2 total;
      Alcotest.(check (list string))
        "names in order" [ "analyst"; "taskmaster" ]
        (List.map (fun (row : Decode.keeper_runtime) -> row.kr_name) rows);
      Alcotest.(check bool)
        "idle parsed" true
        (match rows with
         | [ _; second ] -> second.Decode.kr_status = Status.Surface_idle
         | _ -> false);
      Alcotest.(check bool)
        "phase parsed" true
        (match rows with
         | first :: _ ->
           Decode.keeper_phase_to_string first.Decode.kr_phase = "running"
         | [] -> false)

(* A producer that grows a seventh status label must fail the reading. A
   default would render the new state as one of the six and offer the action
   that belongs to that one instead. *)
let test_roster_decode_rejects_an_unknown_status () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"keepers":[%s]}|} (gate_row ~status:"quarantined" "analyst"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Ok _ -> Alcotest.fail "an unknown status must not decode"
  | Error err ->
      Alcotest.(check bool)
        "error names the status" true
        (let contains needle =
           let n = String.length needle and h = String.length err in
           let rec scan i = i + n <= h && (String.sub err i n = needle || scan (i + 1)) in
           scan 0
         in
         contains "quarantined")

let test_roster_decode_rejects_an_unknown_phase () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"keepers":[%s]}|}
         (gate_row ~phase:"teleporting" "analyst"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Ok _ -> Alcotest.fail "an unknown phase must not decode"
  | Error err ->
      Alcotest.(check string)
        "error names keeper and phase"
        {|keepers[0]: keeper "analyst" has unknown lifecycle phase "teleporting"|}
        err

let () =
  Alcotest.run "tui-keeper-control"
    [ ( "reading"
      , [ Alcotest.test_case "unobserved roster offers nothing" `Quick
            test_unobserved_offers_nothing
        ; Alcotest.test_case "absent keeper offers boot" `Quick
            test_absent_offers_boot
        ; Alcotest.test_case "absent and paused reads paused" `Quick
            test_absent_and_paused_reads_paused
        ; Alcotest.test_case "live keeper offers pause" `Quick
            test_live_running_offers_pause
        ; Alcotest.test_case "live paused keeper offers resume" `Quick
            test_live_paused_offers_resume
        ; Alcotest.test_case "pause overrides surface status" `Quick
            test_pause_overrides_surface_status
        ; Alcotest.test_case "registered without a fiber offers boot" `Quick
            test_registered_without_fiber_offers_boot
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
        ] )
    ; ( "responses"
      , [ Alcotest.test_case "a success is accepted" `Quick
            test_success_is_accepted
        ; Alcotest.test_case "already-live is carried" `Quick
            test_already_live_is_carried
        ; Alcotest.test_case "409 is its own outcome" `Quick
            test_conflict_is_its_own_outcome
        ; Alcotest.test_case "rejection prose stays a rejection" `Quick
            test_rejection_prose_does_not_become_a_conflict
        ; Alcotest.test_case "non-JSON error keeps its text" `Quick
            test_non_json_error_keeps_its_text
        ; Alcotest.test_case "empty error body names the status" `Quick
            test_empty_error_body_names_the_status
        ] )
    ; ( "roster"
      , [ Alcotest.test_case "rows decode in order" `Quick
            test_roster_decode_reads_rows
        ; Alcotest.test_case "unknown status is rejected" `Quick
            test_roster_decode_rejects_an_unknown_status
        ; Alcotest.test_case "unknown phase is rejected" `Quick
            test_roster_decode_rejects_an_unknown_phase
        ] )
    ]

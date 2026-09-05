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
    ?(next_action = None) ?(autoboot_enabled = true) ?(proactive_enabled = true)
    ?(runtime_id = "anthropic.claude-opus-5") ?(phase = phase "running")
    ?(sandbox_profile = "docker") name :
    Decode.keeper_runtime =
  { kr_name = name
  ; kr_health = health
  ; kr_paused = paused
  ; kr_next_action = next_action
  ; kr_keepalive_running = keepalive_running
  ; kr_autoboot_enabled = autoboot_enabled
  ; kr_proactive_enabled = proactive_enabled
  ; kr_runtime_id = runtime_id
  ; kr_phase = phase
  ; kr_sandbox_profile = sandbox_profile
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
  Alcotest.(check string) "health is unread" "unread" (Control.health_label r)

let test_absent_offers_boot () =
  let r = reading ~liveness:Control.Absent "analyst" in
  check_actions "boot" [ Control.Boot ] (Control.available r);
  Alcotest.(check string) "an absent keeper reads absent, not unread" "absent"
    (Control.health_label r)

(* A keeper the operator paused and then shut down is absent from the roster.
   Pause is its own field, so it still reads even where health cannot. *)
let test_absent_and_paused_reads_paused () =
  let r = reading ~paused:true ~liveness:Control.Absent "analyst" in
  Alcotest.(check bool) "pause survives an absent roster" true r.Control.paused;
  check_actions "boot" [ Control.Boot ] (Control.available r)

let test_live_running_offers_pause () =
  let r = reading ~liveness:(Control.Present (runtime "analyst")) "analyst" in
  check_actions "pause first"
    [ Control.Pause; Control.Wakeup; Control.Shutdown ]
    (Control.available r);
  Alcotest.(check (option action_testable))
    "primary is pause" (Some Control.Pause) (Control.primary r);
  Alcotest.(check string) "healthy" "healthy" (Control.health_label r)

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

(* Pause is a person's decision and health is an observation, so neither
   replaces the other. The composition this replaced let pause overwrite the
   status word, which meant a paused keeper whose fiber had died read exactly
   like one that was resting. *)
let test_pause_and_health_are_read_separately () =
  let live = runtime ~health:(health "zombie") "analyst" in
  let resting = reading ~liveness:(Control.Present live) "analyst" in
  let stopped = reading ~paused:true ~liveness:(Control.Present live) "analyst" in
  Alcotest.(check string)
    "health reads the same either way" "zombie"
    (Control.health_label resting);
  Alcotest.(check string)
    "pause does not overwrite it" "zombie" (Control.health_label stopped);
  Alcotest.(check bool) "and pause is still readable" true stopped.Control.paused

(* A row can be in the roster with its keepalive fiber stopped. Pause has
   nothing to pause there, so the fiber pair is what applies. *)
let test_registered_without_fiber_offers_boot () =
  let live =
    runtime ~keepalive_running:false "analyst"
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
       (Control.mint_operation_id ~keeper:"bandleader" ~serial:7))

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
    (Control.health_label r);
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
  Alcotest.(check string) "the observed keeper reports its health" "healthy"
    (Control.health_label present);
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
        { Control.name = "bandleader"; paused = false
        ; liveness = Control.liveness_of_roster (complete rows) "bandleader" }
      in
      (* "absent", not "unread": the roster answered and this keeper was not
         in it, which says no fiber is running it. *)
      Alcotest.(check string) "a name a complete roster omits is absent"
        "absent" (Control.health_label absent)
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
       "health":%S,"paused":%b,"next_action":%s,
       "phase":%S,"keepalive_running":true,"autoboot_enabled":true,
       "proactive_enabled":true,"runtime_id":"anthropic.claude-opus-5",
       "created_at":"2026-08-21T17:32:29Z","updated_at":"2026-08-23T06:53:43Z"}|}
    name name name sandbox_profile health paused next_action phase

(* The roster is where an operator compares keepers, so the sandbox each one is
   declared for has to survive the decode. Reading it per keeper from a detail
   pane was the thing this replaced. *)
let test_roster_decode_reads_the_sandbox_profile () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{"count":2,"total":2,"truncated":false,"keepers":[%s,%s]}|}
         (gate_row ~sandbox_profile:"docker" "contained")
         (gate_row ~sandbox_profile:"local" "on-the-host"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Error detail -> Alcotest.failf "roster must decode: %s" detail
  | Ok (rows, _, _) ->
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
         {|{"count":2,"total":2,"truncated":false,"keepers":[%s,%s]}|}
         (gate_row ~paused:true ~phase:"offline" "stopped-by-a-person")
         (gate_row ~paused:false ~phase:"offline" "fell-over"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Error detail -> Alcotest.failf "roster must decode: %s" detail
  | Ok (rows, _, _) ->
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
      {|{"count":1,"total":1,"truncated":false,"keepers":[
         {"runtime_class":"keeper","name":"n","agent_name":"keeper-n-agent",
          "meta":{"name":"n","trace_id":"t","created_at":"c","updated_at":"u"},
          "health":"healthy","paused":false,"next_action":null,
          "phase":"running","keepalive_running":true,"autoboot_enabled":true,
          "proactive_enabled":true,"runtime_id":"r",
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
      (Printf.sprintf {|{"count":2,"total":2,"truncated":false,"keepers":[%s,%s]}|}
         (gate_row "analyst")
         (gate_row ~health:"idle" "bandleader"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Error err -> Alcotest.fail ("roster must decode: " ^ err)
  | Ok (rows, truncated, total) ->
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
           Decode.keeper_health_to_string second.Decode.kr_health = "idle"
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
      (Printf.sprintf {|{"keepers":[%s]}|}
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

(* The roster header's tally and the status column are the same reading drawn
   twice. They disagreed once already, when the tally folded a status the
   column spelled out. These pin the tally to whichever function labels the
   column - now [health_label], since the column shows health. *)
let present ?(health = health "healthy") ?(paused = false) name =
  { Control.name
  ; paused
  ; liveness = Control.Present (runtime ~health name)
  }

let test_tally_uses_the_column_word () =
  let readings =
    [ present ~health:(health "healthy") "a"
    ; present ~health:(health "stale") "b"
    ; present ~health:(health "stale") "c"
    ]
  in
  Alcotest.(check (list (pair string int)))
    "stale is counted as stale, not folded into a healthier word"
    [ ("healthy", 1); ("stale", 2) ]
    (Control.health_tally readings)

let test_tally_never_names_a_word_the_column_hides () =
  let readings =
    [ present ~health:(health "healthy") "a"
    ; present ~health:(health "stale") "b"
    ; present ~health:(health "zombie") "c"
    ; present ~health:(health "healthy") ~paused:true "d"
    ; { Control.name = "e"; paused = true; liveness = Control.Absent }
    ; reading "f"
    ]
  in
  let tallied = List.map fst (Control.health_tally readings) in
  let shown = List.map Control.health_label readings in
  List.iter
    (fun word ->
      Alcotest.(check bool)
        (Printf.sprintf "the column shows %S somewhere" word)
        true
        (List.mem word shown))
    tallied;
  Alcotest.(check int)
    "every reading is counted exactly once"
    (List.length readings)
    (List.fold_left (fun sum (_, n) -> sum + n) 0 (Control.health_tally readings))

(* Pausing is a person's decision and health is an observation. Folding one
   into the other is what [status_label] does, and it is why a paused keeper
   whose fiber had died read the same as one that was simply resting. *)
let test_pause_does_not_hide_health () =
  let paused_zombie =
    present ~health:(health "zombie") ~paused:true "stopped-and-dead"
  in
  Alcotest.(check string)
    "a paused keeper still reports the health underneath"
    "zombie"
    (Control.health_label paused_zombie);
  Alcotest.(check bool) "and still reports being paused" true
    paused_zombie.Control.paused

(* The row publishes four separate readings, and the decoder has to keep them
   separate. A null action is the runtime naming none, which is not an action
   meaning "nothing to do"; an unknown one is this build not being able to
   spell it, which is not the same as none either. *)
let test_roster_decode_keeps_the_axes_apart () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"count":1,"total":1,"truncated":false,"keepers":[%s]}|}
         (gate_row ~health:"zombie" ~paused:true
            ~next_action:{|"auto_restart"|} "wreck"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Error err -> Alcotest.fail ("roster must decode: " ^ err)
  | Ok ([ row ], _, _) ->
      Alcotest.(check string) "health survives the surface fold" "zombie"
        (Decode.keeper_health_to_string row.Decode.kr_health);
      Alcotest.(check bool) "pause is its own field" true row.Decode.kr_paused;
      Alcotest.(check bool) "and does not replace the health" true
        (Decode.keeper_health_to_string row.Decode.kr_health <> "paused");
      Alcotest.(check bool) "the action is carried" true
        (row.Decode.kr_next_action
         = Some Masc.Keeper_status_runtime.Auto_restart)
  | Ok (rows, _, _) ->
      Alcotest.failf "expected one row, got %d" (List.length rows)

let test_roster_decode_null_action_is_none () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"count":1,"total":1,"truncated":false,"keepers":[%s]}|}
         (gate_row ~next_action:"null" "quiet"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Error err -> Alcotest.fail ("roster must decode: " ^ err)
  | Ok ([ row ], _, _) ->
      Alcotest.(check bool) "null decodes to None" true
        (row.Decode.kr_next_action = None)
  | Ok (rows, _, _) ->
      Alcotest.failf "expected one row, got %d" (List.length rows)

let test_roster_decode_rejects_unknown_action () =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"count":1,"total":1,"truncated":false,"keepers":[%s]}|}
         (gate_row ~next_action:{|"reboot_the_universe"|} "odd"))
  in
  match Decode.decode_keeper_runtime_list json with
  | Ok _ -> Alcotest.fail "an action this build cannot spell must be rejected"
  | Error err ->
      Alcotest.(check bool)
        (Printf.sprintf "the error names the action: %s" err)
        true
        (String_util.contains_substring err "reboot_the_universe")

let () =
  Alcotest.run "tui-keeper-control"
    [ ( "health_tally"
      , [ Alcotest.test_case "stale is not folded into a healthier word" `Quick
            test_tally_uses_the_column_word
        ; Alcotest.test_case "every counted word appears in the column" `Quick
            test_tally_never_names_a_word_the_column_hides
        ; Alcotest.test_case "pause does not hide health" `Quick
            test_pause_does_not_hide_health
        ] )
    ; ( "reading"
      , [ Alcotest.test_case "roster keeps the axes apart" `Quick
            test_roster_decode_keeps_the_axes_apart
        ; Alcotest.test_case "a null action decodes to None" `Quick
            test_roster_decode_null_action_is_none
        ; Alcotest.test_case "an unknown action is rejected" `Quick
            test_roster_decode_rejects_unknown_action
        ; Alcotest.test_case "unobserved roster offers nothing" `Quick
            test_unobserved_offers_nothing
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
      , [ Alcotest.test_case "the sandbox profile survives the decode" `Quick
            test_roster_decode_reads_the_sandbox_profile
        ; Alcotest.test_case "paused stays apart from phase" `Quick
            test_roster_decode_keeps_paused_apart_from_phase
        ; Alcotest.test_case "a row without a sandbox profile is rejected" `Quick
            test_a_row_without_a_sandbox_profile_is_rejected
        ; Alcotest.test_case "rows decode in order" `Quick
            test_roster_decode_reads_rows
        ; Alcotest.test_case "unknown health is rejected" `Quick
            test_roster_decode_rejects_an_unknown_status
        ; Alcotest.test_case "unknown phase is rejected" `Quick
            test_roster_decode_rejects_an_unknown_phase
        ] )
    ]

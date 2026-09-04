open Alcotest

module Gate = Masc.Keeper_tool_approval_gate
module Registry = Masc.Keeper_tool_approval_registry
module Late = Masc.Keeper_late_approval
module Events = Masc.Keeper_chat_events

let keeper = "keeper.one"

let invocation ~tool_use_id =
  Agent_core.Tool_contract.Invocation.create ~tool_use_id ~turn:1
    ~schedule:
      { Agent_core.Tool_contract.planned_index = 0
      ; batch_index = 0
      ; batch_size = 1
      ; execution_mode = Agent_core.Tool_contract.Serial
      }
    ~completion:Agent_core.Tool_contract.Continue_after_success

let request ~tool_call_id ~tool_name ~input =
  { Agent_core.Hooks.prompt =
      { question = "Run it?"; because = "policy: needs an operator's eye" }
  ; invocation = invocation ~tool_use_id:tool_call_id
  ; tool_name
  ; input
  }

let approval_to_string : Agent_core.Hooks.tool_approval -> string = function
  | Agent_core.Hooks.Approved -> "approved"
  | Agent_core.Hooks.Denied -> "denied"
  | Agent_core.Hooks.Timed_out -> "timed_out"

let approval = testable (Fmt.of_to_string approval_to_string) ( = )

let remember_outcome_to_string : Late.remember_outcome -> string = function
  | Late.Remembered { tool_name } -> "remembered:" ^ tool_name
  | Late.No_matching_ask -> "no-matching-ask"

let remember_outcome =
  testable (Fmt.of_to_string remember_outcome_to_string) ( = )

(* The gate and the store the way the server wires them: per-test instances,
   a timeout short enough that "nobody answered" is the outcome of every
   wait. *)
let with_gate f =
  Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let registry = Registry.create () in
      let late = Late.create () in
      let events = Events.create () in
      let gate =
        Gate.create ~registry ~late_approvals:late
          ~publish:(Events.publish events)
          ~clock ~keeper_name:keeper ~timeout_sec:0.05
      in
      f ~clock ~late ~events ~gate)

(* Drain what the stream holds without blocking on an empty one. *)
let rec drain events acc =
  match Events.take_nonblocking events with
  | None -> List.rev acc
  | Some event -> drain events (event :: acc)

let event_labels events =
  drain events []
  |> List.filter_map (function
       | Events.Tool_approval_requested { tool_call_id; question; because; _ } ->
           Some
             (Printf.sprintf "requested(%s,%s,%s)" tool_call_id question because)
       | Events.Tool_approval_settled { tool_call_id; outcome } ->
           Some (Printf.sprintf "settled(%s,%s)" tool_call_id outcome)
       | _ -> None)

let edit_input file = `Assoc [ "file_path", `String file ]

(* A gated call nobody answers: the wait times out, the turn is over, and the
   ask's description is what a late answer will be attributed to. *)
let time_out gate ~tool_call_id ~tool_name ~input =
  let answer = gate.Gate.tool_approval (request ~tool_call_id ~tool_name ~input) in
  check approval "the ask times out" Agent_core.Hooks.Timed_out answer

(* ── remembering a late answer ────────────────────────────────────── *)

let test_an_answer_after_the_timeout_is_remembered () =
  with_gate (fun ~clock:_ ~late ~events:_ ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      (* What handle_keeper_tool_approval does when settle says the wait is
         gone. *)
      check remember_outcome
        "the late answer descends from an ask that really timed out here"
        (Late.Remembered { tool_name = "Edit" })
        (Late.remember_late late ~keeper_name:keeper ~tool_call_id:"call-1"
           Registry.Approve ()))

let test_an_answer_that_names_no_ask_is_dropped () =
  with_gate (fun ~clock:_ ~late ~events:_ ~gate:_ ->
      check remember_outcome
        "an answer that cannot be attributed to an ask is not kept"
        Late.No_matching_ask
        (Late.remember_late late ~keeper_name:keeper
           ~tool_call_id:"call-never-held" Registry.Approve ()))

let test_an_ask_that_timed_out_long_ago_cannot_be_answered () =
  with_gate (fun ~clock:_ ~late ~events:_ ~gate:_ ->
      Late.note_timed_out late ~now:1000.0 ~keeper_name:keeper
        ~tool_call_id:"call-old" ~tool_name:"Edit" ~args:(edit_input "lib/a.ml") ();
      check remember_outcome
        "an ask older than the operator's moment is reaped before it can be \
         answered"
        Late.No_matching_ask
        (Late.remember_late late ~now:(1000.0 +. Late.ttl_sec +. 1.0)
           ~keeper_name:keeper ~tool_call_id:"call-old" Registry.Approve ()))

(* ── settling the retried call ────────────────────────────────────── *)

let test_the_identical_retried_call_is_settled_once () =
  with_gate (fun ~clock:_ ~late ~events ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      ignore
        (Late.remember_late late ~keeper_name:keeper ~tool_call_id:"call-1"
           Registry.Approve ());
      ignore (drain events []);
      (* The retry carries a fresh call id; identity is the call itself. *)
      let retry =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "the retry is settled by the remembered answer"
        Agent_core.Hooks.Approved retry;
      check (list string)
        "the stream shows the question was raised and settled from memory"
        [ "requested(call-2,Run it?,policy: needs an operator's eye)"
        ; "settled(call-2,remembered_approve)" ]
        (event_labels events);
      let again =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-3" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "one use consumes it; the next identical call asks again"
        Agent_core.Hooks.Timed_out again)

let test_a_remembered_denial_refuses_the_identical_retry () =
  with_gate (fun ~clock:_ ~late ~events ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      ignore
        (Late.remember_late late ~keeper_name:keeper ~tool_call_id:"call-1"
           Registry.Deny ());
      ignore (drain events []);
      let retry =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "a remembered refusal spares asking the same no twice"
        Agent_core.Hooks.Denied retry;
      check (list string) "the refusal is on the stream as remembered"
        [ "requested(call-2,Run it?,policy: needs an operator's eye)"
        ; "settled(call-2,remembered_deny)" ]
        (event_labels events))

let test_a_call_with_different_arguments_is_asked_about () =
  with_gate (fun ~clock:_ ~late ~events:_ ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      ignore
        (Late.remember_late late ~keeper_name:keeper ~tool_call_id:"call-1"
           Registry.Approve ());
      let other =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:(edit_input "lib/b.ml"))
      in
      check approval
        "different arguments are a different call; the memory does not reach it"
        Agent_core.Hooks.Timed_out other)

let test_the_same_arguments_in_another_order_are_the_same_call () =
  (* The retried call's arguments are model-regenerated JSON, so identity
     rides the canonical fingerprint rather than byte equality. *)
  with_gate (fun ~clock:_ ~late ~events:_ ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:
          (`Assoc
             [ "file_path", `String "lib/a.ml"; "old_string", `String "x" ]);
      ignore
        (Late.remember_late late ~keeper_name:keeper ~tool_call_id:"call-1"
           Registry.Approve ());
      let retry =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:
               (`Assoc
                  [ "old_string", `String "x"; "file_path", `String "lib/a.ml" ]))
      in
      check approval "reordered keys are the same call"
        Agent_core.Hooks.Approved retry)

let test_a_remembered_answer_does_not_cross_keepers () =
  with_gate (fun ~clock ~late ~events:_ ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      ignore
        (Late.remember_late late ~keeper_name:keeper ~tool_call_id:"call-1"
           Registry.Approve ());
      (* Same store, another keeper's gate: the identity carries the keeper
         name, so the identical call from somebody else is asked about. *)
      let other_gate =
        Gate.create ~registry:(Registry.create ()) ~late_approvals:late
          ~publish:(Events.publish (Events.create ()))
          ~clock ~keeper_name:"keeper.two" ~timeout_sec:0.05
      in
      let answer =
        other_gate.Gate.tool_approval
          (request ~tool_call_id:"call-1" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "another keeper's identical call is not covered"
        Agent_core.Hooks.Timed_out answer;
      let retry =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "the keeper the answer was given to still holds it"
        Agent_core.Hooks.Approved retry)

(* ── staleness ────────────────────────────────────────────────────── *)

let test_a_fresh_remembered_answer_applies () =
  (* The settle-once test above is this with the store's own clock; here the
     remembered entry's age is pinned explicitly just under the bound. *)
  with_gate (fun ~clock ~late ~events:_ ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      ignore
        (Late.remember_late late
           ~now:(Eio.Time.now clock -. 1.0)
           ~keeper_name:keeper ~tool_call_id:"call-1" Registry.Approve ());
      let retry =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "a second-old answer is still the operator's moment"
        Agent_core.Hooks.Approved retry)

let test_a_remembered_answer_past_its_moment_is_asked_about_again () =
  with_gate (fun ~clock ~late ~events ~gate ->
      time_out gate ~tool_call_id:"call-1" ~tool_name:"Edit"
        ~input:(edit_input "lib/a.ml");
      (* The answer arrived, but longer ago than one operator moment spans:
         by the time the identical call returns it is a new occurrence, not
         the retry the operator answered. *)
      ignore
        (Late.remember_late late
           ~now:(Eio.Time.now clock -. Late.ttl_sec -. 1.0)
           ~keeper_name:keeper ~tool_call_id:"call-1" Registry.Approve ());
      ignore (drain events []);
      let retry =
        gate.Gate.tool_approval
          (request ~tool_call_id:"call-2" ~tool_name:"Edit"
             ~input:(edit_input "lib/a.ml"))
      in
      check approval "a stale memory is no memory; the call is asked about"
        Agent_core.Hooks.Timed_out retry;
      check (list string) "and the stream shows a fresh ask, not a memory"
        [ "requested(call-2,Run it?,policy: needs an operator's eye)"
        ; "settled(call-2,timed_out)" ]
        (event_labels events))

let () =
  run "keeper_late_approval"
    [ ( "remembering a late answer"
      , [ test_case "an answer after the timeout is remembered" `Quick
            test_an_answer_after_the_timeout_is_remembered
        ; test_case "an answer that names no ask is dropped" `Quick
            test_an_answer_that_names_no_ask_is_dropped
        ; test_case "an ask that timed out long ago cannot be answered" `Quick
            test_an_ask_that_timed_out_long_ago_cannot_be_answered
        ] )
    ; ( "settling the retried call"
      , [ test_case "the identical retried call is settled once" `Quick
            test_the_identical_retried_call_is_settled_once
        ; test_case "a remembered denial refuses the identical retry" `Quick
            test_a_remembered_denial_refuses_the_identical_retry
        ; test_case "a call with different arguments is asked about" `Quick
            test_a_call_with_different_arguments_is_asked_about
        ; test_case "the same arguments in another order are the same call"
            `Quick test_the_same_arguments_in_another_order_are_the_same_call
        ; test_case "a remembered answer does not cross keepers" `Quick
            test_a_remembered_answer_does_not_cross_keepers
        ] )
    ; ( "staleness"
      , [ test_case "a fresh remembered answer applies" `Quick
            test_a_fresh_remembered_answer_applies
        ; test_case "a remembered answer past its moment is asked about again"
            `Quick test_a_remembered_answer_past_its_moment_is_asked_about_again
        ] )
    ]

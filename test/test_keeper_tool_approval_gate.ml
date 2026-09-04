open Alcotest

module Gate = Masc.Keeper_tool_approval_gate
module Registry = Masc.Keeper_tool_approval_registry
module Events = Masc.Keeper_chat_events
module Keeper_chat_events_publish = Masc.Keeper_chat_events

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

let pre_tool_use_event ~tool_name ~input =
  Agent_core.Hooks.PreToolUse
    { invocation = invocation ~tool_use_id:"call-1"
    ; tool_name
    ; input
    ; accumulated_cost_usd = 0.0
    }

let decision_to_string : Agent_core.Hooks.hook_decision -> string = function
  | Agent_core.Hooks.Continue -> "continue"
  | Agent_core.Hooks.ElicitToolApproval { question } -> "ask:" ^ question
  | Agent_core.Hooks.Block reason -> "block:" ^ reason
  | Agent_core.Hooks.AdjustParams _ -> "adjust"
  | Agent_core.Hooks.ElicitInput _ -> "elicit"
  | Agent_core.Hooks.Nudge _ -> "nudge"
  | Agent_core.Hooks.HookFailed _ -> "hook_failed"

let approval_to_string : Agent_core.Hooks.tool_approval -> string = function
  | Agent_core.Hooks.Approved -> "approved"
  | Agent_core.Hooks.Denied -> "denied"
  | Agent_core.Hooks.Timed_out -> "timed_out"

let approval = testable (Fmt.of_to_string approval_to_string) ( = )

let with_gate ~timeout_sec f =
  Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let registry = Registry.create () in
      let events = Events.create () in
      let gate =
        Gate.create ~registry
          ~late_approvals:(Masc.Keeper_late_approval.create ())
          ~publish:(Keeper_chat_events_publish.publish events)
          ~clock ~keeper_name:keeper ~timeout_sec
      in
      f ~clock ~registry ~events ~gate)

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

(* ── the hook half ────────────────────────────────────────────────── *)

let test_a_read_runs_without_asking () =
  with_gate ~timeout_sec:1.0 (fun ~clock:_ ~registry:_ ~events:_ ~gate ->
      check string "reading is not put to an operator" "continue"
        (decision_to_string
           (gate.Gate.pre_tool_use
              (pre_tool_use_event ~tool_name:"Read"
                 ~input:(`Assoc [ "file_path", `String "a.ml" ])))))

let test_an_edit_asks () =
  with_gate ~timeout_sec:1.0 (fun ~clock:_ ~registry:_ ~events:_ ~gate ->
      let edit_event () =
        pre_tool_use_event ~tool_name:"Edit"
          ~input:(`Assoc [ "file_path", `String "lib/a.ml" ])
      in
      check string "the question names the file the call would change"
        "ask:Run Edit on lib/a.ml?"
        (decision_to_string (gate.Gate.pre_tool_use (edit_event ())));
      (* The because the policy computed is the thing an operator reads when
         deciding; asking without it forces a blind yes. *)
      let why =
        match gate.Gate.pre_tool_use (edit_event ()) with
        | Agent_core.Hooks.ElicitToolApproval { question; because } ->
            Printf.sprintf "ask:%s because=%s" question because
        | other -> "not-an-ask: " ^ decision_to_string other
      in
      check string "the ask carries why this call was held"
        "ask:Run Edit on lib/a.ml? because=this call reaches outside masc"
        why)

let test_other_stages_pass_through () =
  with_gate ~timeout_sec:1.0 (fun ~clock:_ ~registry:_ ~events:_ ~gate ->
      (* Installed at pre_tool_use only; a stage that reaches it anyway must
         not be turned into an approval prompt. *)
      check string "a turn boundary is not a tool call" "continue"
        (decision_to_string
           (gate.Gate.pre_tool_use
              (Agent_core.Hooks.BeforeTurn { turn = 1; messages = [] }))))

(* ── the callback half ────────────────────────────────────────────── *)

let request ~tool_name ~input =
  { Agent_core.Hooks.prompt =
      { question = "Run it?"; because = "policy: needs an operator's eye" }
  ; invocation = invocation ~tool_use_id:"call-1"
  ; tool_name
  ; input
  }

let settle_when_pending registry ~clock decision =
  let rec wait attempts =
    if Registry.pending registry = [] && attempts > 0 then begin
      Eio.Time.sleep clock 0.005;
      wait (attempts - 1)
    end
  in
  wait 100;
  ignore
    (Registry.settle registry ~keeper_name:keeper ~tool_call_id:"call-1"
       decision)

let test_an_approval_lets_the_call_through () =
  with_gate ~timeout_sec:5.0 (fun ~clock ~registry ~events ~gate ->
      let answer =
        Eio.Fiber.pair
          (fun () ->
            gate.Gate.tool_approval
              (request ~tool_name:"Edit"
                 ~input:(`Assoc [ "file_path", `String "a.ml" ])))
          (fun () -> settle_when_pending registry ~clock Registry.Approve)
        |> fst
      in
      check approval "the call is admitted" Agent_core.Hooks.Approved answer;
      check (list string) "the stream carried the question, its reason and its answer"
        [ "requested(call-1,Run it?,policy: needs an operator's eye)"
        ; "settled(call-1,approve)" ]
        (event_labels events))

let test_a_denial_stops_the_call () =
  with_gate ~timeout_sec:5.0 (fun ~clock ~registry ~events ~gate ->
      let answer =
        Eio.Fiber.pair
          (fun () ->
            gate.Gate.tool_approval
              (request ~tool_name:"Edit" ~input:(`Assoc [])))
          (fun () -> settle_when_pending registry ~clock Registry.Deny)
        |> fst
      in
      check approval "the call is refused" Agent_core.Hooks.Denied answer;
      check (list string) "and the refusal is on the stream"
        [ "requested(call-1,Run it?,policy: needs an operator's eye)"
        ; "settled(call-1,deny)" ]
        (event_labels events))

let test_nobody_answering_does_not_admit_the_call () =
  with_gate ~timeout_sec:0.05 (fun ~clock:_ ~registry:_ ~events ~gate ->
      (* The whole point of the gate: silence must not run the call it was
         built to hold. *)
      let answer =
        gate.Gate.tool_approval (request ~tool_name:"Edit" ~input:(`Assoc []))
      in
      check approval "silence is not consent" Agent_core.Hooks.Timed_out answer;
      check (list string) "the pane is told the prompt is over"
        [ "requested(call-1,Run it?,policy: needs an operator's eye)"
        ; "settled(call-1,timed_out)" ]
        (event_labels events))

let test_the_settled_event_is_sent_on_every_path () =
  (* A prompt with no closing event would stay on screen forever, so this is
     checked across the outcomes rather than only the happy one. *)
  with_gate ~timeout_sec:0.05 (fun ~clock:_ ~registry:_ ~events ~gate ->
      ignore (gate.Gate.tool_approval (request ~tool_name:"Edit" ~input:(`Assoc [])));
      let settled =
        event_labels events
        |> List.filter (fun label ->
               String.length label >= 7 && String.sub label 0 7 = "settled")
      in
      check int "exactly one closing event" 1 (List.length settled))

let test_a_synthetic_composition_asks_with_its_node_name () =
  (* A composition tool has no descriptor, so the policy falls to the plan
     index; its because is the only place the node that caused the ask is
     named. This pins that the node name survives the gate — dropped here,
     an operator sees a plan name and a blind yes. *)
  with_gate ~timeout_sec:1.0 (fun ~clock:_ ~registry:_ ~events:_ ~gate ->
      Masc.Keeper_tool_composition_plan_index.record
        gate.Gate.composition_plan_index
        ~composition:"keeper_compose_gate_fixture"
        ~node_tools:[ "Read"; "Edit"; "Grep" ];
          match gate.Gate.pre_tool_use (pre_tool_use_event
                 ~tool_name:"keeper_compose_gate_fixture"
                 ~input:(`Assoc [])) with
          | Agent_core.Hooks.ElicitToolApproval { because; _ } ->
              let has_affix affix s =
                let n = String.length affix in
                let m = String.length s in
                let rec at i =
                  i + n <= m
                  && (String.sub s i n = affix || at (i + 1))
                in
                m >= n && at 0
              in
              check bool "a composition's because names the node that asks"
                true
                (has_affix "node Edit:" because)
          | other ->
              Alcotest.fail
                ("composition should ask, got: " ^ decision_to_string other))

let () =
  run "keeper_tool_approval_gate"
    [ ( "deciding whether to ask"
      , [ test_case "a read runs without asking" `Quick
            test_a_read_runs_without_asking
        ; test_case "an edit asks" `Quick test_an_edit_asks
        ; test_case "a synthetic composition asks with its node name" `Quick
            test_a_synthetic_composition_asks_with_its_node_name
        ; test_case "other stages pass through" `Quick
            test_other_stages_pass_through
        ] )
    ; ( "asking"
      , [ test_case "an approval lets the call through" `Quick
            test_an_approval_lets_the_call_through
        ; test_case "a denial stops the call" `Quick test_a_denial_stops_the_call
        ; test_case "nobody answering does not admit the call" `Quick
            test_nobody_answering_does_not_admit_the_call
        ; test_case "the settled event is sent on every path" `Quick
            test_the_settled_event_is_sent_on_every_path
        ] )
    ]

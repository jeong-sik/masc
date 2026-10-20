open Agent_core

(* ── Elicitation types ──────────────────────────────────── *)

let test_elicitation_request_basic () =
  let req : Hooks.elicitation_request =
    { question = "What environment?"; schema = None; timeout_s = None }
  in
  Alcotest.(check string) "question" "What environment?" req.question;
  Alcotest.(check bool) "no schema" true (Option.is_none req.schema);
  Alcotest.(check bool) "no timeout" true (Option.is_none req.timeout_s)
;;

let test_elicitation_request_with_schema () =
  let schema =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "env", `Assoc [ "type", `String "string" ] ]
      ]
  in
  let req : Hooks.elicitation_request =
    { question = "Choose environment"; schema = Some schema; timeout_s = Some 30.0 }
  in
  Alcotest.(check bool) "has schema" true (Option.is_some req.schema);
  Alcotest.(check bool)
    "has timeout"
    true
    (match req.timeout_s with
     | Some 30.0 -> true
     | _ -> false)
;;

let test_elicitation_response_answer () =
  let resp = Hooks.Answer (`String "production") in
  match resp with
  | Hooks.Answer (`String s) -> Alcotest.(check string) "answer" "production" s
  | _ -> Alcotest.fail "expected Answer"
;;

let test_elicitation_response_declined () =
  let resp = Hooks.Declined in
  match resp with
  | Hooks.Declined -> ()
  | _ -> Alcotest.fail "expected Declined"
;;

let test_elicitation_response_timeout () =
  let resp = Hooks.Timeout in
  match resp with
  | Hooks.Timeout -> ()
  | _ -> Alcotest.fail "expected Timeout"
;;

(* ── hook_decision ElicitInput ─────────────────────────── *)

let test_hook_decision_elicit_input () =
  let req : Hooks.elicitation_request =
    { question = "Confirm?"; schema = None; timeout_s = Some 10.0 }
  in
  let decision = Hooks.ElicitInput req in
  match decision with
  | Hooks.ElicitInput r -> Alcotest.(check string) "question" "Confirm?" r.question
  | _ -> Alcotest.fail "expected ElicitInput"
;;

let test_hook_decision_to_string () =
  let req : Hooks.elicitation_request =
    { question = "ok?"; schema = None; timeout_s = None }
  in
  let s = Agent_lifecycle.hook_decision_to_string (Hooks.ElicitInput req) in
  Alcotest.(check string) "string" "elicit_input" s
;;

let test_hook_decision_tool_approval () =
  let prompt : Hooks.tool_approval_prompt = { question = "Approve exact tool call?"; because = "policy: unknown tool surface" } in
  let decision = Hooks.ElicitToolApproval prompt in
  match decision with
  | Hooks.ElicitToolApproval returned ->
    Alcotest.(check string) "question" "Approve exact tool call?" returned.question
  | _ -> Alcotest.fail "expected ElicitToolApproval"
;;

let test_hook_decision_tool_approval_to_string () =
  let decision = Hooks.ElicitToolApproval { question = "Approve exact tool call?"; because = "policy: unknown tool surface" } in
  Alcotest.(check string)
    "string"
    "elicit_tool_approval"
    (Agent_lifecycle.hook_decision_to_string decision)
;;

(* ── Elicitation callback ──────────────────────────────── *)

let test_elicitation_callback_answer () =
  let cb : Hooks.elicitation_callback =
    fun req -> Hooks.Answer (`String (Printf.sprintf "answered: %s" req.question))
  in
  let req : Hooks.elicitation_request =
    { question = "env?"; schema = None; timeout_s = None }
  in
  match cb req with
  | Hooks.Answer (`String s) ->
    Alcotest.(check string) "callback answer" "answered: env?" s
  | _ -> Alcotest.fail "expected Answer from callback"
;;

let test_elicitation_callback_declined () =
  let cb : Hooks.elicitation_callback = fun _req -> Hooks.Declined in
  let req : Hooks.elicitation_request =
    { question = "ok?"; schema = None; timeout_s = None }
  in
  match cb req with
  | Hooks.Declined -> ()
  | _ -> Alcotest.fail "expected Declined from callback"
;;

(* ── Event bus ElicitationCompleted ────────────────────── *)

let test_event_bus_elicitation_completed () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let config =
    Event_bus.subscription_config ~capacity:1 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let sub = Event_bus.subscribe ~config bus in
  Event_bus.publish
    bus
    (Event_bus.mk_event
       (ElicitationCompleted
          { agent_name = "test-agent"
          ; question = "What env?"
          ; response = Hooks.Answer (`String "prod")
          }));
  let events = Event_bus.drain sub in
  Alcotest.(check int) "1 event" 1 (List.length events);
  match (List.hd events).payload with
  | ElicitationCompleted { agent_name; question; _ } ->
    Alcotest.(check string) "agent" "test-agent" agent_name;
    Alcotest.(check string) "question" "What env?" question
  | _ -> Alcotest.fail "expected ElicitationCompleted"
;;

let test_event_bus_filter_agent () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let config =
    Event_bus.subscription_config ~capacity:1 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let sub = Event_bus.subscribe ~config ~filter:(Event_bus.filter_agent "agent-a") bus in
  Event_bus.publish
    bus
    (Event_bus.mk_event
       (ElicitationCompleted
          { agent_name = "agent-a"; question = "q"; response = Hooks.Declined }));
  Event_bus.publish
    bus
    (Event_bus.mk_event
       (ElicitationCompleted
          { agent_name = "agent-b"; question = "q"; response = Hooks.Declined }));
  let events = Event_bus.drain sub in
  Alcotest.(check int) "filtered to 1" 1 (List.length events)
;;

(* ── Agent.options elicitation field ───────────────────── *)

let test_agent_options_elicitation_default () =
  let opts = Agent.default_options in
  Alcotest.(check bool) "generic default none" true (Option.is_none opts.elicitation);
  Alcotest.(check bool)
    "tool approval default none"
    true
    (Option.is_none opts.tool_approval)
;;

let test_agent_elicit_input_without_callback_pauses () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let schema =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "env", `Assoc [ "type", `String "string" ] ]
      ]
  in
  let request : Hooks.elicitation_request =
    { question = "Which environment?"; schema = Some schema; timeout_s = Some 20.0 }
  in
  let before_turn = function
    | Hooks.BeforeTurn _ -> Hooks.ElicitInput request
    | _ -> Hooks.Continue
  in
  let event_bus = Event_bus.create () in
  let subscription =
    Event_bus.subscribe
      ~config:
        (Event_bus.subscription_config
           ~capacity:8
           ~overflow:Event_bus.Drop_newest
         |> Result.get_ok)
      event_bus
  in
  let options =
    { Agent.default_options with
      hooks = { Hooks.empty with before_turn = Some before_turn }
    ; event_bus = Some event_bus
    }
  in
  let config =
    { (Types.default_config ~model:"test-model") with name = "human-reviewer" }
  in
  let agent = Agent.create ~net:env#net ~config ~options () in
  (match Agent.run ~sw agent "deploy" with
  | Error (Error.Agent (Error.InputRequired input)) ->
    (match input.participant_name with
     | Some participant ->
       Alcotest.(check string) "participant" "human-reviewer" participant
     | None -> Alcotest.fail "expected participant");
    Alcotest.(check string) "question" "Which environment?" input.question;
    Alcotest.(check bool) "schema preserved" true (Option.is_some input.schema);
    Alcotest.(check bool) "timeout preserved" true (input.timeout_s = Some 20.0);
    Alcotest.(check bool) "request_id non-empty" true (String.length input.request_id > 0);
    let state_after_pause = Agent.state agent in
    Alcotest.(check int) "prompt retained" 1 (List.length state_after_pause.messages);
    let pending = Option.get (Agent.pending_input agent) in
    Alcotest.(check string) "owned request identity" input.request_id pending.request.request_id;
    let persisted = Checkpoint.to_string (Agent.checkpoint agent) in
    Agent.close agent;
    let restored = Agent.resume ~net:env#net
      ~checkpoint:(Result.get_ok (Checkpoint.of_string persisted))
      ~options () in
    Alcotest.(check bool) "pending survives checkpoint and Agent cleanup" true
      (Agent.pending_input restored = Some pending);
    let forged_question = {pending with request={pending.request with question="tampered"}} in
    Alcotest.(check bool) "exact response accepted" true
      (Agent.provide_input restored forged_question (Hooks.Answer (`Assoc [ "env", `String "prod" ])) = Ok ());
    Alcotest.(check bool) "pending consumed" true (Agent.pending_input restored = None);
    Alcotest.(check bool) "repeated response refused" true
      (Agent.provide_input restored pending Hooks.Declined = Error (Agent.Input_not_current Agent_input_request.No_pending_request));
    let agent = restored in
    let state_after_input = Agent.state agent in
    Alcotest.(check int) "input appended" 2 (List.length state_after_input.messages);
    (match List.rev state_after_input.messages with
     | { Types.role = Types.User; content = [ Types.Text text ]; _ } :: _ ->
       Alcotest.(check string)
         "input message"
         "[User input] Which environment?: {\"env\":\"prod\"}"
         text
     | _ -> Alcotest.fail "expected user input message")
  | Error err -> Alcotest.failf "expected InputRequired, got %s" (Error.to_string err)
  | Ok _ -> Alcotest.fail "expected InputRequired");
  let lifecycle_events =
    Event_bus.drain subscription
    |> List.filter (fun (event : Event_bus.event) ->
      String.starts_with ~prefix:"agent_" (Event_bus.payload_kind event.payload))
  in
  Alcotest.(check (list string))
    "input request is not failure"
    [ "agent_started"; "agent_input_required" ]
    (List.map
       (fun (event : Event_bus.event) -> Event_bus.payload_kind event.payload)
       lifecycle_events);
  (match List.rev lifecycle_events with
   | { Event_bus.payload = Event_bus.AgentInputRequired { request; _ }; _ } :: _ ->
     Alcotest.(check string) "event question" "Which environment?" request.question
   | _ -> Alcotest.fail "expected AgentInputRequired lifecycle event")
;;

let test_current_wait_survives_rejection_and_replacement () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let request : Hooks.elicitation_request =
    {question="question";schema=None;timeout_s=None} in
  let before_turn = function
    | Hooks.BeforeTurn _ -> Hooks.ElicitInput request
    | _ -> Hooks.Continue in
  let options = {Agent.default_options with
    hooks={Hooks.empty with before_turn=Some before_turn}} in
  let config = {(Types.default_config ~model:"input-only") with name="same-name"} in
  let agent = Agent.create ~net:env#net ~config ~options () in
  let paused = function
    | Error (Error.Agent (Error.InputRequired _)) -> Option.get (Agent.pending_input agent)
    | Ok _ -> Alcotest.fail "expected pause before provider"
    | Error error -> Alcotest.fail (Error.to_string error) in
  let a = paused (Agent.run ~sw agent "original") in
  let rejected = Agent.run ~sw ~on_yield:(fun () -> ()) agent "invalid callbacks" in
  Alcotest.(check bool) "unpaired callback rejected" true (Result.is_error rejected);
  Alcotest.(check bool) "Started before validation cannot erase wait" true
    (Agent.pending_input agent = Some a);
  let before = Agent.state agent in
  let b = paused (Agent.run_turn_stream ~sw ~on_event:ignore agent) in
  Alcotest.(check bool) "low-level continuation has a distinct run" true
    (not (String.equal a.run_id b.run_id));
  Alcotest.(check bool) "replacement request is distinct" true
    (not (String.equal a.request.request_id b.request.request_id));
  Alcotest.(check bool) "late A refused" true
    (Agent.provide_input agent a (Hooks.Answer (`String "old")) = Error (Agent.Input_not_current Agent_input_request.Request_not_current));
  Alcotest.(check bool) "late A leaves B and messages unchanged" true
    (Agent.pending_input agent = Some b && Agent.state agent = before);
  Alcotest.(check bool) "explicit decline settles B" true
    (Agent.provide_input agent b Hooks.Declined = Ok ());
  Alcotest.(check bool) "decline has no synthetic message" true
    (Agent.pending_input agent = None && Agent.state agent = before);
  let c = paused (Agent.run_turn_stream ~sw ~on_event:ignore agent) in
  Alcotest.(check bool) "explicit timeout response settles C" true
    (Agent.provide_input agent c Hooks.Timeout = Ok ());
  Alcotest.(check bool) "timeout has no synthetic message" true
    (Agent.pending_input agent = None && Agent.state agent = before)
;;

let test_checkpoint_delta_retains_current_wait () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let request : Hooks.elicitation_request = {question="question";schema=None;timeout_s=None} in
  let before_turn = function Hooks.BeforeTurn _ -> Hooks.ElicitInput request | _ -> Hooks.Continue in
  let options = {Agent.default_options with hooks={Hooks.empty with before_turn=Some before_turn}} in
  let config = {(Types.default_config ~model:"input-only") with name="same-name"} in
  let a = Agent.create ~net:env#net ~config ~options () in
  let b = Agent.create ~net:env#net ~config ~options () in
  ignore (Agent.run ~sw a "first"); ignore (Agent.run ~sw b "second");
  let pa = Option.get (Agent.pending_input a) and pb = Option.get (Agent.pending_input b) in
  Alcotest.(check bool) "same-name agents have independent originating runs" true
    (not (String.equal pa.run_id pb.run_id));
  Alcotest.(check bool) "another Agent's response cannot settle A" true
    (Agent.provide_input a pb Hooks.Declined = Error (Agent.Input_not_current Agent_input_request.Request_not_current));
  let before = Agent.checkpoint a in
  let after = {before with Checkpoint.pending_input=Some pb} in
  let delta = Checkpoint.compute_delta before after in
  let decoded = Result.get_ok (Checkpoint.delta_of_json (Checkpoint.delta_to_json delta)) in
  let restored = Result.get_ok (Checkpoint.apply_delta before decoded) in
  Alcotest.(check bool) "delta retains exact pending proof" true (restored.pending_input = Some pb);
  let cleared = {after with Checkpoint.pending_input=None} in
  let restored = Result.get_ok (Checkpoint.apply_delta after (Checkpoint.compute_delta after cleared)) in
  Alcotest.(check bool) "delta records settlement" true (restored.pending_input = None)
;;

let test_accepted_resume_failure_consumes_old_wait () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let waiting = ref true in
  let request : Hooks.elicitation_request = {question="question";schema=None;timeout_s=None} in
  let before_turn = function
    | Hooks.BeforeTurn _ when !waiting -> Hooks.ElicitInput request
    | _ -> Hooks.Continue in
  let before_turn_params _ = Hooks.HookFailed {stage=Hooks.Before_turn_params;detail="fixture failure after accepted input"} in
  let options = {Agent.default_options with
    hooks={Hooks.empty with before_turn=Some before_turn;before_turn_params=Some before_turn_params}} in
  let agent = Agent.create ~net:env#net ~config:(Types.default_config ~model:"input-only") ~options () in
  ignore (Agent.run ~sw agent "original");
  let pending = Option.get (Agent.pending_input agent) in
  waiting := false;
  let result = Agent.run_turn_stream ~sw ~on_event:ignore agent in
  Alcotest.(check bool) "later typed stage fails before provider dispatch" true
    (match result with
     | Error (Error.Agent (Error.HookExecutionFailed {hook_name;_})) -> String.equal hook_name "before_turn_params"
     | Error _ | Ok _ -> false);
  Alcotest.(check bool) "accepted low-level resume consumed old wait" true
    (Agent.pending_input agent = None);
  Alcotest.(check bool) "old answer cannot apply after terminal failure" true
    (Agent.provide_input agent pending Hooks.Declined = Error (Agent.Input_not_current Agent_input_request.No_pending_request))
;;

let with_input_checkpoint f =
  let path = Filename.temp_file "owned-input-checkpoint-" ".json" in
  Sys.remove path;
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () -> f path)
;;

let save_input_checkpoint path (snapshot : Agent.checkpoint_snapshot) =
  Alcotest.(check bool) "input transition has its own checkpoint boundary" true
    (snapshot.stage = Agent.After_input_wait_changed);
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () ->
    output_string channel (Checkpoint.to_string snapshot.checkpoint));
  Ok ()
;;

let read_input_checkpoint path =
  let channel = open_in_bin path in
  let bytes = Fun.protect ~finally:(fun () -> close_in channel)
      (fun () -> really_input_string channel (in_channel_length channel)) in
  Result.get_ok (Checkpoint.of_string bytes)
;;

let test_pause_survives_cleanup_and_answer_is_saved () =
  with_input_checkpoint @@ fun path ->
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let question : Hooks.elicitation_request = {question="canonical question";schema=None;timeout_s=None} in
  let options = {Agent.default_options with hooks={Hooks.empty with
    before_turn=Some (fun _ -> Hooks.ElicitInput question)}} in
  let agent = Agent.create ~net:env#net ~checkpoint_sink:(save_input_checkpoint path)
      ~config:(Types.default_config ~model:"input-only") ~options () in
  ignore (Agent.run ~sw agent "original");
  let pending = Option.get (Agent.pending_input agent) in
  Agent.close agent;
  let checkpoint = read_input_checkpoint path in
  Alcotest.(check bool) "first pause is durable without an AfterTurn" true
    (checkpoint.pending_input = Some pending);
  let restored = Agent.resume ~net:env#net ~checkpoint
      ~checkpoint_sink:(save_input_checkpoint path) () in
  let forged = {pending with request={pending.request with question="forged question"}} in
  Alcotest.(check bool) "response committed" true
    (Agent.provide_input restored forged (Hooks.Answer (`String "yes")) = Ok ());
  let current = read_input_checkpoint path in
  Alcotest.(check bool) "answer and settlement saved together" true
    (current.pending_input = None && current.messages = (Agent.state restored).messages);
  let last = List.hd (List.rev current.messages) in
  Alcotest.(check bool) "saved answer uses the canonical question" true
    (last.content = [Types.Text "[User input] canonical question: \"yes\""]);
  Agent.close restored
;;

let test_accepted_resume_persists_before_parameter_failure () =
  with_input_checkpoint @@ fun path ->
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let waiting = ref true in
  let question : Hooks.elicitation_request = {question="question";schema=None;timeout_s=None} in
  let options = {Agent.default_options with hooks={Hooks.empty with
    before_turn=Some (fun _ -> if !waiting then Hooks.ElicitInput question else Hooks.Continue);
    before_turn_params=Some (fun _ ->
      Alcotest.(check bool) "settlement already stored before parameters" true
        ((read_input_checkpoint path).pending_input = None);
      Hooks.HookFailed {stage=Hooks.Before_turn_params;detail="after input acceptance"})}} in
  let agent = Agent.create ~net:env#net ~checkpoint_sink:(save_input_checkpoint path)
      ~config:(Types.default_config ~model:"input-only") ~options () in
  ignore (Agent.run ~sw agent "original");
  waiting := false;
  let result = Agent.run_turn_stream ~sw ~on_event:ignore agent in
  Alcotest.(check bool) "parameter failure remains a failure" true (Result.is_error result);
  Agent.close agent;
  let restored = Agent.resume ~net:env#net ~checkpoint:(read_input_checkpoint path) () in
  Alcotest.(check bool) "cleanup and restore cannot resurrect the old wait" true
    (Agent.pending_input restored = None);
  Agent.close restored
;;

let test_input_sink_failure_preserves_owned_state () =
  with_input_checkpoint @@ fun path ->
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let refuse = ref false in
  let question : Hooks.elicitation_request = {question="question";schema=None;timeout_s=None} in
  let options = {Agent.default_options with hooks={Hooks.empty with
    before_turn=Some (fun _ -> Hooks.ElicitInput question)}} in
  let sink snapshot = if !refuse then Error "write refused" else save_input_checkpoint path snapshot in
  let agent = Agent.create ~net:env#net ~checkpoint_sink:sink
      ~config:(Types.default_config ~model:"input-only") ~options () in
  ignore (Agent.run ~sw agent "original");
  let pending = Option.get (Agent.pending_input agent) in
  let messages = (Agent.state agent).messages in
  refuse := true;
  Alcotest.(check bool) "response reports persistence failure" true
    (match Agent.provide_input agent pending (Hooks.Answer (`String "yes")) with
     | Error (Agent.Input_checkpoint_failed _) -> true
     | Error (Agent.Input_not_current _) | Ok () -> false);
  Alcotest.(check bool) "failed response preserves messages and wait" true
    ((Agent.state agent).messages = messages && Agent.pending_input agent = Some pending);
  let result = Agent.run_turn_stream ~sw ~on_event:ignore agent in
  Alcotest.(check bool) "replacement pause cannot claim a failed write" true
    (match result with
     | Error (Error.Agent (Error.InputRequired _)) | Ok _ -> false
     | Error _ -> true);
  Alcotest.(check bool) "original durable request remains" true
    ((read_input_checkpoint path).pending_input = Some pending && Agent.pending_input agent = Some pending);
  Agent.close agent
;;

let test_uncertain_input_commit_is_not_a_stale_response () =
  with_input_checkpoint @@ fun path ->
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let uncertain = ref false in
  let question : Hooks.elicitation_request = {question="question";schema=None;timeout_s=None} in
  let options = {Agent.default_options with hooks={Hooks.empty with
    before_turn=Some (fun _ -> Hooks.ElicitInput question)}} in
  let sink snapshot =
    let result = save_input_checkpoint path snapshot in
    if !uncertain then Error "write outcome requires host reconciliation" else result in
  let agent = Agent.create ~net:env#net ~checkpoint_sink:sink
      ~config:(Types.default_config ~model:"input-only") ~options () in
  ignore (Agent.run ~sw agent "original");
  let pending = Option.get (Agent.pending_input agent) in
  uncertain := true;
  Alcotest.(check bool) "uncertainty is an explicit checkpoint error" true
    (match Agent.provide_input agent pending Hooks.Declined with
     | Error (Agent.Input_checkpoint_failed _) -> true
     | Error (Agent.Input_not_current _) | Ok () -> false);
  Alcotest.(check bool) "an error does not assert external storage unchanged" true
    ((read_input_checkpoint path).pending_input = None && Agent.pending_input agent = Some pending);
  Agent.close agent
;;

let () =
  let open Alcotest in
  run
    "Elicitation"
    [ ( "durable input transitions"
      , [ test_case "first pause and canonical answer survive cleanup" `Quick test_pause_survives_cleanup_and_answer_is_saved
        ; test_case "accepted resume is saved before later failure" `Quick test_accepted_resume_persists_before_parameter_failure
        ; test_case "failed input writes preserve the original owner" `Quick test_input_sink_failure_preserves_owned_state
        ; test_case "uncertain writes require host reconciliation" `Quick test_uncertain_input_commit_is_not_a_stale_response ] )
    ; ( "owned current input"
      , [ test_case "rejected resume and stale response preserve current wait" `Quick test_current_wait_survives_rejection_and_replacement
        ; test_case "concurrent same-name runs and durable deltas" `Quick test_checkpoint_delta_retains_current_wait
        ; test_case "accepted low-level resume then failure consumes old wait" `Quick test_accepted_resume_failure_consumes_old_wait ] )
    ; ( "types"
      , [ test_case "request basic" `Quick test_elicitation_request_basic
        ; test_case "request with schema" `Quick test_elicitation_request_with_schema
        ; test_case "response answer" `Quick test_elicitation_response_answer
        ; test_case "response declined" `Quick test_elicitation_response_declined
        ; test_case "response timeout" `Quick test_elicitation_response_timeout
        ] )
    ; ( "hook_decision"
      , [ test_case "ElicitInput variant" `Quick test_hook_decision_elicit_input
        ; test_case "to_string" `Quick test_hook_decision_to_string
        ; test_case "ElicitToolApproval variant" `Quick test_hook_decision_tool_approval
        ; test_case
            "tool approval to_string"
            `Quick
            test_hook_decision_tool_approval_to_string
        ] )
    ; ( "callback"
      , [ test_case "answer" `Quick test_elicitation_callback_answer
        ; test_case "declined" `Quick test_elicitation_callback_declined
        ] )
    ; ( "event_bus"
      , [ test_case "publish/drain" `Quick test_event_bus_elicitation_completed
        ; test_case "filter_agent" `Quick test_event_bus_filter_agent
        ] )
    ; ( "agent_options"
      , [ test_case "default none" `Quick test_agent_options_elicitation_default ] )
    ; ( "agent_pause"
      , [ test_case
            "ElicitInput without callback returns InputRequired"
            `Quick
            test_agent_elicit_input_without_callback_pauses
        ] )
    ]
;;

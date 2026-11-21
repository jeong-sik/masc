open Agent_core
open Alcotest
module Internal = Agent_core__
module Runtime = Internal.Execution_runtime
module Codec = Internal.Execution_codec_executor
module Writer = Internal.Execution_lane_writer
module Scope = Internal.Execution_agent_scope
module Event = Internal.Execution_event

(* A durable response whose every tool call was admitted under its registered
   name, in provider order. *)
let all_admitted_snapshot (response : Llm_provider.Types.api_response)
  : Agent_core__.Execution_provider_response_snapshot.t =
  let count =
    List.length
      (List.filter
         (function
           | Llm_provider.Types.ToolUse _ -> true
           | Llm_provider.Types.Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
           | ToolResult _ | ToolReference _ | Image _ | Document _ | Audio _ -> false)
         response.content)
  in
  { Agent_core__.Execution_provider_response_snapshot.response
  ; admission =
      { Agent_core__.Execution_provider_response_snapshot.source_map =
          { Agent_core.Hooks.admitted_tool_sources =
              List.init count (fun index ->
                { Agent_core.Hooks.planned_index = index
                ; source_tool_use_ordinal = index
                ; name_resolution = Agent_core.Hooks.Registered_name
                })
          ; source_tool_use_count = count
          }
      ; unavailable_names = []
      ; unreadable = []
      }
  }
;;
module Projection = Agent.Execution_projection

let agent_name = "uncollected-turn"

let value = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let scope_value = function
  | Ok value -> value
  | Error error -> fail (Scope.error_to_string error)
;;

let writer_value = function
  | Ok value -> value
  | Error error -> fail (Writer.scope_failure_to_string error)
;;

let projection_value = function
  | Ok value -> value
  | Error error -> fail (Projection.error_to_string error)
;;

let binding () =
  value
    (Binding_identity.of_provider_config
       ~transport:Binding_identity.Injected
       (Llm_provider.Provider_config.make
          ~kind:Llm_provider.Provider_config.OpenAI_compat
          ~model_id:"uncollected-turn-test"
          ~base_url:"http://uncollected-turn.invalid"
          ~api_key:""
          ~request_path:"/v1/chat/completions"
          ()))
;;

let make_dir fs prefix =
  let native_path = Filename.temp_file prefix ".dir" in
  Sys.remove native_path;
  let dir = Eio.Path.(fs / native_path) in
  Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
  dir
;;

let public_locator scope =
  Scope.scope_locator scope
  |> Scope.scope_locator_to_yojson
  |> Agent.execution_locator_of_yojson
  |> value
;;

type fixture =
  { runtime : Agent.execution_runtime
  ; codec : Codec.t
  ; fs : Eio.Fs.dir_ty Eio.Path.t
  ; sw : Eio.Switch.t
  }

(* One journal directory and the run it holds. *)
type journal =
  { dir : Eio.Fs.dir_ty Eio.Path.t
  ; locator : Agent.execution_locator
  }

let with_fixture run =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let runtime =
    Agent.create_execution_runtime ~sw ~domain_mgr ~domain_count:1
    |> Result.map_error Error.to_string
    |> value
  in
  let internal_runtime =
    Runtime.create ~sw ~domain_mgr ~domain_count:1
    |> Result.map_error Runtime.create_error_to_string
    |> value
  in
  run { runtime; codec = Codec.of_runtime internal_runtime; fs = Eio.Stdenv.fs env; sw }
;;

let fresh_dir fixture =
  let dir = make_dir fixture.fs "agent_core-uncollected-turn-" in
  Eio.Switch.on_release fixture.sw (fun () -> Eio.Path.rmtree ~missing_ok:true dir);
  dir
;;

(* The writer is released without a terminal, as a process that died or was
   stopped leaves it. *)
let write_journal fixture shape =
  let dir = fresh_dir fixture in
  let locator =
    writer_value
      (Writer.run ~codec:fixture.codec ~dir (fun ~sw:_ writer ->
         let root = scope_value (Scope.start ~writer ~agent_name) in
         shape root;
         public_locator root))
  in
  { dir; locator }
;;

let settled_turn root ordinal =
  let turn = scope_value (Scope.open_turn root ~ordinal) in
  let provider = scope_value (Scope.open_provider_attempt turn ~ordinal:0 (binding ())) in
  scope_value (Scope.close_provider_attempt provider Event.Succeeded);
  scope_value (Scope.close_turn turn Event.Succeeded)
;;

let open_provider root ordinal =
  let turn = scope_value (Scope.open_turn root ~ordinal) in
  scope_value (Scope.open_provider_attempt turn ~ordinal:0 (binding ()))
;;

let response : Types.api_response =
  { id = "uncollected-reply"
  ; model = "fixture"
  ; stop_reason = Types.EndTurn
  ; content = [ Types.Text "recorded but never collected" ]
  ; unreadable_tool_uses = []
  ; usage = None
  ; telemetry = None
  }
;;

let invocation ~turn =
  Tool_contract.Invocation.create
    ~tool_use_id:"uncollected-tool-use"
    ~turn
    ~schedule:
      { Tool_contract.planned_index = 0
      ; batch_index = 0
      ; batch_size = 1
      ; execution_mode = Tool_contract.Serial
      }
    ~completion:Tool_contract.Continue_after_success
;;

let retire fixture ?(agent_name = agent_name) journal ~checkpoint_turn_count =
  Agent.retire_uncollected_turn
    ~runtime:fixture.runtime
    ~dir:journal.dir
    journal.locator
    ~agent_name
    ~checkpoint_turn_count
;;

let retire_value fixture journal ~checkpoint_turn_count =
  match retire fixture journal ~checkpoint_turn_count with
  | Ok retirement -> retirement
  | Error error -> fail (Agent.uncollected_turn_error_to_string error)
;;

let projection fixture journal =
  projection_value
    (Agent.open_execution_projection ~runtime:fixture.runtime ~dir:journal.dir journal.locator)
;;

let journal_seq fixture journal =
  Projection.cursor_seq (projection_value (Projection.current_cursor (projection fixture journal)))
;;

let check_cancelled_retire label (evidence : Agent.execution_terminal_evidence) =
  (match evidence.disposition with
   | { Agent.outcome = Terminal_cancelled; recovery = Retire } -> ()
   | { Agent.outcome = Terminal_succeeded | Terminal_failed | Terminal_cancelled; _ } ->
     fail (label ^ ": expected a cancelled terminal that retires"));
  check bool (label ^ ": no Tool attempt") false evidence.has_tool_attempts;
  check int (label ^ ": no settled result") 0 (List.length evidence.settled_tool_results)
;;

let check_retired fixture journal ~checkpoint_turn_count =
  (match retire_value fixture journal ~checkpoint_turn_count with
   | Agent.Retired evidence -> check_cancelled_retire "returned evidence" evidence
   | Agent.Not_uncollected -> fail "the cut turn was not retired");
  match projection_value (Agent.read_execution_terminal (projection fixture journal)) with
  | Some evidence -> check_cancelled_retire "journal after reopen" evidence
  | None -> fail "the retired run has no terminal in its journal"
;;

let check_untouched fixture journal ~checkpoint_turn_count =
  let before = journal_seq fixture journal in
  (match retire_value fixture journal ~checkpoint_turn_count with
   | Agent.Not_uncollected -> ()
   | Agent.Retired _ -> fail "a run that is not a cut turn was retired");
  check int "nothing was written" before (journal_seq fixture journal)
;;

let test_retires_open_attempt_without_response () =
  with_fixture @@ fun fixture ->
  let journal =
    write_journal fixture (fun root ->
      settled_turn root 0;
      ignore (open_provider root 1 : Scope.provider_attempt))
  in
  check_retired fixture journal ~checkpoint_turn_count:1
;;

let test_retires_open_attempt_with_recorded_response () =
  with_fixture @@ fun fixture ->
  let journal =
    write_journal fixture (fun root ->
      let provider = open_provider root 0 in
      scope_value (Scope.record_provider_response provider (all_admitted_snapshot response)))
  in
  check_retired fixture journal ~checkpoint_turn_count:0
;;

let test_second_call_leaves_the_closed_run () =
  with_fixture @@ fun fixture ->
  let journal =
    write_journal fixture (fun root -> ignore (open_provider root 0 : Scope.provider_attempt))
  in
  check_retired fixture journal ~checkpoint_turn_count:0;
  check_untouched fixture journal ~checkpoint_turn_count:0
;;

let test_other_checkpoint_turn_counts_leave_the_run () =
  with_fixture @@ fun fixture ->
  let journal =
    write_journal fixture (fun root ->
      settled_turn root 0;
      ignore (open_provider root 1 : Scope.provider_attempt))
  in
  (* A collected response moves the checkpoint past the open turn. *)
  check_untouched fixture journal ~checkpoint_turn_count:2;
  check_untouched fixture journal ~checkpoint_turn_count:0;
  check_retired fixture journal ~checkpoint_turn_count:1
;;

let test_shapes_without_an_open_attempt_are_left () =
  with_fixture @@ fun fixture ->
  let no_turn = write_journal fixture (fun _root -> ()) in
  check_untouched fixture no_turn ~checkpoint_turn_count:0;
  let no_attempt =
    write_journal fixture (fun root ->
      ignore (scope_value (Scope.open_turn root ~ordinal:0) : Scope.turn))
  in
  check_untouched fixture no_attempt ~checkpoint_turn_count:0;
  let settled_attempt =
    write_journal fixture (fun root ->
      let turn = scope_value (Scope.open_turn root ~ordinal:0) in
      let provider = scope_value (Scope.open_provider_attempt turn ~ordinal:0 (binding ())) in
      scope_value (Scope.close_provider_attempt provider Event.Succeeded))
  in
  check_untouched fixture settled_attempt ~checkpoint_turn_count:0
;;

let test_attempt_with_invocation_is_left () =
  with_fixture @@ fun fixture ->
  let journal =
    write_journal fixture (fun root ->
      let provider = open_provider root 0 in
      ignore
        (scope_value
           (Scope.open_invocation
              provider
              ~invocation:(invocation ~turn:0)
              ~tool_name:"uncollected-tool"
              ~input:(`Assoc []))
         : Scope.invocation))
  in
  check_untouched fixture journal ~checkpoint_turn_count:0
;;

let test_other_agent_name_is_an_error () =
  with_fixture @@ fun fixture ->
  let journal =
    write_journal fixture (fun root -> ignore (open_provider root 0 : Scope.provider_attempt))
  in
  let before = journal_seq fixture journal in
  (match retire fixture ~agent_name:"another-agent" journal ~checkpoint_turn_count:0 with
   | Error _ -> ()
   | Ok _ -> fail "a run of another Agent was judged");
  check int "nothing was written" before (journal_seq fixture journal)
;;

let test_live_writer_is_an_error () =
  with_fixture @@ fun fixture ->
  let dir = fresh_dir fixture in
  let locator =
    writer_value
      (Writer.run ~codec:fixture.codec ~dir (fun ~sw:_ writer ->
         let root = scope_value (Scope.start ~writer ~agent_name) in
         ignore (open_provider root 0 : Scope.provider_attempt);
         let locator = public_locator root in
         (match retire fixture { dir; locator } ~checkpoint_turn_count:0 with
          | Error _ -> ()
          | Ok _ -> fail "a run with a live writer was judged");
         locator))
  in
  (* The live writer is gone now; the same run is still the cut shape. *)
  check_retired fixture { dir; locator } ~checkpoint_turn_count:0
;;

let () =
  run
    "agent_uncollected_turn"
    [ ( "retire"
      , [ test_case "open attempt without response" `Quick
            test_retires_open_attempt_without_response
        ; test_case "open attempt with recorded response" `Quick
            test_retires_open_attempt_with_recorded_response
        ; test_case "second call leaves the closed run" `Quick
            test_second_call_leaves_the_closed_run
        ] )
    ; ( "leave"
      , [ test_case "other checkpoint turn counts" `Quick
            test_other_checkpoint_turn_counts_leave_the_run
        ; test_case "no open provider attempt" `Quick
            test_shapes_without_an_open_attempt_are_left
        ; test_case "attempt with a Tool invocation" `Quick
            test_attempt_with_invocation_is_left
        ] )
    ; ( "error"
      , [ test_case "other Agent name" `Quick test_other_agent_name_is_an_error
        ; test_case "live writer" `Quick test_live_writer_is_an_error
        ] )
    ]
;;

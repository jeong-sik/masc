let frozen_librarian_position point : Masc.Keeper_turn_driver_try_provider.librarian_position =
  let snapshot=match point with
    | Masc.Keeper_turn_driver_try_provider.Librarian_snapshot snapshot -> snapshot.unread_messages
    | Masc.Keeper_turn_driver_try_provider.Librarian_progress _ | Masc.Keeper_turn_driver_try_provider.No_position -> [] in
  {point;unread=Masc.Keeper_librarian_request_unread.of_results ~snapshot:(Ok snapshot) ~memory:(Ok [])}
;;

(* Drive the production Keeper adapter through fresh and resumed native
   requests. The fixture observes transport input, not model understanding. *)
open Alcotest
open Masc

let unavailable_native_unread = Keeper_librarian_request_unread.of_results
    ~snapshot:(Error "fixture has no snapshot reader")
    ~memory:(Error "fixture has no Memory reader")
;;

let write path value = Out_channel.with_open_bin path (fun out -> output_string out value)
let member = Yojson.Safe.Util.member
let text = Yojson.Safe.Util.to_string
let items = Yojson.Safe.Util.to_list
let require = function Ok value -> value | Error detail -> fail detail

let fixture root ~reject_context ~overflow_resume ~hold_first_resume ~compact_resume ~compact_item ~checkpoint_tool =
  let capture = Filename.concat root "requests.jsonl" in
  write capture "";
  let command = Filename.concat root "codex-fixture" in
  write command (Printf.sprintf {|#!/usr/bin/env python3
import json, sys, os
if '--masc-warmup' in sys.argv:
    sys.exit(0)
capture = %S
with open(capture+'.argv', 'a') as out:
    out.write(json.dumps(sys.argv[1:])+'\n')
reject_context = %s
overflow_resume = %s
hold_first_resume = %s
compact_resume = %s
compact_item = %s
checkpoint_tool = %s
turn_id = 'fresh-turn'
def emit(value):
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    with open(capture, 'a') as out:
        out.write(json.dumps(request)+'\n')
    method, ident = request.get('method'), request.get('id')
    if method == 'initialize':
        emit({'id':ident,'result':{'userAgent':'fixture/0.147.0','codexHome':'/tmp/codex','platformFamily':'unix','platformOs':'linux'}})
    elif method == 'account/read':
        emit({'id':ident,'result':{'account':{'type':'chatgpt','email':'fixture@example.test','planType':'pro'},'requiresOpenaiAuth':True}})
    elif method in ('thread/start', 'thread/resume'):
        if method == 'thread/resume':
            turn_id = 'resumed-turn'
        emit({'id':ident,'result':{'thread':{'id':'context-thread'},'model':'context-fixture'}})
    elif method == 'thread/inject_items':
        if reject_context:
            emit({'id':ident,'error':{'code':-32602,'message':'fixture rejected current context'}})
        else:
            emit({'id':ident,'result':{}})
    elif method == 'turn/start':
        hold_this_turn = hold_first_resume and turn_id == 'resumed-turn' and not os.path.exists(capture+'.held')
        if hold_this_turn:
            with open(capture+'.held', 'w') as out:
                out.write('turn accepted; terminal withheld')
        emit({'id':ident,'result':{'turn':{'id':turn_id}}})
        if hold_this_turn:
            continue
        if checkpoint_tool and not os.path.exists(capture+'.checkpointed'):
            with open(capture+'.checkpointed', 'w') as out:
                out.write('original tool boundary reached')
            emit({'id':'checkpoint-call','method':'item/tool/call','params':{'threadId':'context-thread','turnId':turn_id,'callId':'checkpoint-call','tool':'CheckpointFixture','namespace':None,'arguments':{}}})
            continue
        if overflow_resume and turn_id == 'resumed-turn' and not os.path.exists(capture+'.overflowed'):
            with open(capture+'.overflowed', 'w') as out:
                out.write('rejected before effects')
            emit({'method':'turn/completed','params':{'threadId':'context-thread','turn':{'id':turn_id,'items':[],'status':'failed','error':{'message':'context is full','codexErrorInfo':'contextWindowExceeded'}}}})
            continue
        if compact_resume and turn_id == 'resumed-turn' and not os.path.exists(capture+'.compacted'):
            with open(capture+'.compacted', 'w') as out:
                out.write('compaction followed by another model response')
            request_usage = {'inputTokens':100,'cachedInputTokens':0,'outputTokens':10,'reasoningOutputTokens':0,'totalTokens':110}
            estimate = {'inputTokens':0,'cachedInputTokens':0,'outputTokens':0,'reasoningOutputTokens':0,'totalTokens':50}
            if compact_item:
                emit({'method':'item/completed','params':{'threadId':'context-thread','turnId':turn_id,
                     'item':{'type':'contextCompaction','id':'compact-1'}}})
            for last in ((request_usage,) if compact_item else (estimate, request_usage)):
                emit({'method':'thread/tokenUsage/updated','params':{'threadId':'context-thread','turnId':turn_id,
                     'tokenUsage':{'last':last,'total':request_usage,'modelContextWindow':400000}}})
        item = {'type':'agentMessage','id':'answer','text':'CONTEXT_RECEIVED','phase':'final_answer'}
        emit({'method':'item/completed','params':{'threadId':'context-thread','turnId':turn_id,'completedAtMs':1,'item':item}})
        emit({'method':'turn/completed','params':{'threadId':'context-thread','turn':{'id':turn_id,'items':[item],'status':'completed'}}})
|} capture (if reject_context then "True" else "False")
    (if overflow_resume then "True" else "False")
    (if hold_first_resume then "True" else "False")
    (if compact_resume then "True" else "False")
    (if compact_item then "True" else "False")
    (if checkpoint_tool then "True" else "False"));
  Unix.chmod command 0o700;
  command, capture

let with_fixture ?(worker_pool = false) ?(reject_context = false) ?(overflow_resume = false) ?(hold_first_resume = false) ?(compact_resume = false) ?(compact_item = false) ?(checkpoint_tool = false) ?catalog_context_window test =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let previous_pool = Domain_pool_ref.get () in
  Eio.Switch.on_release sw (fun () ->
    match previous_pool with
    | None -> Domain_pool_ref.clear_for_tests ()
    | Some pool -> Domain_pool_ref.set pool);
  if worker_pool then
    Domain_pool_ref.set (Domain_pool.create ~sw ~domain_count:1 env#domain_mgr)
  else Domain_pool_ref.clear_for_tests ();
  Eio_context.set_env env;
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let root = Filename.temp_file "masc-codex-current-context-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  (* #36066: the posture resolve reads the keeper's declaration before the
     client is spawned, so the fixture keeper is declared. *)
  Masc_test_deps.declare_fixture_keeper
    ~base_path:root ~sandbox_profile:None "context-fixture";
  let saved = Runtime.For_testing.snapshot () in
  Eio.Switch.on_release sw (fun () -> Runtime.For_testing.restore saved; Fs_compat.remove_tree root);
  let command, capture = fixture root ~reject_context ~overflow_resume ~hold_first_resume ~compact_resume ~compact_item ~checkpoint_tool in
  let config_path = Filename.concat root "runtime.toml" in
  let write_catalog max_context =
    write config_path (Printf.sprintf {|
[providers.codex]
protocol = "codex-app-server"
command = %S
is-non-interactive = true
[models.context]
api-name = "context-fixture"
max-context = %d
[codex.context]
[runtime]
default = "codex.context"
|} command max_context) in
  write_catalog 400000;
  Runtime.init_default ~config_path |> require;
  let runtime = Runtime.get_runtime_by_id "codex.context" |> Option.get in
  let config = match runtime.execution with
    | Runtime_execution.Codex_app_server config -> config
    | _ -> fail "fixture runtime missing" in
  Option.iter (fun window ->
    write_catalog window;
    Runtime.init_default ~config_path |> require) catalog_context_window;
  let reports = ref [] in
  let run ?argument_source ?official_task_reference ?model_input_projection ?prompt_blocks
      ?(tools=[]) ?tool_choice
      ?carried_front_seed ?librarian_front ?on_model_input_window_observation
      ?(turn_start = Keeper_carried_front.Turn_boundary { end_atom = 0 })
      ?(initial_messages=[Agent_core.Types.user_msg "Previous completed work"])
      ?official_client_continuation ?on_event ?on_official_client_tool_boundary
      ?(goal="Continue from current World State.") ~instructions ~world () =
    let composed_context = ref None in
    let hooks = { Agent_core.Hooks.empty with before_turn_params = Some (function
      | Agent_core.Hooks.BeforeTurnParams {current_params;_} ->
        (* Production records the block witness in this hook. Reading it before
           preparation would observe None and silently resend the carrier. *)
        composed_context := Option.map (fun blocks ->
          (Keeper_context_assembly.assemble ~dynamic_context_partition:None ~existing_extra_system_context:None ~blocks)) prompt_blocks;
        Agent_core.Hooks.AdjustParams {current_params with extra_system_context=Some world;tool_choice}
      | _ -> Agent_core.Hooks.Continue) } in
    Keeper_codex_runtime.run ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "context-fixture" })
      ?argument_source
      ~context_window:(Some (Runtime_instance.max_context_of_runtime runtime))
      ~composed_context:(fun () -> !composed_context)
        ~accepts_image_input:(Runtime_agent.runtime_accepts_image_input
          ~runtime) ~runtime_id:"codex.context" ~keeper_name:"context-fixture"
      ~turn_start
      ?carried_front_seed ?librarian_front
      ?on_model_input_window_observation
      ~pre_tool_rejects:(ref []) ~base_path:root ~media_store:(Tool_blob_media_store.of_base_path ~base_path:root) ~goal ?official_task_reference ?official_client_continuation
      ?on_official_client_tool_boundary
      ~goal_blocks:None ~system_prompt:instructions ~tools
      ~initial_messages
      ~model_input_projection ~on_transmitted_model_input:(fun report -> reports := report :: !reports)
      ~hooks:(Some hooks) ~context_injector:None ~context:(Some (Agent_core.Context.create ()))
      ~event_bus:None ~raw_trace:None ~on_event ~config ()
  in
  test ~run ~capture ~reports

let read_requests path = In_channel.with_open_bin path In_channel.input_lines
  |> List.map Yojson.Safe.from_string

let successful attempt = match attempt.Keeper_codex_runtime.result with
  | Ok result ->
    (match attempt.pending_result_receipts with
     | None -> ()
     | Some pending -> Keeper_client_tool_outbox.settle_consumption pending
         ~stop_reason:result.Runtime_agent.stop_reason |> require)
  | Error error -> fail (Agent_core.Error.to_string error)

let test_captured_context_window_survives_catalog_reload () =
  with_fixture ~catalog_context_window:800000 @@ fun ~run ~capture ~reports:_ ->
  check (option int) "catalog was reloaded" (Some 800000)
    (Runtime.max_context_of_runtime_id "codex.context");
  successful (run ~instructions:"Follow the current context." ~world:"First turn" ());
  successful (run ~instructions:"Follow the current context." ~world:"Next turn" ());
  let invocations = In_channel.with_open_bin (capture ^ ".argv") In_channel.input_lines in
  check int "fresh and resumed processes" 2 (List.length invocations);
  List.iter (fun line ->
    let argv = Yojson.Safe.from_string line |> items |> List.map text in
    check bool "selected snapshot window reaches the process" true
      (List.mem "model_context_window=400000" argv);
    check bool "reloaded window does not reach the selected process" false
      (List.mem "model_context_window=800000" argv)) invocations;
  let methods = read_requests capture |> List.map (fun request -> request |> member "method" |> text) in
  check bool "fresh thread started" true (List.mem "thread/start" methods);
  check bool "existing thread resumed" true (List.mem "thread/resume" methods)

let test_operator_interrupt_preserves_previous_native_settlement () =
  with_fixture ~hold_first_resume:true @@ fun ~run ~capture ~reports:_ ->
  let base_path = Filename.dirname capture in
  let load_state () =
    match Keeper_official_client_session_store.load
            ~base_path ~keeper_name:"context-fixture"
          |> Result.map_error Keeper_official_client_session_store.read_error_to_string with
    | Ok (Some state) -> state
    | Ok None -> fail "Codex native session state disappeared"
    | Error detail -> fail detail
  in
  let original_task = "FIRST_SENTINEL_INPUT" in
  successful (run ~goal:original_task ~instructions:"Keeper instructions"
    ~world:"Original context" ());
  let original = load_state () in
  let operation_id =
    Keeper_chat_operation.Operation_id.of_string "codex-interrupted-original"
    |> require in
  let seed =
    match Keeper_semantic_execution.create
      ~id:(Keeper_execution_scope_id.direct_operation operation_id)
      ~input:(`String original_task) ~sources:[] ~now:1. with
    | Ok value -> value
    | Error error -> fail (Keeper_semantic_execution.error_to_string error)
  in
  let observed : Keeper_semantic_execution.official_client_checkpoint =
    match original.phase with
    | Keeper_official_client_session_store.Settled { session_id; turn_id } ->
      { client_kind = original.client_kind; runtime_id = original.runtime_id;
        session_id; turn_id; tool_surface_sha256 = original.tool_surface_sha256;
        frame = seed.frame }
    | _ -> fail "original Codex turn did not settle"
  in
  let admitted, resolve_admitted = Eio.Promise.create () in
  let interrupt_newer () = Eio.Switch.run @@ fun turn_sw ->
     Eio.Fiber.fork ~sw:turn_sw (fun () ->
       Eio_context.with_turn_switch turn_sw (fun () ->
         let attempt =
           run ~goal:"NEWER" ~instructions:"Keeper instructions"
             ~world:"Newer context"
             ~on_event:(function
               | Agent_core.Types.MessageStart _ ->
                 Eio.Promise.resolve resolve_admitted ()
               | _ -> ()) ()
         in
         successful attempt;
         fail "newer Codex turn completed despite withheld terminal"));
     Eio.Promise.await admitted;
     (match (load_state ()).phase with
      | Keeper_official_client_session_store.Turn_inflight _ -> ()
      | _ -> fail "newer Codex turn was not durably admitted");
     Eio.Switch.fail turn_sw Keeper_registry_types.Operator_interrupt
  in
  let env = Option.get (Eio_context.get_env_opt ()) in
  (match Eio.Time.with_timeout_exn env#clock 30. interrupt_newer with
   | exception exn when Keeper_registry_types.is_operator_interrupt exn -> ()
   | exception exn -> fail (Printexc.to_string exn)
   | () -> fail "operator stop did not cancel the admitted Codex turn");
  let restored = load_state () in
  check bool "operator interruption restores prior Codex settlement" true
    (restored.phase = original.phase);
  (match restored.last_transient_release with
   | Some release ->
     check bool "typed owner stop was recorded" true
       (release.failure = Keeper_official_client_session_store.Owner_stopped_turn)
   | None -> fail "Codex owner stop release evidence was not persisted");
  let checkpoint =
    Keeper_direct_checkpoint_continuation.For_testing.prepare_official_resume
      ~observed ~expected:(Some restored) |> require in
  check string "previous Codex checkpoint remains resumable"
    observed.turn_id checkpoint.turn_id;
  let official_task_reference =
    Keeper_official_task_reference.create
      ~operation_id ~message:original_task ~original_turn:observed in
  let before = List.length (read_requests capture) in
  let continuation_goal =
    Keeper_direct_checkpoint_continuation.official_resume_message
      ~operation_id in
  successful
    (run ~official_task_reference ~official_client_continuation:checkpoint
       ~goal:continuation_goal
       ~instructions:"Keeper instructions" ~world:"Resumed original context" ());
  let resumed_wire =
    read_requests capture
    |> List.filteri (fun index _ -> index >= before)
  in
  let requests method_ =
    List.filter (fun row -> member "method" row = `String method_) resumed_wire
  in
  check int "original continuation resumed its native thread" 1
    (List.length (requests "thread/resume"));
  check int "original continuation submitted one new turn" 1
    (List.length (requests "turn/start"));
  check int "continuation did not create a new native thread" 0
    (List.length (requests "thread/start"));
  check int "continuation did not replay history" 0
    (List.length (requests "thread/inject_items"));
  let resumed_thread =
    List.hd (requests "thread/resume")
    |> member "params" |> member "threadId" |> text in
  check string "original Codex session identity" observed.session_id resumed_thread;
  let resumed_input =
    List.hd (requests "turn/start")
    |> member "params" |> member "input" |> items
    |> List.hd |> member "text" |> text in
  check bool "original task is carried as a historical reference" true
    (String_util.contains_substring resumed_input
       "masc.official-client-historical-task.v1");
  check bool "continuation ends with the remaining-work instruction" true
    (String.ends_with ~suffix:("\n\n" ^ continuation_goal) resumed_input)

let turn_text rows =
  List.find (fun row -> member "method" row = `String "turn/start") rows
  |> member "params" |> member "input" |> items |> List.hd |> member "text" |> text

let test_resume_carries_per_turn_context_in_front_of_the_goal ?(worker_pool = false) () =
  (* The thread holds the conversation, so a Resume sends none of it. The
     per-turn context goes in front of the goal, as the Claude Code lane sends
     it, and stays out of [developerInstructions], which Codex applies only
     when it compacts the thread. *)
  with_fixture ~worker_pool @@ fun ~run ~capture ~reports ->
  successful (run ~instructions:"Keeper revision 1: publish the first artifact."
    ~world:"World State: task-001 done; goal awaiting confirmation." ());
  let first_requests = read_requests capture in
  successful (run ~instructions:"Keeper revision 2: continue remaining assigned work."
    ~world:"World State: task-003 todo; autonomous-collaboration-continuation executing." ());
  let requests = read_requests capture in
  let resumed = List.filteri (fun index _ -> index >= List.length first_requests) requests in
  let methods rows = List.filter_map (fun row -> match member "method" row with
      | `String method_ -> Some method_ | _ -> None) rows in
  check (list string) "a resume submits its turn and writes no thread items"
    ["initialize";"initialized";"account/read";"thread/resume";"turn/start"]
    (methods resumed);
  let params method_ rows = List.find (fun row -> member "method" row = `String method_) rows |> member "params" in
  check string "same vendor session retained" "context-thread"
    (params "thread/resume" resumed |> member "threadId" |> text);
  let sent = turn_text resumed in
  check bool "the autonomous cue ends the turn input" true
    (String.ends_with ~suffix:"\n\nContinue from current World State." sent);
  check bool "the current world frame rides in front of the goal" true
    (String_util.contains_substring sent "task-003 todo");
  check bool "the old world frame is not sent again" false
    (String_util.contains_substring sent "task-001 done");
  check bool "the turn input carries no earlier conversation" false
    (String_util.contains_substring sent "Previous completed work");
  let instructions rows method_ = params method_ rows |> member "developerInstructions" |> text in
  let resumed_instructions = instructions resumed "thread/resume" in
  check bool "resume names the current instructions" true
    (String.starts_with ~prefix:"Keeper revision 2:" resumed_instructions);
  check bool "the per-turn context stays out of the instructions" false
    (String_util.contains_substring resumed_instructions "task-003 todo");
  check bool "the instructions carry no conversation" false
    (String_util.contains_substring resumed_instructions "Previous completed work");
  let initial = params "thread/inject_items" first_requests |> member "items" |> items in
  check (list string) "persistent seed contains conversation only"
    ["user"] (List.map (fun item -> member "role" item |> text) initial);
  let started_instructions = instructions first_requests "thread/start" in
  check bool "start carries original instructions" true
    (String.starts_with ~prefix:"Keeper revision 1:" started_instructions);
  check bool "start context is configuration" true
    (String_util.contains_substring started_instructions "task-001 done");
  (match List.rev !reports with
   | [Keeper_official_client_host.Whole_input_transmitted _;
      Keeper_official_client_host.Held_by_client_session] -> ()
   | _ -> fail "a Start transmits its prepared context; a Resume leaves the conversation to the thread")

let test_resume_deduplicates_context_blocks () =
  with_fixture @@ fun ~run ~capture ~reports:_ ->
  let instructions = "Keeper instructions" in
  let send ~memory ~world ~clock =
    let prompt_blocks =
      [ Prompt_block_id.Memory_os_recall, memory
      ; Prompt_block_id.Dynamic_context, world
      ; Prompt_block_id.Temporal_summary, clock
      ; Prompt_block_id.Operator_note, "OPERATOR_NOTE"
      ] in
    let before = List.length (read_requests capture) in
    successful (run ~instructions ~prompt_blocks
      ~world:(String.concat "\n\n" (List.map snd prompt_blocks)) ());
    read_requests capture |> List.filteri (fun i _ -> i >= before)
  in
  let first = send ~memory:"RECALL_A" ~world:"WORLD_1" ~clock:"CLOCK_1" in
  check bool "fresh thread receives recall" true
    (String_util.contains_substring (Yojson.Safe.to_string (`List first)) "RECALL_A");
  let check_resume rows expected =
    check int "same session resumes" 1
      (List.length (List.filter (fun row -> member "method" row = `String "thread/resume") rows));
    let sent = turn_text rows in
    List.iter (fun (marker, present) ->
      check bool marker present (String_util.contains_substring sent marker)) expected;
    check bool "operator note is delivered even unchanged" true
      (String_util.contains_substring sent "OPERATOR_NOTE")
  in
  let second = send ~memory:"RECALL_A" ~world:"WORLD_2" ~clock:"CLOCK_2" in
  check_resume second [ "RECALL_A", false; "WORLD_2", true; "CLOCK_2", true ];
  let third = send ~memory:"RECALL_B" ~world:"WORLD_2" ~clock:"CLOCK_3" in
  check_resume third [ "RECALL_A", false; "RECALL_B", true; "WORLD_2", false; "CLOCK_3", true ];
  let fourth = send ~memory:"RECALL_B" ~world:"WORLD_3" ~clock:"CLOCK_4" in
  check_resume fourth [ "RECALL_B", false; "WORLD_3", true; "CLOCK_4", true ]

let test_context_blocks_survive_fresh_retry () =
  with_fixture ~overflow_resume:true @@ fun ~run ~capture ~reports:_ ->
  let send world =
    let prompt_blocks =
      [ Prompt_block_id.Memory_os_recall, "RECALL_RETRY"
      ; Prompt_block_id.Dynamic_context, world ] in
    let before = List.length (read_requests capture) in
    successful (run ~instructions:"Keeper instructions" ~prompt_blocks
      ~world:(String.concat "\n\n" (List.map snd prompt_blocks)) ());
    read_requests capture |> List.filteri (fun i _ -> i >= before)
  in
  ignore (send "WORLD_1");
  let retried = send "WORLD_2" in
  check bool "overflowing resume omits held recall" false
    (String_util.contains_substring (turn_text retried) "RECALL_RETRY");
  let fresh = List.find (fun row -> member "method" row = `String "thread/start") retried in
  check bool "replacement thread receives recall" true
    (String_util.contains_substring
       (fresh |> member "params" |> member "developerInstructions" |> text) "RECALL_RETRY");
  check bool "settled replacement remembers the recall" false
    (String_util.contains_substring (turn_text (send "WORLD_3")) "RECALL_RETRY")

let check_compaction_receipt_survives_later_request_usage ~compact_item () =
  with_fixture ~compact_resume:true ~compact_item @@ fun ~run ~capture ~reports:_ ->
  List.iteri (fun index recall_expected ->
    let prompt_blocks =
      [ Prompt_block_id.Memory_os_recall, "RECALL_AFTER_COMPACTION"
      ; Prompt_block_id.Temporal_summary, Printf.sprintf "COMPACTION_TICK_%d" index ] in
    let before = List.length (read_requests capture) in
    successful (run ~instructions:"Keeper instructions" ~prompt_blocks
      ~world:(String.concat "\n\n" (List.map snd prompt_blocks)) ());
    let rows = read_requests capture |> List.filteri (fun i _ -> i >= before) in
    let sent = if index = 0 then Yojson.Safe.to_string (`List rows) else turn_text rows in
    check bool "compacted session receives recall again despite later request usage"
      recall_expected (String_util.contains_substring sent "RECALL_AFTER_COMPACTION");
    if index > 0 then
      check int "compaction does not require a new thread" 1
        (List.length (List.filter (fun row -> member "method" row = `String "thread/resume") rows)))
    [true; false; true; false]

let test_compaction_receipt_survives_later_request_usage () =
  check_compaction_receipt_survives_later_request_usage ~compact_item:false ()

let test_compaction_item_invalidates_recall_without_usage_estimate () =
  check_compaction_receipt_survives_later_request_usage ~compact_item:true ()

let test_recall_lifecycle_across_native_ticks () =
  with_fixture @@ fun ~run ~capture ~reports:_ ->
  let module Current = Keeper_memory_os_current in
  let module Memory = Keeper_memory_os_types in
  let keepers_dir = Filename.concat (Filename.dirname capture) "recall-store" in
  Unix.mkdir keepers_dir 0o700;
  let keeper_id = "context-fixture" in
  let path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let fact claim : Memory.fact =
    { claim; category = Constraint; first_seen = 1.; last_seen = 1.
    ; origin = { kind = Authored; trace_id = "recall-cycle" }
    ; basis = Observed Transcript } in
  let replace ?(now = 1.) expected_revision facts =
    match Current.replace ~keepers_dir ~keeper_id ~expected_revision
      ~now ~source:{kind = Librarian; trace_id = "recall-cycle"} ~facts () with
    | Ok _ -> ()
    | Error _ -> fail "fixture could not replace the committed memory"
  in
  let tick = ref 0 in
  let send ~changed =
    incr tick;
    let recall = Keeper_memory_os_recall.render_context ~keepers_dir ~keeper_id () in
    check bool "current memory availability is explicit" true (recall <> "");
    let clock = Printf.sprintf "CYCLE_TICK_%d" !tick in
    let prompt_blocks =
      [ Prompt_block_id.Memory_os_recall, recall
      ; Prompt_block_id.Temporal_summary, clock ] in
    let before = List.length (read_requests capture) in
    successful (run ~instructions:"Keeper instructions" ~prompt_blocks
      ~world:(String.concat "\n\n" (List.map snd prompt_blocks)) ());
    let rows = read_requests capture |> List.filteri (fun i _ -> i >= before) in
    let sent = if !tick = 1 then
        List.find (fun row -> member "method" row = `String "thread/start") rows
        |> member "params" |> member "developerInstructions" |> text
      else (
        check int "subsequent tick resumes the same session" 1
          (List.length (List.filter (fun row -> member "method" row = `String "thread/resume") rows));
        turn_text rows)
    in
    (* The model receives the encoded context envelope. Compare its text
       against the actual rendered snapshot rather than estimating tokens. *)
    let encoded = Yojson.Safe.to_string (`String recall) in
    let body = String.sub encoded 1 (String.length encoded - 2) in
    check bool (Printf.sprintf "tick %d delivers exactly when state changes" !tick)
      changed (String_util.contains_substring sent body);
    check bool "the current tick still reaches the model" true
      (String_util.contains_substring sent clock);
    recall
  in
  replace None [fact "CURRENT_FACT_A"];
  let original_file = Fs_compat.load_file path in
  let present = send ~changed:true in
  ignore (send ~changed:false);
  replace (Some 1) [fact "CURRENT_FACT_B"];
  let revised = send ~changed:true in
  check bool "revised memory changes the delivered state" true (present <> revised);
  replace (Some 2) [];
  let empty_file = Fs_compat.load_file path in
  let cleared = send ~changed:true in
  check bool "cleared snapshot carries no previous claim" false
    (String_util.contains_substring cleared "CURRENT_FACT_");
  ignore (send ~changed:false);
  write path "{broken snapshot";
  let unavailable = send ~changed:true in
  check bool "read failure is distinct from authoritative empty memory" true
    (unavailable <> cleared);
  ignore (send ~changed:false);
  write path empty_file;
  check string "recovery re-delivers the same empty snapshot" cleared (send ~changed:true);
  Unix.unlink path;
  let absent = send ~changed:true in
  check bool "missing snapshot is distinct from a failed read" true (absent <> unavailable);
  ignore (send ~changed:false);
  write path original_file;
  check string "returning to an earlier snapshot re-delivers it" present (send ~changed:true);
  (* Each Librarian pass can commit unchanged facts with a new revision/time.
     That bookkeeping and the changing clock must not append another Recall.
     This is a test horizon, not a runtime deduplication gate. *)
  for revision = 1 to 16 do
    replace ~now:(float_of_int (100 + revision)) (Some revision) [fact "CURRENT_FACT_A"];
    ignore (send ~changed:false)
  done;
  (match Keeper_official_client_session_store.load
      ~base_path:(Filename.dirname capture) ~keeper_name:keeper_id with
   | Ok (Some {context_frontier = Some frontier; _}) ->
     let contexts = List.map
       (fun (held : Keeper_official_client_session_store.held_context) -> held.context)
       frontier.held_context in
     let module Store = Keeper_official_client_session_store in
     check bool "delivery receipts contain only the two blocks and frozen unread identity" true
       (List.sort_uniq Stdlib.compare contexts =
        List.sort Stdlib.compare
          [Store.Context_block Prompt_block_id.Memory_os_recall;
           Store.Context_block Prompt_block_id.Temporal_summary; Store.Librarian_unread]);
     check int "repeated ticks retain one receipt per context identity" 3
       (List.length frontier.held_context)
   | Ok _ | Error _ -> fail "settled native session lost its context frontier")

let test_rejected_context_never_submits_turn () =
  with_fixture ~reject_context:true @@ fun ~run ~capture ~reports ->
  let attempt = run ~instructions:"Keeper current instructions" ~world:"World State: task-003 todo" () in
  check bool "context rejection is a failed turn" true (Result.is_error attempt.Keeper_codex_runtime.result);
  check bool "no model turn after rejected context" false
    (List.exists (fun row -> member "method" row = `String "turn/start") (read_requests capture));
  check int "rejected context never reports transmitted turn input" 0 (List.length !reports)

let test_cooperative_resume_sends_only_remaining_work_instruction () =
  with_fixture @@ fun ~run ~capture ~reports:_ ->
  let original_task = "Create the requested artifact and report its path." in
  let initial = run ~goal:original_task ~instructions:"Keeper instructions" ~world:"Original work" () in
  successful initial;
  let settled = Option.get initial.Keeper_codex_runtime.settled_session in
  let session_id, turn_id = match settled.Keeper_official_client_session_store.phase with
    | Settled settlement -> settlement.session_id, settlement.turn_id
    | _ -> fail "fixture did not settle a native thread" in
  let operation_id = Keeper_chat_operation.Operation_id.of_string "cooperative-original" |> require in
  let seed = match Keeper_semantic_execution.create
      ~id:(Keeper_execution_scope_id.direct_operation operation_id)
      ~input:(`String original_task) ~sources:[] ~now:1. with
    | Ok value -> value | Error error -> fail (Keeper_semantic_execution.error_to_string error) in
  let observed : Keeper_semantic_execution.official_client_checkpoint =
    { client_kind=settled.client_kind;runtime_id=settled.runtime_id;session_id;turn_id;
      tool_surface_sha256=settled.tool_surface_sha256;frame=seed.frame } in
  let steering = run ~instructions:"Keeper instructions" ~world:"Newer steering" () in
  successful steering;
  let checkpoint = Keeper_direct_checkpoint_continuation.For_testing.prepare_official_resume
    ~observed ~expected:steering.Keeper_codex_runtime.settled_session |> require in
  check bool "steering advances admission turn" true (not (String.equal observed.turn_id checkpoint.turn_id));
  let official_task_reference = Keeper_official_task_reference.create
    ~operation_id ~message:original_task ~original_turn:observed in
  let before = List.length (read_requests capture) in
  let goal = Keeper_direct_checkpoint_continuation.official_resume_message ~operation_id in
  let rejected = run ~official_task_reference ~official_client_continuation:checkpoint ~goal
    ~model_input_projection:(fun messages -> Ok (List.filter
      (fun (message : Agent_core.Types.message) -> message.role <> System) messages))
    ~instructions:"Keeper instructions" ~world:"Newer steering" () in
  (match rejected.Keeper_codex_runtime.result with
   | Error (Agent_core.Error.Config (InvalidConfig {field;_})) ->
     check string "required task mapping cannot be projected away"
       "official_client_session.task_reference" field
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok _ -> fail "a continuation with no historical task mapping was admitted");
  check int "rejected mapping never submits a model request" before
    (List.length (read_requests capture));
  successful (run ~official_task_reference ~official_client_continuation:checkpoint ~goal
    ~instructions:"Keeper instructions" ~world:"Newer steering" ());
  let rows = read_requests capture |> List.filteri (fun index _ -> index >= before) in
  check bool "cooperative continuation resumes the original vendor thread" true
    (List.exists (fun row -> member "method" row = `String "thread/resume") rows);
  check bool "cooperative continuation never injects old input/history again" false
    (List.exists (fun row -> let method_ = member "method" row in
      method_ = `String "thread/start" || method_ = `String "thread/inject_items") rows);
  let resume = List.find (fun row -> member "method" row = `String "thread/resume") rows |> member "params" in
  check bool "the instructions carry no task mapping" false
    (String_util.contains_substring (resume |> member "developerInstructions" |> text)
       "masc.official-client-historical-task.v1");
  let sent = turn_text rows in
  (* [Host.resume_prompt] writes each carried message as one encoded line
     behind its role label. *)
  let historical_task = sent |> String.split_on_char '\n'
    |> List.find_map (fun line ->
      match Yojson.Safe.from_string line with
      | exception Yojson.Json_error _ -> None
      | `Assoc _ as envelope ->
        (match envelope |> member "message" |> member "content_blocks" with
         | `List ((`Assoc fields) :: _) -> (match List.assoc_opt "text" fields with
             | Some (`String encoded) -> (match Yojson.Safe.from_string encoded with
                 | `Assoc task_fields as task when List.assoc_opt "schema" task_fields =
                     Some (`String "masc.official-client-historical-task.v1") -> Some task
                 | _ -> None | exception Yojson.Json_error _ -> None)
             | Some _ | None -> None)
         | _ -> None)
      | _ -> None)
    |> function Some task -> task | None -> fail "original task text has no model-visible mapping" in
  check string "original admitted text mapped after newer steering" original_task
    (historical_task |> member "admitted_message" |> text);
  check string "historical task mapped to original operation" "cooperative-original"
    (historical_task |> member "operation_id" |> text);
  check bool "original operation identity accompanies saved turn" true
    (historical_task |> member "execution_scope"
      = Keeper_execution_scope_id.to_json (Keeper_execution_scope_id.direct_operation operation_id));
  check string "task reference retains saved vendor turn" observed.turn_id
    (historical_task |> member "original_vendor_turn" |> member "turn_id" |> text);
  check bool "the turn input ends with the continuation intent" true
    (String.ends_with ~suffix:("\n\n" ^ goal) sent);
  check bool "the turn input carries no earlier conversation" false
    (String_util.contains_substring sent "Previous completed work")

let test_continuation_resume_overflow_ends_on_a_full_thread () =
  (* A Resume's input is the same at every capacity, and a continuation may
     not move to a fresh thread, so its overflow is not retried: the thread is
     recorded full and the turn ends on the typed overflow. *)
  with_fixture ~overflow_resume:true @@ fun ~run ~capture ~reports:_ ->
  let first = run ~instructions:"Keeper instructions" ~world:"world" () in
  successful first;
  let settled = Option.get first.Keeper_codex_runtime.settled_session in
  let session_id, turn_id = match settled.Keeper_official_client_session_store.phase with
    | Settled turn -> turn.session_id, turn.turn_id | _ -> fail "initial turn not settled" in
  let operation_id = Keeper_chat_operation.Operation_id.of_string "context-shrink-original" |> require in
  let seed = match Keeper_semantic_execution.create
      ~id:(Keeper_execution_scope_id.direct_operation operation_id)
      ~input:(`String "original operation") ~sources:[] ~now:1. with
    | Ok value -> value | Error error -> fail (Keeper_semantic_execution.error_to_string error) in
  let checkpoint : Keeper_semantic_execution.official_client_checkpoint =
    {client_kind=settled.client_kind;runtime_id=settled.runtime_id;session_id;turn_id;
     tool_surface_sha256=settled.tool_surface_sha256;frame=seed.frame} in
  let attempt = run ~official_client_continuation:checkpoint
    ~instructions:"Keeper instructions" ~world:"world" () in
  check bool "the overflow ends the turn" true
    (Result.is_error attempt.Keeper_codex_runtime.result);
  let resumes = read_requests capture |> List.filter (fun row -> member "method" row = `String "thread/resume") in
  (match resumes with
   | [resume] ->
     check string "the continuation resumed the original thread" session_id
       (resume |> member "params" |> member "threadId" |> text)
   | rows -> fail (Printf.sprintf "expected one resume and no retry, saw %d" (List.length rows)));
  match Keeper_official_client_session_store.load ~base_path:(Filename.dirname capture)
          ~keeper_name:"context-fixture"
        |> Result.map_error Keeper_official_client_session_store.read_error_to_string with
  | Ok (Some { phase = Recovery_required { failure; _ }; _ }) ->
    check bool "the thread is recorded full, with no activity observed" true
      (failure = Keeper_official_client_session_store.(Vendor_session_full No_activity_observed))
  | Ok _ -> fail "the overflow left no recovery record"
  | Error detail -> fail detail

(* 64 messages of about 4 KiB: roughly 262 KiB of history, well inside the
   Codex request limit. *)
let large_history = List.init 64 (fun index -> Agent_core.Types.user_msg
  (Printf.sprintf "%d:%s" index (String.make 4096 'x')))

(* One settled native thread, then a Resume carrying [large_history]. Returns
   the Resume attempt and the requests it wrote. [start] and [resume] are the
   fixture's [run] already applied, so its optional arguments stay known. *)
let resume_large_history ~capture ~start ~resume =
  let first = start () in
  successful first;
  let settled = Option.get first.Keeper_codex_runtime.settled_session in
  let session_id, turn_id = match settled.Keeper_official_client_session_store.phase with
    | Settled turn -> turn.session_id, turn.turn_id | _ -> fail "initial turn not settled" in
  let operation_id = Keeper_chat_operation.Operation_id.of_string "prompt-limit-original" |> require in
  let seed = match Keeper_semantic_execution.create
      ~id:(Keeper_execution_scope_id.direct_operation operation_id)
      ~input:(`String "original operation") ~sources:[] ~now:1. with
    | Ok value -> value | Error error -> fail (Keeper_semantic_execution.error_to_string error) in
  let checkpoint : Keeper_semantic_execution.official_client_checkpoint =
    {client_kind=settled.client_kind;runtime_id=settled.runtime_id;session_id;turn_id;
     tool_surface_sha256=settled.tool_surface_sha256;frame=seed.frame} in
  let before = List.length (read_requests capture) in
  let attempt = resume checkpoint in
  attempt, read_requests capture |> List.filteri (fun index _ -> index >= before)

let params_of method_ rows =
  List.filter (fun row -> member "method" row = `String method_) rows
  |> List.map (member "params")

let turn_input params = params |> member "input" |> items |> List.hd |> member "text" |> text

(* Frozen unread observations replace the session's earlier observation by
   identity. A clear is an explicit carrier, and an unchanged clear is held. *)
let test_frozen_unread_changes_and_clears_across_native_requests () =
  with_fixture @@ fun ~run ~capture ~reports:_ ->
  let module Frozen = Keeper_librarian_request_unread in
  let module Store = Keeper_official_client_session_store in
  let history = [Agent_core.Types.user_msg "Unread original A";
                 Agent_core.Types.user_msg "Unread original B"] in
  let hole atom = Keeper_librarian_unread.for_atom ~trace_id:"native-unread"
    ~history_start_boundary_line:1 ~atom ~message_in_atom:0 ~messages:history
    ~reasons:[Keeper_librarian_input_refusal.Input_capacity] |> require in
  let initial = Frozen.of_results ~snapshot:(Ok [hole 0]) ~memory:(Ok []) in
  let changed = Frozen.of_results ~snapshot:(Ok [hole 0]) ~memory:(Ok [hole 1]) in
  let unavailable = Frozen.of_results ~snapshot:(Ok []) ~memory:(Error "ledger unreadable") in
  let carrier unread = match Frozen.attach ~include_empty:true
      ~role:Agent_core.Types.System unread [] with
    | [message] -> message
    | [] | _ :: _ :: _ -> fail "native observation must have one carrier" in
  let encoded unread = Keeper_official_client_host.encode_history_message (carrier unread) in
  let previous = ref None in
  List.iteri (fun index (unread, delivered) ->
    let before = List.length (read_requests capture) in
    let librarian_front _ = Ok
      {Keeper_turn_driver_try_provider.point=No_position; unread} in
    successful (run ~librarian_front ~initial_messages:history
      ~instructions:"Keeper instructions" ~world:"Stable native world" ());
    let rows = read_requests capture |> List.filteri (fun i _ -> i >= before) in
    let sent = if index = 0 then
        match params_of "thread/start" rows with
        | [params] -> params |> member "developerInstructions" |> text
        | _ -> fail "first unread observation did not start one thread"
      else (
        check int "later observation resumes the existing native thread" 1
          (List.length (params_of "thread/resume" rows));
        check int "resume carries no persistent history injection" 0
          (List.length (params_of "thread/inject_items" rows));
        turn_text rows) in
    check bool "transport delivers frozen unread exactly when its observation changes"
      delivered (String_util.contains_substring sent (encoded unread));
    Option.iter (fun prior ->
      if prior <> unread then
        check bool "a changed observation never replays the earlier unread carrier" false
          (String_util.contains_substring sent (encoded prior))) !previous;
    previous := Some unread;
    match Store.load ~base_path:(Filename.dirname capture) ~keeper_name:"context-fixture" |> Result.map_error Store.read_error_to_string with
    | Ok (Some {context_frontier=Some frontier;_}) ->
      let held = List.filter
        (fun (item : Store.held_context) -> item.context=Store.Librarian_unread)
        frontier.held_context in
      (match held with
       | [receipt] -> check string "session holds the latest frozen unread bytes"
           Agent_core_sha256.(digest_string (encoded unread) |> to_hex) receipt.sha256
       | [] | _ :: _ :: _ -> fail "native session lost its single unread receipt")
    | Ok _ | Error _ -> fail "native session lost its acknowledged context frontier")
    [initial,true;initial,false;changed,true;Frozen.empty,true;Frozen.empty,false;
     unavailable,true;unavailable,false;Frozen.empty,true]

(* Two fixtures live under different temporary roots; anything that names the
   root is compared with the root taken out. *)
let without_root ~capture value =
  let root = Filename.dirname capture in
  let root_length = String.length root in
  let buffer = Buffer.create (String.length value) in
  let rec copy index =
    if index >= String.length value then ()
    else if index + root_length <= String.length value
         && String.equal (String.sub value index root_length) root
    then (Buffer.add_string buffer "<root>"; copy (index + root_length))
    else (Buffer.add_char buffer value.[index]; copy (index + 1))
  in
  copy 0;
  Buffer.contents buffer

let test_start_carries_the_range_not_the_whole_history () =
  (* A fresh thread is seeded with the carried range the other official
     clients send, not with every message the keeper holds. The history is
     inside the request limit, so no byte window cuts anything and only the
     range can bound the seed. The last completed turn ended at atom 60, so the range
     is atoms 60..63. *)
  with_fixture @@ fun ~run ~capture ~reports:_ ->
  successful
    (run ~initial_messages:large_history
       ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 60 })
       ~instructions:"Keeper instructions" ~world:"world" ());
  match params_of "thread/inject_items" (read_requests capture) with
  | [injected] ->
    let seeded =
      injected |> member "items" |> items |> List.map Yojson.Safe.to_string
    in
    let carries index =
      List.exists
        (fun item -> String_util.contains_substring item (Printf.sprintf "\"%d:xxxx" index))
        seeded
    in
    check (list bool) "atoms 60..63 are seeded" [ true; true; true; true ]
      (List.map carries [ 60; 61; 62; 63 ]);
    check bool "nothing before the range is seeded" false (carries 59 || carries 0);
    check int "only the range goes" 4 (List.length seeded)
  | rows -> fail (Printf.sprintf "expected one inject_items request, saw %d" (List.length rows))

let resume_wire () =
  with_fixture @@ fun ~run ~capture ~reports:_ ->
  let attempt, rows = resume_large_history ~capture
    ~start:(fun () -> run ~instructions:"Keeper instructions" ~world:"world" ())
    ~resume:(fun checkpoint -> run ~initial_messages:large_history
      ~official_client_continuation:checkpoint
      ~instructions:"Keeper instructions" ~world:"world" ()) in
  successful attempt;
  match params_of "thread/resume" rows, params_of "turn/start" rows with
  | [resume], [turn] ->
    let instructions = resume |> member "developerInstructions" |> text in
    instructions,
    [ without_root ~capture instructions; without_root ~capture (turn_input turn) ]
  | resumes, turns ->
    fail (Printf.sprintf "expected one Resume, saw %d resumes and %d turns"
      (List.length resumes) (List.length turns))

let snapshot_carries kept index =
  List.exists
    (fun item ->
       String_util.contains_substring (Yojson.Safe.to_string item)
         (Printf.sprintf "\"%d:xxxx" index))
    kept

(* The composition both modes share, driven directly. *)
let carried_indices messages =
  List.filter_map
    (fun (message : Agent_core.Types.message) ->
       match message.content with
       | [ Agent_core.Types.Text text ] ->
         (match String.index_opt text ':' with
          | Some colon -> int_of_string_opt (String.sub text 0 colon)
          | None -> None)
       | _ -> None)
    messages

let native_unread_messages
    ?(unread = unavailable_native_unread) messages =
  Keeper_librarian_request_unread.attach ~include_empty:true ~role:Agent_core.Types.System unread messages

let carried ?carried_front_seed ?librarian_front
    ?(unread = unavailable_native_unread) ?(capacity_bytes = Keeper_codex_runtime.For_testing.unbounded_capacity_bytes) turn_start =
  match
    Keeper_codex_runtime.For_testing.carried_projection ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "context-fixture" })
      ~capacity_bytes ?carried_front_seed ?librarian_front ~turn_start
      ~keeper_name:"context-fixture" ~runtime_id:"codex.context" large_history
  with
  | Ok messages ->
    let carriers = List.filter Runtime_model_input_tail_window.is_unread_context messages in
    let encoded = List.map Keeper_official_client_host.encode_history_message in
    check (list string) "native range contains its exact frozen unread observation"
      (encoded (native_unread_messages ~unread [])) (encoded carriers);
    check int "native unread carrier is pinned" 0
      (snd (Runtime_model_input_tail_window.annotate carriers));
    carried_indices messages
  | Error error -> fail (Agent_core.Error.to_string error)

let seed_at first_atom () =
  let front_digest =
    match Runtime_model_input_tail_window.atom_opening_digest large_history first_atom with
    | Some digest -> digest
    | None -> fail "the history opens that atom"
  in
  { Keeper_carried_front.seed =
      Some { Keeper_carried_front.first_atom; front = Model_input_front.At_atom front_digest; source = Keeper_carried_front.Ledger }
  ; unreadable = None
  ; boundary_error = None
  }

let test_resume_after_start_sends_no_history () =
  (* Both requests hold the same 64-message checkpoint. The Start seeds the
     new thread with the turn's range only; the Resume that follows sends none
     of the history, since the thread already holds it. *)
  with_fixture @@ fun ~run ~capture ~reports:_ ->
  let windows = ref 0 in
  let on_model_input_window_observation _ = incr windows in
  let first = run ~initial_messages:large_history
    ~on_model_input_window_observation
    ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 60 })
    ~instructions:"Keeper instructions" ~world:"world" () in
  successful first;
  check int "the Start reports its window" 1 !windows;
  let before = List.length (read_requests capture) in
  successful (run ~initial_messages:large_history
    ~on_model_input_window_observation
    ~carried_front_seed:(seed_at 60)
    ~turn_start:(Keeper_carried_front.Turn_boundary_unknown { reason = "fixture" })
    ~instructions:"Keeper instructions" ~world:"world" ());
  check int "the Resume reports no window for history it did not send" 1 !windows;
  let first_rows = read_requests capture |> List.filteri (fun index _ -> index < before) in
  let resumed_rows = read_requests capture |> List.filteri (fun index _ -> index >= before) in
  let start_messages = match params_of "thread/inject_items" first_rows with
    | [params] -> params |> member "items" |> items
    | rows -> fail (Printf.sprintf "expected one Start injection, saw %d" (List.length rows)) in
  let start_carries index = snapshot_carries start_messages index in
  check (list bool) "Start carries atoms 60..63" [ true; true; true; true ]
    (List.map start_carries [ 60; 61; 62; 63 ]);
  check bool "Start excludes earlier atoms" false (start_carries 59 || start_carries 0);
  check int "Start sends only the range" 4 (List.length start_messages);
  (match params_of "thread/resume" resumed_rows with
   | [_] -> ()
   | rows -> fail (Printf.sprintf "expected one Resume, saw %d" (List.length rows)));
  check int "Resume injects nothing" 0
    (List.length (params_of "thread/inject_items" resumed_rows));
  List.iter (fun row ->
    check bool "Resume sends no history message" false
      (String_util.contains_substring (Yojson.Safe.to_string row) "xxxx"))
    resumed_rows

let test_a_resume_overflow_retries_with_the_whole_range () =
  (* A Resume sends no history, so its overflow says the thread is full, not
     that the range is too large. The fresh thread that retries it carries
     the whole range, atoms 60..63, not half of it. *)
  with_fixture ~overflow_resume:true @@ fun ~run ~capture ~reports:_ ->
  let turn_start = Keeper_carried_front.Turn_boundary { end_atom = 60 } in
  successful (run ~initial_messages:large_history ~turn_start
    ~instructions:"Keeper instructions" ~world:"world" ());
  let before = List.length (read_requests capture) in
  successful (run ~initial_messages:large_history ~turn_start
    ~instructions:"Keeper instructions" ~world:"world" ());
  let rows = read_requests capture |> List.filteri (fun index _ -> index >= before) in
  (match params_of "thread/resume" rows, params_of "thread/start" rows with
   | [_], [_] -> ()
   | resumes, starts ->
     fail (Printf.sprintf "expected a Resume then a fresh Start, saw %d resumes and %d starts"
       (List.length resumes) (List.length starts)));
  match params_of "thread/inject_items" rows with
  | [injected] ->
    let seeded = injected |> member "items" |> items in
    check (list bool) "the retry carries atoms 60..63" [ true; true; true; true ]
      (List.map (snapshot_carries seeded) [ 60; 61; 62; 63 ])
  | injected ->
    fail (Printf.sprintf "expected one retry injection, saw %d" (List.length injected))

let from index = List.init (64 - index) (fun offset -> index + offset)

let test_the_seed_decides_the_range () =
  (* A seed holds even when it is older than the turn start: the range the
     last answered request carried is this lane's continuity. *)
  check (list int) "the range opens on the seed" (from 50)
    (carried ~carried_front_seed:(seed_at 50)
       (Keeper_carried_front.Turn_boundary { end_atom = 60 }))

let test_a_later_librarian_position_decides_the_range () =
  check (list int) "the Librarian's read position is past the seed" (from 62)
    (carried ~carried_front_seed:(seed_at 50)
       ~unread:Keeper_librarian_request_unread.empty
       ~librarian_front:(fun _ ->
         Ok (frozen_librarian_position (Keeper_turn_driver_try_provider.Librarian_progress { end_atom = 62 })))
       (Keeper_carried_front.Turn_boundary { end_atom = 60 }))

(* A response accepted no prior history, but the next request can retain the
   Librarian's fitting summary and its separately delivered current goal. The
   summary must not resurrect the omitted final atom or bypass a real ceiling. *)
let test_empty_history_keeps_a_fitting_summary () =
  with_fixture @@ fun ~run ~capture ~reports ->
  let trace_id = "accepted-empty-summary" in
  let summary_marker = "KEEP_CONTINUITY_WITHOUT_OLD_ATOMS" in
  let working_state = summary_marker ^ ": prior work is complete." in
  let position = match Keeper_turn_boundaries.position_of_messages large_history with
    | Ok position -> position | Error detail -> fail detail in
  let lines = [ 1, Ok
    { Keeper_turn_boundaries.recorded_at = 1.
    ; event = Keeper_turn_boundaries.Turn_ended
        { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1
        ; history_at_start = Fresh_history; position }
    } ] in
  let snapshot = match Librarian_continuity_snapshot.capture ~unread_messages:[]
    ~trace_id ~lines ~messages:large_history ~working_state with
    | Ok snapshot -> snapshot
    | Error error -> fail (Librarian_continuity_snapshot.error_to_string error) in
  let librarian_front messages =
    (match Librarian_continuity_snapshot.restore ~trace_id ~lines ~messages snapshot with
     | Ok _ -> ()
     | Error error -> fail (Librarian_continuity_snapshot.error_to_string error));
    Ok (frozen_librarian_position (Keeper_turn_driver_try_provider.Librarian_snapshot snapshot))
  in
  let seed : Keeper_carried_front.seed =
    { first_atom = 64
    ; front = Model_input_front.After_history
        (Option.get (Runtime_model_input_tail_window.atom_opening_digest large_history 63))
    ; source = Keeper_carried_front.Turn_record { turn = 1 }
    } in
  let carried_front_seed () =
    { Keeper_carried_front.seed = Some seed; unreadable = None; boundary_error = None } in
  let goal = "Continue with the new user instruction." in
  successful (run ~initial_messages:large_history ~carried_front_seed ~librarian_front
    ~goal ~instructions:"Keeper instructions" ~world:"Current state" ());
  let requests = read_requests capture in
  let start = match params_of "thread/start" requests with
    | [params] -> params | _ -> fail "expected one fresh thread" in
  let instructions = start |> member "developerInstructions" |> text in
  check bool "a fitting summary survives"
    true (String_util.contains_substring instructions summary_marker);
  (match params_of "turn/start" requests with
   | [params] -> check string "current goal is still sent separately" goal (turn_input params)
   | _ -> fail "summary handling should not need another provider attempt");
  (match !reports with
   | [Keeper_official_client_host.Whole_input_transmitted messages] ->
     check (list int) "no omitted atom was resurrected" [] (carried_indices messages);
     check bool "reported composition agrees with the native instructions"
       true (List.exists Runtime_model_input_tail_window.is_working_state messages)
   | _ -> fail "expected one transmitted input observation")

let test_a_ceiling_cuts_inside_the_range () =
  (* Room for the omission preamble and two of the ~4 KiB messages: the
     ceiling cuts deeper than the range's own front at atom 60, and
     the later front wins. *)
  let measure message = String.length (Keeper_official_client_host.encode_history_message message) in
  let framing =
    match Runtime_model_input_tail_window.minimum_capacity_bytes ~measure_message_bytes:measure
      (native_unread_messages large_history) with
    | Some bytes -> bytes
    | None -> fail "a history this long has a framed floor"
  in
  let capacity_bytes =
    framing + measure (List.nth large_history 62) + measure (List.nth large_history 63)
  in
  check (list int) "the ceiling keeps the newest two" [ 62; 63 ]
    (carried ~capacity_bytes
       (Keeper_carried_front.Turn_boundary { end_atom = 60 }))

let test_the_overflow_floor_does_not_restore_the_newest_atom () =
  (* A typed overflow can narrow past the last atom. Reapplying the carried
     start after this cut would resend exactly the atom the client refused. *)
  let measure message =
    String.length (Keeper_official_client_host.encode_history_message message)
  in
  let floor =
    match
      Runtime_model_input_tail_window.minimum_capacity_bytes
        ~measure_message_bytes:measure
        (native_unread_messages large_history)
    with
    | Some bytes -> bytes
    | None -> fail "the rejected history must have a smaller floor"
  in
  check (list int) "the floor carries no conversation atom" []
    (carried ~capacity_bytes:floor
       (Keeper_carried_front.Turn_boundary { end_atom = 60 }))

let test_an_unknown_turn_start_carries_the_newest_atom () =
  check (list int) "the newest atom alone" [ 63 ]
    (carried (Keeper_carried_front.Turn_boundary_unknown { reason = "fixture" }))

let turn_start_to_string = Keeper_carried_front.turn_start_to_string

let test_completion_evidence_without_a_keeper_boundary_keeps_every_atom () =
  let seed_reads = ref 0 and librarian_reads = ref 0 in
  let sent = Keeper_codex_runtime.For_testing.carried_projection
      ~input_source:Masc.Keeper_request_source.Completion_review ~capacity_bytes:1
      ~carried_front_seed:(fun () -> incr seed_reads; (seed_at 60) ())
      ~librarian_front:(fun _ -> incr librarian_reads;
        Error (Agent_core.Error.Internal "completion evidence has no Keeper continuity"))
      ~turn_start:(Keeper_carried_front.Turn_boundary_unknown { reason = "program-owned completion evidence" })
      ~keeper_name:"completion-review-fixture" ~runtime_id:"codex.context" large_history
    |> Result.map_error Agent_core.Error.to_string
    |> function Ok messages -> messages | Error error -> fail error
  in
  check bool "Codex receives the exact full evidence, despite a tiny capacity" true
    (List.map Agent_core.Checkpoint.message_to_json sent
     = List.map Agent_core.Checkpoint.message_to_json large_history);
  check int "the native completion review does not read a Keeper seed" 0 !seed_reads;
  check int "the native completion review does not query the Librarian" 0 !librarian_reads

let test_resume_sends_no_history () =
  (* The thread already holds the conversation. Neither the instructions nor
     the turn input carry any of it. *)
  let _, wire = resume_wire () in
  List.iter (fun sent ->
    check bool "no history message is sent" false
      (String_util.contains_substring sent "xxxx")) wire

let argument_exchange id input =
  let open Agent_core.Types in
  [make_message ~role:Assistant [ToolUse {id;name="record";input}];
   make_message ~role:Tool ~tool_call_id:id
     [ToolResult {tool_use_id=id;content="done";outcome=Tool_succeeded;json=None;content_blocks=None}]]

let argument_reader base_path =
  let schema = Keeper_runtime_schemas_toml.artifact_read in
  Tool_bridge.agent_core_tool_of_masc_with_execution_env ~base_path
    ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
    ~model_projection:(fun () -> Tool_output.bounded_inline_model_projection)
    ~name:schema.name ~description:schema.description ~input_schema:schema.input_schema
    (fun _ args ->
      let execution = Keeper_artifact_read.handle ~base_path ~args in
      match execution.disposition with
      | Tool_result.Completed () -> Tool_result.make_ok ~tool_name:schema.name
          ~start_time:(Tool_timing.start ()) ?data:execution.data ()
      | Tool_result.Failed class_ -> Tool_result.make_err ~tool_name:schema.name ~class_
          ~start_time:(Tool_timing.start ()) execution.raw_output
      | Tool_result.Deferred () -> fail "canonical reader cannot defer")

let argument_input id rows =
  let blocks = params_of "thread/inject_items" rows
    |> List.concat_map (fun params -> params |> member "items" |> items)
    |> List.concat_map (fun item -> item |> member "content" |> items)
    |> List.concat_map (fun block -> block |> member "text" |> text
      |> Yojson.Safe.from_string |> member "message" |> member "content_blocks" |> items) in
  match List.find_opt (fun block -> member "type" block=`String "tool_use"
    && member "id" block=`String id) blocks with
  | Some block -> member "input" block
  | None -> fail ("missing actual injected tool call " ^ id)

let argument_fixture capture =
  let old = `Assoc ["command",`String (String.make 4000 'a')] in
  let current = `Assoc ["command",`String (String.make 4000 'c')] in
  let seed = Agent_core.Types.user_msg "Earlier decision" :: argument_exchange "old" old in
  let history = seed @ [Agent_core.Types.user_msg "Current decision"] @ argument_exchange "current" current in
  let boundary = Keeper_carried_front.Turn_boundary
    {end_atom=snd (Runtime_model_input_tail_window.annotate seed)} in
  (* Official clients send this projected current goal separately. Requiring
     it after the history prefix would disable otherwise valid arguments. *)
  let replay_prefix = Keeper_replay_prefix.media_degraded_with_current_input
    ~canonical_prefix:seed ~dispatch_prefix:seed
    ~canonical_input:(Agent_core.Types.user_msg "Original media goal")
    ~dispatch_input:(Agent_core.Types.user_msg "Projected media goal") in
  check bool "full checkpoint authority still requires the current input" true
    (Result.is_error (Keeper_replay_prefix.restore_messages replay_prefix history));
  let base_path = Filename.dirname capture in
  let source () = Keeper_official_client_host.create_argument_source
    ~input_policy:Keeper_input_policy.Small ~base_path ~keeper_name:"context-fixture"
    ~seed:(Some seed) ~replay_prefix ~turn_start:boundary in
  let librarian_front _ = Ok (frozen_librarian_position
    (Keeper_turn_driver_try_provider.Librarian_progress {end_atom=1})) in
  old,current,history,boundary,source,librarian_front,argument_reader base_path

let test_completed_arguments_cross_start_resume_and_reseed ~overflow_resume () =
  with_fixture ~overflow_resume @@ fun ~run ~capture ~reports ->
  let old,current,history,turn_start,source,librarian_front,reader = argument_fixture capture in
  let raw = List.map Agent_core.Checkpoint.message_to_json history in
  let send () = run ?argument_source:(source ()) ~tools:[reader]
    ~initial_messages:history ~turn_start ~librarian_front
    ~instructions:"Keeper instructions" ~world:"world" () in
  successful (send ());
  let input = argument_input "old" (read_requests capture) in
  let reference = match Tool_output.normalized_artifact_ref_of_json input with
    | Tool_output.Decoded_normalized_artifact_ref reference -> reference
    | Tool_output.Not_normalized_artifact_ref | Invalid_normalized_artifact_ref _ ->
      fail "actual Codex Start did not inject a normalized argument reference" in
  check bool "current arguments remain exact on the actual writer" true
    (argument_input "current" (read_requests capture)=current);
  let recovered = Buffer.create reference.bytes in
  let rec read offset =
    let output = match Agent_core.Tool.execute reader
      (`Assoc ["sha256",`String reference.sha256;"offset",`Int offset]) with
      | Ok output -> output | Error error -> fail error.message in
    let page = Yojson.Safe.from_string output.content in
    let contents = page |> member "content" |> text in
    let contents = match page |> member "encoding" |> text with
      | "utf-8" -> contents | "base64" -> Base64.decode_exn contents
      | other -> fail ("unknown reader encoding " ^ other) in
    Buffer.add_string recovered contents;
    if not (Yojson.Safe.Util.to_bool (member "eof" page)) then
      read (Yojson.Safe.Util.to_int (member "next_offset" page)) in
  read 0;
  check string "actual canonical reader restores original JSON"
    (Yojson.Safe.to_string old) (Buffer.contents recovered);
  let store = Tool_blob_store.create ~base_path:(Filename.dirname capture) in
  (match Tool_blob_store.delete store ~sha256:reference.sha256 with
   | Ok true -> () | Ok false -> fail "Start blob was absent"
   | Error _ -> fail "cannot remove fixture blob before Resume");
  write capture "";
  successful (send ());
  let rows = read_requests capture in
  check int "the next request really resumed" 1 (List.length (params_of "thread/resume" rows));
  if overflow_resume then (
    check bool "fresh overflow retry re-materializes the old input" true
      (argument_input "old" rows=input);
    match Tool_blob_store.fetch store ~sha256:reference.sha256 with
    | Ok (Some bytes) -> check string "fresh retry restored the exact blob" (Yojson.Safe.to_string old) bytes
    | Ok None | Error _ -> fail "fresh retry did not store its transmitted argument")
  else (
    check int "Resume injects no history" 0 (List.length (params_of "thread/inject_items" rows));
    (match Tool_blob_store.fetch store ~sha256:reference.sha256 with
     | Ok None -> () | Ok (Some _) | Error _ -> fail "Resume touched an unmaterialized argument");
    check bool "history remains held by the client" true
      (match !reports with Keeper_official_client_host.Held_by_client_session::_ -> true | _ -> false));
  check bool "the canonical source stays unchanged" true
    (List.map Agent_core.Checkpoint.message_to_json history=raw)

let test_argument_projection_requires_the_prepared_reader ~disabled () =
  with_fixture @@ fun ~run ~capture ~reports:_ ->
  let old,_,history,turn_start,source,librarian_front,reader = argument_fixture capture in
  successful (run ?argument_source:(source ()) ~tools:(if disabled then [reader] else [])
    ?tool_choice:(if disabled then Some Agent_core.Types.None_ else None)
    ~initial_messages:history ~turn_start ~librarian_front
    ~instructions:"Keeper instructions" ~world:"world" ());
  check bool "actual tool surface keeps the original input" true
    (argument_input "old" (read_requests capture)=old);
  check bool "ineligible arguments create no blob directory" false
    (Sys.file_exists (Tool_blob_store.root_dir
      (Tool_blob_store.create ~base_path:(Filename.dirname capture))))

let test_argument_projection_keeps_exact_history_prefix_guards () =
  with_fixture @@ fun ~run ~capture ~reports:_ ->
  let old,_,history,turn_start,source,librarian_front,reader = argument_fixture capture in
  let changed = Agent_core.Types.user_msg "Unrelated source" :: List.tl history in
  successful (run ?argument_source:(source ()) ~tools:[reader]
    ~initial_messages:changed ~turn_start ~librarian_front
    ~instructions:"Keeper instructions" ~world:"world" ());
  check bool "a mismatched history cannot borrow raw argument authority" true
    (argument_input "old" (read_requests capture)=old)

let test_checkpoint_preserves_receipt_across_session_replacement ~repeated_tool () =
  with_fixture ~checkpoint_tool:true @@ fun ~run ~capture ~reports:_ ->
  let base_path = Filename.dirname capture and keeper_name = "context-fixture" in
  let config = Workspace.default_config base_path in
  Masc_test_deps.declare_fixture_keeper ~base_path ~sandbox_image:"base"
    ~sandbox_profile:(Some Keeper_types_profile.Docker) keeper_name;
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String keeper_name])
    |> require |> Keeper_meta_contract.effective_meta_result ~base_path |> require in
  ignore (Keeper_meta_store.replace_snapshot config meta |> require);
  ignore (Keeper_registry.register_offline ~base_path keeper_name meta);
  Fun.protect ~finally:(fun () -> Keeper_registry.For_testing.unregister ~base_path keeper_name)
    (fun () ->
      let original : Keeper_client_tool_outbox.receipt =
        {thread_id="previous-session";turn_id="original-turn";call_id="original-call";
         tool_name="Execute";arguments=`Assoc ["command",`String "original-effect-no-replay"];
         response=`String "original-private-result-after-session-replacement"} in
      Keeper_client_tool_outbox.retain ~base_path ~keeper_name original |> require;
      let load () = Keeper_client_tool_outbox.load ~base_path ~keeper_name |> require in
      let original_id = match Keeper_client_tool_outbox.receipt_ids (load ()) with
        | [id] -> id | _ -> fail "expected the original committed receipt" in
      Keeper_client_tool_outbox_wake.notify ~base_path ~keeper_name |> require;
      let intake () =
        let env = Option.get (Eio_context.get_env_opt ()) in
        Eio.Switch.run (fun sw ->
          let ctx : _ Keeper_types_profile.context =
            {config;agent_name="receipt-checkpoint-fixture";sw;clock=env#clock;
             proc_mgr=None;net=None;
             publication_recovery_provider=Masc_test_deps.non_runtime_publication_recovery_provider} in
          Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
            ~ctx ~meta_after_triage:meta ~pending_board_events:[]) in
      let admitted = (intake ()).source_batch |> Keeper_heartbeat_source_batch.selections in
      check int "real intake admits the original receipt" 1 (List.length admitted);
      let calls = ref 0 in
      let tool = Agent_core.Tool.create ~name:"CheckpointFixture"
        ~description:"Settle independent work before yielding" ~parameters:[]
        (fun _ -> incr calls; Ok {Agent_core.Types.content="independent-result";
                                 content_blocks=None;_meta=None}) in
      let stop : Keeper_official_client_host.host_stop =
        if repeated_tool then Repeated_tool_call {tool_name="CheckpointFixture";repeated_count=2}
        else Terminal_tool_boundary {tool_name="CheckpointFixture";outcome=Durable_stimulus_deferred} in
      let attempt = run ~tools:[tool]
        ~on_official_client_tool_boundary:(fun ~tool_name:_ -> Ok (Some stop))
        ~instructions:"Read the original result without replaying its effect." ~world:"before checkpoint" () in
      let result = match attempt.Keeper_codex_runtime.result with
        | Ok result -> result | Error error -> fail (Agent_core.Error.to_string error) in
      (match result.stop_reason with
       | Yielded_to_durable_stimulus _ when not repeated_tool -> ()
       | Yielded_after_repeated_tool_call _ when repeated_tool -> ()
       | Completed _ | Yielded_to_operation_queued _ | Yielded_to_durable_stimulus _
       | Yielded_after_repeated_tool_call _ | Yielded_after_repeated_assistant_text _
       | InputRequired _ -> fail "the production adapter must project the checkpoint");
      check int "the independent tool ran once" 1 !calls;
      Keeper_heartbeat_loop.For_testing.retain_checkpoint_continuations
        ~base_path ~keeper_name admitted |> require;
      Keeper_event_queue_persistence.For_testing.reset_snapshot_cache_for_testing ();
      check bool "host checkpoint retains original result bytes" true
        (Keeper_client_tool_outbox.contains_receipt (load ()) ~receipt_id:original_id);
      Keeper_official_client_session_store.clear_then ~base_path ~keeper_name (fun () -> ()) |> require;
      let replacement = intake () in
      check bool "session replacement does not withdraw original input" true
        (List.exists (fun (s : Keeper_event_queue_state.pending_selection) ->
           s.source.payload=Keeper_event_queue.Tool_result_ready original_id)
           (Keeper_heartbeat_source_batch.selections replacement.source_batch));
      let before = List.length (read_requests capture) in
      successful (run ~tools:[tool] ~instructions:"Continue from the retained original result."
        ~world:"replacement session" ());
      let sent = read_requests capture |> List.filteri (fun i _ -> i >= before) in
      check bool "replacement starts a fresh vendor session" true
        (List.exists (fun row -> member "method" row=`String "thread/start") sent);
      let encoded = Yojson.Safe.to_string (`List sent) in
      List.iter (fun value -> check bool "fresh consumer receives exact original data" true
        (String_util.contains_substring encoded value))
        ["original-effect-no-replay";"original-private-result-after-session-replacement"];
      check int "completed replacement acknowledges loaded receipts" 0
        (List.length (Keeper_client_tool_outbox.receipt_ids (load ())));
      let original_hint = Keeper_registry_event_queue.pending_selections_result ~base_path keeper_name
        |> require |> List.find (fun (s : Keeper_event_queue_state.pending_selection) ->
             s.source.payload=Keeper_event_queue.Tool_result_ready original_id) in
      (match Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
         ~config ~keeper_name original_hint |> require with
       | Tool_result_hint_retired -> ()
       | Selection_actionable | Spent_grant_replay_acknowledged | Absent_grant_retired _ ->
         fail "completed receipt consumption must retire its exact hint");
      check int "replacement never re-executes the original or independent effect" 1 !calls)

let () = run "Keeper current Codex context" ["native requests",[
  test_case "completed arguments cross Start and held Resume" `Quick
    (test_completed_arguments_cross_start_resume_and_reseed ~overflow_resume:false);
  test_case "fresh overflow retry materializes its own Start" `Quick
    (test_completed_arguments_cross_start_resume_and_reseed ~overflow_resume:true);
  test_case "no canonical reader keeps original arguments" `Quick
    (test_argument_projection_requires_the_prepared_reader ~disabled:false);
  test_case "hook-disabled tools keep original arguments" `Quick
    (test_argument_projection_requires_the_prepared_reader ~disabled:true);
  test_case "history-only authority retains exact prefix guards" `Quick
    test_argument_projection_keeps_exact_history_prefix_guards;
  test_case "selected context window survives catalog reload on start and resume" `Quick test_captured_context_window_survives_catalog_reload;
  test_case "compaction item invalidates recall without usage estimate" `Quick test_compaction_item_invalidates_recall_without_usage_estimate;
  test_case "compaction invalidates recall despite later request usage" `Quick test_compaction_receipt_survives_later_request_usage;
  test_case "resume delivers only changed blocks and pending operator note" `Quick test_resume_deduplicates_context_blocks;
  test_case "fresh overflow retry receives and remembers recall" `Quick test_context_blocks_survive_fresh_retry;
  test_case "frozen unread changes, clears and stays held across native requests" `Quick
    test_frozen_unread_changes_and_clears_across_native_requests;
  test_case "memory changes, clears, fails and recovers across native ticks" `Quick test_recall_lifecycle_across_native_ticks;
  test_case "operator interruption preserves previous Codex settlement" `Quick test_operator_interrupt_preserves_previous_native_settlement;
  test_case "a Start carries the range, not the whole history" `Quick test_start_carries_the_range_not_the_whole_history;
  test_case "a Resume after a Start sends no history" `Quick test_resume_after_start_sends_no_history;
  test_case "a Resume overflow retries with the whole range" `Quick test_a_resume_overflow_retries_with_the_whole_range;
  test_case "the seed decides the range" `Quick test_the_seed_decides_the_range;
  test_case "a later Librarian position decides the range" `Quick test_a_later_librarian_position_decides_the_range;
  test_case "accepted empty history retains a fitting summary" `Quick
    test_empty_history_keeps_a_fitting_summary;
  test_case "a ceiling cuts inside the range" `Quick test_a_ceiling_cuts_inside_the_range;
  test_case "an overflow floor never restores the last atom" `Quick test_the_overflow_floor_does_not_restore_the_newest_atom;
  test_case "an unknown turn start carries the newest atom" `Quick test_an_unknown_turn_start_carries_the_newest_atom;
  test_case "completion evidence without a Keeper boundary keeps every atom" `Quick test_completion_evidence_without_a_keeper_boundary_keeps_every_atom;
  test_case "a Resume sends none of the history" `Quick test_resume_sends_no_history;
  test_case "a continuation's resume overflow ends on a full thread" `Quick test_continuation_resume_overflow_ends_on_a_full_thread;
  test_case "cooperative native resume does not replay original input" `Quick test_cooperative_resume_sends_only_remaining_work_instruction;
  test_case "a resume carries per-turn context in front of the goal" `Quick (test_resume_carries_per_turn_context_in_front_of_the_goal ~worker_pool:false);
  test_case "pooled context projection preserves fresh and resumed requests" `Quick (test_resume_carries_per_turn_context_in_front_of_the_goal ~worker_pool:true);
  test_case "context injection must be acknowledged before model turn" `Quick test_rejected_context_never_submits_turn];
  "async receipt continuation",[
    test_case "host checkpoint preserves result through fresh-session intake" `Quick
      (test_checkpoint_preserves_receipt_across_session_replacement ~repeated_tool:false);
    test_case "repeated-tool checkpoint preserves result through fresh-session intake" `Quick
      (test_checkpoint_preserves_receipt_across_session_replacement ~repeated_tool:true)]]

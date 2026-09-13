(* Drive the production Keeper adapter through fresh and resumed native
   requests. The fixture observes transport input, not model understanding. *)
open Alcotest
open Masc

let write path value = Out_channel.with_open_bin path (fun out -> output_string out value)
let member = Yojson.Safe.Util.member
let text = Yojson.Safe.Util.to_string
let items = Yojson.Safe.Util.to_list
let require = function Ok value -> value | Error detail -> fail detail

let fixture root ~reject_context ~overflow_resume =
  let capture = Filename.concat root "requests.jsonl" in
  let command = Filename.concat root "codex-fixture" in
  write command (Printf.sprintf {|#!/usr/bin/env python3
import json, sys, os
if '--masc-warmup' in sys.argv:
    sys.exit(0)
capture = %S
reject_context = %s
overflow_resume = %s
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
        emit({'id':ident,'result':{'turn':{'id':turn_id}}})
        if overflow_resume and turn_id == 'resumed-turn' and not os.path.exists(capture+'.overflowed'):
            with open(capture+'.overflowed', 'w') as out:
                out.write('rejected before effects')
            emit({'method':'turn/completed','params':{'threadId':'context-thread','turn':{'id':turn_id,'items':[],'status':'failed','error':{'message':'context is full','codexErrorInfo':'contextWindowExceeded'}}}})
            continue
        item = {'type':'agentMessage','id':'answer','text':'CONTEXT_RECEIVED','phase':'final_answer'}
        emit({'method':'item/completed','params':{'threadId':'context-thread','turnId':turn_id,'completedAtMs':1,'item':item}})
        emit({'method':'turn/completed','params':{'threadId':'context-thread','turn':{'id':turn_id,'items':[item],'status':'completed'}}})
|} capture (if reject_context then "True" else "False") (if overflow_resume then "True" else "False"));
  Unix.chmod command 0o700;
  command, capture

let with_fixture ?(reject_context = false) ?(overflow_resume = false) test =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio_context.set_env env;
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let root = Filename.temp_file "masc-codex-current-context-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let saved = Runtime.For_testing.snapshot () in
  Eio.Switch.on_release sw (fun () -> Runtime.For_testing.restore saved; Fs_compat.remove_tree root);
  let command, capture = fixture root ~reject_context ~overflow_resume in
  let config_path = Filename.concat root "runtime.toml" in
  write config_path (Printf.sprintf {|
[providers.codex]
protocol = "codex-app-server"
command = %S
is-non-interactive = true
[models.context]
api-name = "context-fixture"
max-context = 400000
[codex.context]
[runtime]
default = "codex.context"
|} command);
  Runtime.init_default ~config_path |> require;
  let config = match Runtime.get_runtime_by_id "codex.context" with
    | Some {execution=Runtime_execution.Codex_app_server config;_} -> config
    | Some _ | None -> fail "fixture runtime missing" in
  let reports = ref [] in
  let run ?(initial_messages=[Agent_core.Types.user_msg "Previous completed work"]) ?official_client_continuation ?official_client_original_turn ?(goal="Continue from current World State.") ~instructions ~world () =
    let hooks = { Agent_core.Hooks.empty with before_turn_params = Some (function
      | Agent_core.Hooks.BeforeTurnParams {current_params;_} ->
        Agent_core.Hooks.AdjustParams {current_params with extra_system_context=Some world}
      | _ -> Agent_core.Hooks.Continue) } in
    Keeper_codex_runtime.run
        ~accepts_image_input:(Runtime_agent.runtime_accepts_image_input
          ~runtime:(Runtime.get_runtime_by_id "codex.context" |> Option.get)) ~runtime_id:"codex.context" ~keeper_name:"context-fixture"
      ~pre_tool_rejects:(ref []) ~base_path:root ~goal ?official_client_continuation ?official_client_original_turn
      ~goal_blocks:None ~system_prompt:instructions ~tools:[]
      ~initial_messages
      ~model_input_projection:None ~on_transmitted_model_input:(fun report -> reports := report :: !reports)
      ~hooks:(Some hooks) ~context_injector:None ~context:(Some (Agent_core.Context.create ()))
      ~event_bus:None ~raw_trace:None ~on_event:None ~config ()
  in
  test ~run ~capture ~reports

let read_requests path = In_channel.with_open_bin path In_channel.input_lines
  |> List.map Yojson.Safe.from_string

let successful attempt = match attempt.Keeper_codex_runtime.result with
  | Ok _ -> ()
  | Error error -> fail (Agent_core.Error.to_string error)

let test_resume_persists_no_per_turn_context () =
  (* Current instructions and observation frames replace configuration; only
     actual initial conversation rows are injected into persistent history. *)
  with_fixture @@ fun ~run ~capture ~reports ->
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
  check string "autonomous cue stays user input"
    "Continue from current World State."
    (params "turn/start" resumed |> member "input" |> items |> List.hd |> member "text" |> text);
  let instructions rows method_ = params method_ rows |> member "developerInstructions" |> text in
  let resumed_instructions = instructions resumed "thread/resume" in
  check bool "resume carries current instructions" true
    (String.starts_with ~prefix:"Keeper revision 2:" resumed_instructions);
  check bool "resume carries current world frame" true
    (String_util.contains_substring resumed_instructions "task-003 todo");
  check bool "resume does not retain old world frame in configuration" false
    (String_util.contains_substring resumed_instructions "task-001 done");
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
      Keeper_official_client_host.Whole_input_transmitted _] -> ()
   | _ -> fail "both turns transmit current canonical context; vendor tool history stays external")

let test_rejected_context_never_submits_turn () =
  with_fixture ~reject_context:true @@ fun ~run ~capture ~reports ->
  let attempt = run ~instructions:"Keeper current instructions" ~world:"World State: task-003 todo" () in
  check bool "context rejection is a failed turn" true (Result.is_error attempt.Keeper_codex_runtime.result);
  check bool "no model turn after rejected context" false
    (List.exists (fun row -> member "method" row = `String "turn/start") (read_requests capture));
  check int "rejected context never reports transmitted turn input" 0 (List.length !reports)

let test_cooperative_resume_sends_only_remaining_work_instruction () =
  with_fixture @@ fun ~run ~capture ~reports:_ ->
  let initial = run ~instructions:"Keeper instructions" ~world:"Original work" () in
  successful initial;
  let settled = Option.get initial.Keeper_codex_runtime.settled_session in
  let session_id, turn_id = match settled.Keeper_official_client_session_store.phase with
    | Settled settlement -> settlement.session_id, settlement.turn_id
    | _ -> fail "fixture did not settle a native thread" in
  let operation_id = Keeper_chat_operation.Operation_id.of_string "cooperative-original" |> require in
  let seed = match Keeper_semantic_execution.create
      ~id:(Keeper_execution_scope_id.direct_operation operation_id)
      ~input:(`String "original user input") ~sources:[] ~now:1. with
    | Ok value -> value | Error error -> fail (Keeper_semantic_execution.error_to_string error) in
  let observed : Keeper_semantic_execution.official_client_checkpoint =
    { client_kind=settled.client_kind;runtime_id=settled.runtime_id;session_id;turn_id;
      tool_surface_sha256=settled.tool_surface_sha256;frame=seed.frame } in
  let steering = run ~instructions:"Keeper instructions" ~world:"Newer steering" () in
  successful steering;
  let checkpoint = Keeper_direct_checkpoint_continuation.For_testing.prepare_official_resume
    ~observed ~expected:steering.Keeper_codex_runtime.settled_session |> require in
  check bool "steering advances admission turn" true (not (String.equal observed.turn_id checkpoint.turn_id));
  let before = List.length (read_requests capture) in
  let goal = Keeper_direct_checkpoint_continuation.official_resume_message ~operation_id in
  successful (run ~official_client_continuation:checkpoint ~official_client_original_turn:observed ~goal
    ~instructions:"Keeper instructions" ~world:"Newer steering" ());
  let rows = read_requests capture |> List.filteri (fun index _ -> index >= before) in
  check bool "cooperative continuation resumes the original vendor thread" true
    (List.exists (fun row -> member "method" row = `String "thread/resume") rows);
  check bool "cooperative continuation never injects old input/history again" false
    (List.exists (fun row -> let method_ = member "method" row in
      method_ = `String "thread/start" || method_ = `String "thread/inject_items") rows);
  let params = List.find (fun row -> member "method" row = `String "turn/start") rows |> member "params" in
  let resume = List.find (fun row -> member "method" row = `String "thread/resume") rows |> member "params" in
  let snapshot = resume |> member "developerInstructions" |> text
    |> String.split_on_char '\n' |> List.rev |> List.hd |> Yojson.Safe.from_string in
  check string "saved unfinished turn remains distinct from newer steering" observed.turn_id
    (snapshot |> member "original_vendor_turn" |> member "turn_id" |> text);
  check string "admission references latest settled turn" checkpoint.turn_id
    (snapshot |> member "admission_vendor_turn" |> member "turn_id" |> text);
  check bool "original operation identity accompanies saved turn" true
    (snapshot |> member "original_vendor_turn" |> member "execution_scope"
      = Keeper_execution_scope_id.to_json (Keeper_execution_scope_id.direct_operation operation_id));
  let sent = params |> member "input" |> items |> List.hd |> member "text" |> text in
  check string "the model receives only continuation intent" goal sent

let test_resumed_context_overflow_shrinks_configuration () =
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
  let initial_messages = List.init 64 (fun index -> Agent_core.Types.user_msg
    (Printf.sprintf "%d:%s" index (String.make 4096 'x'))) in
  successful (run ~initial_messages ~official_client_continuation:checkpoint
    ~official_client_original_turn:checkpoint ~instructions:"Keeper instructions" ~world:"world" ());
  let resumes = read_requests capture |> List.filter (fun row -> member "method" row = `String "thread/resume") in
  match resumes with
  | [first; second] ->
    let wire row = row |> member "params" |> member "developerInstructions" |> text in
    check bool "retry sends smaller replacement configuration" true
      (String.length (wire second) < String.length (wire first));
    List.iter (fun row ->
      check string "both attempts retain original vendor session" session_id
        (row |> member "params" |> member "threadId" |> text);
      let snapshot = wire row |> String.split_on_char '\n' |> List.rev |> List.hd |> Yojson.Safe.from_string in
      check int "source provenance remains whole even when projection shrinks" 64
        (snapshot |> member "source_message_count" |> Yojson.Safe.Util.to_int);
      check string "original operation turn survives capacity retry" turn_id
        (snapshot |> member "original_vendor_turn" |> member "turn_id" |> text)) resumes
  | _ -> fail "expected exactly one context-capacity retry on the same vendor thread"

let () = run "Keeper current Codex context" ["native requests",[
  test_case "resumed context overflow shrinks replacement configuration" `Quick test_resumed_context_overflow_shrinks_configuration;
  test_case "cooperative native resume does not replay original input" `Quick test_cooperative_resume_sends_only_remaining_work_instruction;
  test_case "a resumed native thread is not written to per turn" `Quick test_resume_persists_no_per_turn_context;
  test_case "context injection must be acknowledged before model turn" `Quick test_rejected_context_never_submits_turn]]

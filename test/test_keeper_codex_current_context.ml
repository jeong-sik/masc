(* Drive the production Keeper adapter through fresh and resumed native
   requests. The fixture observes transport input, not model understanding. *)
open Alcotest
open Masc

let write path value = Out_channel.with_open_bin path (fun out -> output_string out value)
let member = Yojson.Safe.Util.member
let text = Yojson.Safe.Util.to_string
let items = Yojson.Safe.Util.to_list
let require = function Ok value -> value | Error detail -> fail detail

let fixture root ~reject_context =
  let capture = Filename.concat root "requests.jsonl" in
  let command = Filename.concat root "codex-fixture" in
  write command (Printf.sprintf {|#!/usr/bin/env python3
import json, sys
if '--masc-warmup' in sys.argv:
    sys.exit(0)
capture = %S
reject_context = %s
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
        item = {'type':'agentMessage','id':'answer','text':'CONTEXT_RECEIVED','phase':'final_answer'}
        emit({'method':'item/completed','params':{'threadId':'context-thread','turnId':turn_id,'completedAtMs':1,'item':item}})
        emit({'method':'turn/completed','params':{'threadId':'context-thread','turn':{'id':turn_id,'items':[item],'status':'completed'}}})
|} capture (if reject_context then "True" else "False"));
  Unix.chmod command 0o700;
  command, capture

let with_fixture ?(reject_context = false) test =
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
  let command, capture = fixture root ~reject_context in
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
  let run ~instructions ~world =
    let hooks = { Agent_core.Hooks.empty with before_turn_params = Some (function
      | Agent_core.Hooks.BeforeTurnParams {current_params;_} ->
        Agent_core.Hooks.AdjustParams {current_params with extra_system_context=Some world}
      | _ -> Agent_core.Hooks.Continue) } in
    Keeper_codex_runtime.run ~runtime_id:"codex.context" ~keeper_name:"context-fixture"
      ~pre_tool_rejects:(ref []) ~base_path:root ~goal:"Continue from current World State."
      ~goal_blocks:None ~system_prompt:instructions ~tools:[]
      ~initial_messages:[Agent_core.Types.user_msg "Previous completed work"]
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

let test_current_context_reaches_resumed_thread () =
  with_fixture @@ fun ~run ~capture ~reports ->
  successful (run ~instructions:"Keeper revision 1: publish the first artifact."
    ~world:"World State: task-001 done; goal awaiting confirmation.");
  let first_requests = read_requests capture in
  successful (run ~instructions:"Keeper revision 2: continue remaining assigned work."
    ~world:"World State: task-003 todo; autonomous-collaboration-continuation executing.");
  let requests = read_requests capture in
  let resumed = List.filteri (fun index _ -> index >= List.length first_requests) requests in
  let methods rows = List.filter_map (fun row -> match member "method" row with
      | `String method_ -> Some method_ | _ -> None) rows in
  check (list string) "resume injects before submitting the next turn"
    ["initialize";"initialized";"account/read";"thread/resume";"thread/inject_items";"turn/start"]
    (methods resumed);
  let params method_ rows = List.find (fun row -> member "method" row = `String method_) rows |> member "params" in
  check string "same vendor session retained" "context-thread"
    (params "thread/resume" resumed |> member "threadId" |> text);
  let injected = params "thread/inject_items" resumed |> member "items" |> items in
  check (list string) "only current developer context injected; no history replay"
    ["developer";"developer"] (List.map (fun item -> member "role" item |> text) injected);
  let content item = member "content" item |> items |> List.hd |> member "text" |> text in
  let current_instructions = content (List.hd injected) in
  check string "updated Keeper instructions are actually injected"
    (String.concat "\n\n" ("Keeper revision 2: continue remaining assigned work." ::
       Keeper_codex_runtime.For_testing.native_posture_note Runtime_native_tools.codex_default))
    current_instructions;
  let context = content (List.nth injected 1) |> Yojson.Safe.from_string in
  check string "latest task and goal reach native model history"
    "World State: task-003 todo; autonomous-collaboration-continuation executing."
    (context |> member "message" |> member "content_blocks" |> items |> List.hd |> member "text" |> text);
  check string "autonomous cue stays user input"
    "Continue from current World State."
    (params "turn/start" resumed |> member "input" |> items |> List.hd |> member "text" |> text);
  let initial = params "thread/inject_items" first_requests |> member "items" |> items in
  check (list string) "fresh session receives seed history and current context"
    ["user";"developer"] (List.map (fun item -> member "role" item |> text) initial);
  (match List.rev !reports with
   | [Keeper_official_client_host.Whole_input_transmitted _;
      Keeper_official_client_host.Held_by_client_session] -> ()
   | _ -> fail "fresh context does not imply transmission of the client-owned history")

let test_rejected_context_never_submits_turn () =
  with_fixture ~reject_context:true @@ fun ~run ~capture ~reports ->
  let attempt = run ~instructions:"Keeper current instructions" ~world:"World State: task-003 todo" in
  check bool "context rejection is a failed turn" true (Result.is_error attempt.Keeper_codex_runtime.result);
  check bool "no model turn after rejected context" false
    (List.exists (fun row -> member "method" row = `String "turn/start") (read_requests capture));
  check int "rejected context never reports transmitted turn input" 0 (List.length !reports)

let () = run "Keeper current Codex context" ["native requests",[
  test_case "current World State and Keeper instructions survive native resume" `Quick test_current_context_reaches_resumed_thread;
  test_case "context injection must be acknowledged before model turn" `Quick test_rejected_context_never_submits_turn]]

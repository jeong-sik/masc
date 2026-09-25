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

let with_fixture ?(reject_context = false) ?(overflow_resume = false) ?max_prompt_bytes test =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
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
%s[codex.context]
[runtime]
default = "codex.context"
|} command
    (match max_prompt_bytes with
     | None -> ""
     | Some bytes -> Printf.sprintf "max-prompt-bytes = %d\n" bytes));
  Runtime.init_default ~config_path |> require;
  let config = match Runtime.get_runtime_by_id "codex.context" with
    | Some {execution=Runtime_execution.Codex_app_server config;_} -> config
    | Some _ | None -> fail "fixture runtime missing" in
  let reports = ref [] in
  let run ?official_task_reference ?model_input_projection
      ?carried_front_seed ?on_model_input_window_observation
      ?(turn_start = Keeper_carried_front.Turn_boundary { end_atom = 0 }) ?(initial_messages=[Agent_core.Types.user_msg "Previous completed work"]) ?official_client_continuation ?(goal="Continue from current World State.") ~instructions ~world () =
    let hooks = { Agent_core.Hooks.empty with before_turn_params = Some (function
      | Agent_core.Hooks.BeforeTurnParams {current_params;_} ->
        Agent_core.Hooks.AdjustParams {current_params with extra_system_context=Some world}
      | _ -> Agent_core.Hooks.Continue) } in
    Keeper_codex_runtime.run
        ~accepts_image_input:(Runtime_agent.runtime_accepts_image_input
          ~runtime:(Runtime.get_runtime_by_id "codex.context" |> Option.get)) ~runtime_id:"codex.context" ~keeper_name:"context-fixture"
      ~turn_start
      ?carried_front_seed
      ?on_model_input_window_observation
      ~pre_tool_rejects:(ref []) ~base_path:root ~goal ?official_task_reference ?official_client_continuation
      ~goal_blocks:None ~system_prompt:instructions ~tools:[]
      ~initial_messages
      ~model_input_projection ~on_transmitted_model_input:(fun report -> reports := report :: !reports)
      ~hooks:(Some hooks) ~context_injector:None ~context:(Some (Agent_core.Context.create ()))
      ~event_bus:None ~raw_trace:None ~on_event:None ~config ()
  in
  test ~run ~capture ~reports

let read_requests path = In_channel.with_open_bin path In_channel.input_lines
  |> List.map Yojson.Safe.from_string

let successful attempt = match attempt.Keeper_codex_runtime.result with
  | Ok _ -> ()
  | Error error -> fail (Agent_core.Error.to_string error)

let turn_text rows =
  List.find (fun row -> member "method" row = `String "turn/start") rows
  |> member "params" |> member "input" |> items |> List.hd |> member "text" |> text

let test_resume_carries_per_turn_context_in_front_of_the_goal () =
  (* The thread holds the conversation, so a Resume sends none of it. The
     per-turn context goes in front of the goal, as the Claude Code lane sends
     it, and stays out of [developerInstructions], which Codex applies only
     when it compacts the thread. *)
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
          ~keeper_name:"context-fixture" with
  | Ok (Some { phase = Recovery_required { failure; _ }; _ }) ->
    check bool "the thread is recorded full, with no activity observed" true
      (failure = Keeper_official_client_session_store.(Vendor_session_full No_activity_observed))
  | Ok _ -> fail "the overflow left no recovery record"
  | Error detail -> fail detail

(* 64 messages of about 4 KiB: roughly 262 KiB of history, so the fixture can
   cross a declared limit without building a large request. *)
let large_history = List.init 64 (fun index -> Agent_core.Types.user_msg
  (Printf.sprintf "%d:%s" index (String.make 4096 'x')))

let declared_limit = 65_536

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

let test_declared_limit_windows_start () =
  (* A Start injects its history as thread items instead of a snapshot; the
     same declared limit bounds it. *)
  with_fixture ~max_prompt_bytes:declared_limit @@ fun ~run ~capture ~reports:_ ->
  successful (run ~initial_messages:large_history ~instructions:"Keeper instructions" ~world:"world" ());
  match params_of "thread/inject_items" (read_requests capture) with
  | [injected] ->
    let injected = injected |> member "items" |> items in
    check bool "older history was cut before the thread was seeded" true
      (injected <> [] && List.length injected < 64);
    check bool "the newest message is seeded" true
      (String_util.contains_substring
         (Yojson.Safe.to_string (List.nth injected (List.length injected - 1))) "63:xxxx")
  | rows -> fail (Printf.sprintf "expected one inject_items request, saw %d" (List.length rows))

let test_start_carries_the_range_not_the_whole_history () =
  (* A fresh thread is seeded with the carried range the other official
     clients send, not with every message the keeper holds. Nothing is
     declared here, so no byte window cuts anything and only the range can
     bound the seed. The last completed turn ended at atom 60, so the range
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

let resume_wire ~max_prompt_bytes =
  with_fixture ?max_prompt_bytes @@ fun ~run ~capture ~reports:_ ->
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

let carried ?carried_front_seed ?librarian_front ?(capacity_bytes = Keeper_codex_runtime.For_testing.unbounded_capacity_bytes) turn_start =
  match
    Keeper_codex_runtime.For_testing.carried_projection
      ~capacity_bytes ?carried_front_seed ?librarian_front ~turn_start
      ~keeper_name:"context-fixture" ~runtime_id:"codex.context" large_history
  with
  | Ok messages -> carried_indices messages
  | Error error -> fail (Agent_core.Error.to_string error)

let seed_at first_atom () =
  let front_digest =
    match Runtime_model_input_tail_window.atom_opening_digest large_history first_atom with
    | Some digest -> digest
    | None -> fail "the history opens that atom"
  in
  { Keeper_carried_front.seed =
      Some { Keeper_carried_front.first_atom; front_digest; source = Keeper_carried_front.Ledger }
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
       ~librarian_front:(fun _ ->
         Ok (Keeper_turn_driver_try_provider.Librarian_progress { end_atom = 62 }))
       (Keeper_carried_front.Turn_boundary { end_atom = 60 }))

let test_a_declared_limit_cuts_inside_the_range () =
  (* Room for the omission preamble and two of the ~4 KiB messages: the
     declared ceiling cuts deeper than the range's own front at atom 60, and
     the later front wins. *)
  let measure message = String.length (Keeper_official_client_host.encode_history_message message) in
  let framing =
    match Runtime_model_input_tail_window.minimum_capacity_bytes ~measure_message_bytes:measure large_history with
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
        large_history
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

let test_a_turn_without_a_session_trace_opens_on_the_newest_atom () =
  (* A turn with no session trace, or with a recovery view, cannot read where
     the last completed turn ended. [Turn_boundary { end_atom = 0 }] would
     claim a history with no completed turn and send all of it. *)
  let read = Keeper_carried_front.Turn_boundary { end_atom = 60 } in
  let start ~session_id ~recovery_view =
    Keeper_turn_driver.For_testing.official_client_turn_start ~session_id ~recovery_view
      ~read_boundary:(fun () -> read)
  in
  let unknown = function
    | Keeper_carried_front.Turn_boundary_unknown _ -> true
    | Keeper_carried_front.Turn_boundary _ -> false
  in
  check string "a session trace reads the boundary" (turn_start_to_string read)
    (turn_start_to_string (start ~session_id:(Some "trace-1") ~recovery_view:None));
  check bool "no session trace: unknown" true
    (unknown (start ~session_id:None ~recovery_view:None));
  check bool "a recovery view: unknown" true
    (unknown (start ~session_id:(Some "trace-1") ~recovery_view:(Some ())));
  check bool "no session trace with a recovery view: unknown" true
    (unknown (start ~session_id:None ~recovery_view:(Some ())));
  check (list int) "and a Codex Start without a trace carries the newest atom" [ 63 ]
    (carried (start ~session_id:None ~recovery_view:None))
let test_resume_sends_no_history () =
  (* The thread already holds the conversation. Neither the instructions nor
     the turn input carry any of it, with a declared limit or without one. *)
  List.iter (fun (label, max_prompt_bytes) ->
    let _, wire = resume_wire ~max_prompt_bytes in
    List.iter (fun sent ->
      check bool (label ^ ": no history message is sent") false
        (String_util.contains_substring sent "xxxx")) wire)
    [ "nothing declared", None; "a declared limit", Some declared_limit ]

let test_declared_limit_above_history_changes_nothing () =
  (* (b) A limit the history fits under sends exactly what an undeclared lane
     sends. *)
  let _, undeclared = resume_wire ~max_prompt_bytes:None in
  let _, declared = resume_wire ~max_prompt_bytes:(Some 10_000_000) in
  check (list string) "a limit above the history leaves the request unchanged"
    undeclared declared


let () = run "Keeper current Codex context" ["native requests",[
  test_case "a declared prompt limit windows a Start" `Quick test_declared_limit_windows_start;
  test_case "a Start carries the range, not the whole history" `Quick test_start_carries_the_range_not_the_whole_history;
  test_case "a Resume after a Start sends no history" `Quick test_resume_after_start_sends_no_history;
  test_case "a Resume overflow retries with the whole range" `Quick test_a_resume_overflow_retries_with_the_whole_range;
  test_case "the seed decides the range" `Quick test_the_seed_decides_the_range;
  test_case "a later Librarian position decides the range" `Quick test_a_later_librarian_position_decides_the_range;
  test_case "a declared limit cuts inside the range" `Quick test_a_declared_limit_cuts_inside_the_range;
  test_case "an overflow floor never restores the last atom" `Quick test_the_overflow_floor_does_not_restore_the_newest_atom;
  test_case "an unknown turn start carries the newest atom" `Quick test_an_unknown_turn_start_carries_the_newest_atom;
  test_case "a turn without a session trace opens on the newest atom" `Quick test_a_turn_without_a_session_trace_opens_on_the_newest_atom;
  test_case "a Resume sends none of the history" `Quick test_resume_sends_no_history;
  test_case "a prompt limit above the history changes nothing" `Quick test_declared_limit_above_history_changes_nothing;
  test_case "a continuation's resume overflow ends on a full thread" `Quick test_continuation_resume_overflow_ends_on_a_full_thread;
  test_case "cooperative native resume does not replay original input" `Quick test_cooperative_resume_sends_only_remaining_work_instruction;
  test_case "a resume carries per-turn context in front of the goal" `Quick test_resume_carries_per_turn_context_in_front_of_the_goal;
  test_case "context injection must be acknowledged before model turn" `Quick test_rejected_context_never_submits_turn]]

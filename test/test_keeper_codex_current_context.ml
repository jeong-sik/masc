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
      ?carried_front_seed ?librarian_front
      ?(turn_start = Keeper_carried_front.Turn_boundary { end_atom = 0 }) ?(initial_messages=[Agent_core.Types.user_msg "Previous completed work"]) ?official_client_continuation ?official_client_original_turn ?(goal="Continue from current World State.") ~instructions ~world () =
    let hooks = { Agent_core.Hooks.empty with before_turn_params = Some (function
      | Agent_core.Hooks.BeforeTurnParams {current_params;_} ->
        Agent_core.Hooks.AdjustParams {current_params with extra_system_context=Some world}
      | _ -> Agent_core.Hooks.Continue) } in
    Keeper_codex_runtime.run
        ~accepts_image_input:(Runtime_agent.runtime_accepts_image_input
          ~runtime:(Runtime.get_runtime_by_id "codex.context" |> Option.get)) ~runtime_id:"codex.context" ~keeper_name:"context-fixture"
      ~turn_start
      ?carried_front_seed ?librarian_front
      ~pre_tool_rejects:(ref []) ~base_path:root ~goal ?official_task_reference ?official_client_continuation ?official_client_original_turn
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
  let rejected = run ~official_task_reference ~official_client_continuation:checkpoint
    ~official_client_original_turn:observed ~goal
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
  successful (run ~official_task_reference ~official_client_continuation:checkpoint ~official_client_original_turn:observed ~goal
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
  let historical_task = snapshot |> member "messages" |> items
    |> List.find_map (fun envelope ->
      let message = envelope |> member "message" in
      match message |> member "content_blocks" |> items with
      | (`Assoc fields) :: _ -> (match List.assoc_opt "text" fields with
          | Some (`String encoded) -> (match Yojson.Safe.from_string encoded with
              | `Assoc task_fields as task when List.assoc_opt "schema" task_fields =
                  Some (`String "masc.official-client-historical-task.v1") -> Some task
              | _ -> None | exception Yojson.Json_error _ -> None)
          | Some _ | None -> None)
      | _ -> None)
    |> function Some task -> task | None -> fail "original task text has no model-visible mapping" in
  check string "original admitted text mapped after newer steering" original_task
    (historical_task |> member "admitted_message" |> text);
  check string "historical task mapped to original operation" "cooperative-original"
    (historical_task |> member "operation_id" |> text);
  check string "task reference retains saved vendor turn" observed.turn_id
    (historical_task |> member "original_vendor_turn" |> member "turn_id" |> text);
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

(* #37353. 64 messages of about 4 KiB: roughly 262 KiB of history, well under
   the app-server's 10 MiB string limit, so the fixture can cross a declared
   limit without building a 10 MiB request. *)
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

let snapshot_of_instructions instructions =
  instructions |> String.split_on_char '\n' |> List.rev |> List.hd |> Yojson.Safe.from_string

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

let test_declared_limit_windows_resume_before_send () =
  (* (a) The limit is applied to the first attempt. Before #37353 the Resume
     went out whole and only a provider refusal narrowed it -- a refusal that
     arrives after a tool has run cannot be retried. *)
  with_fixture ~max_prompt_bytes:declared_limit @@ fun ~run ~capture ~reports:_ ->
  let attempt, rows = resume_large_history ~capture
    ~start:(fun () -> run ~instructions:"Keeper instructions" ~world:"world" ())
    ~resume:(fun checkpoint -> run ~initial_messages:large_history
      ~official_client_continuation:checkpoint ~official_client_original_turn:checkpoint
      ~instructions:"Keeper instructions" ~world:"world" ()) in
  successful attempt;
  (match params_of "thread/resume" rows, params_of "turn/start" rows with
   | [resume], [turn] ->
     let instructions = resume |> member "developerInstructions" |> text in
     let goal = turn_input turn in
     check bool "developerInstructions and goal fit the declared limit" true
       (String.length instructions + String.length goal <= declared_limit);
     let snapshot = snapshot_of_instructions instructions in
     let kept = snapshot |> member "messages" |> items in
     check bool "older history was cut before sending" true
       (kept <> [] && List.length kept < 64);
     check bool "the newest message survives the cut" true
       (String_util.contains_substring instructions "63:xxxx");
     check int "provenance still names the whole source" 64
       (snapshot |> member "source_message_count" |> Yojson.Safe.Util.to_int)
   | resumes, turns ->
     fail (Printf.sprintf
       "expected one windowed Resume and no overflow retry, saw %d resumes and %d turns"
       (List.length resumes) (List.length turns)))

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
      ~official_client_continuation:checkpoint ~official_client_original_turn:checkpoint
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

let test_undeclared_limit_sends_whole_history () =
  (* (c) Nothing declared and no completed turn on this history: the carried
     range is the whole history, so the Resume carries every message. *)
  let instructions, _ = resume_wire ~max_prompt_bytes:None in
  let kept = snapshot_of_instructions instructions |> member "messages" |> items in
  check int "no completed turn: every message is carried" 64 (List.length kept)

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
      Some { Keeper_carried_front.first_atom; front = Model_input_front.At_atom front_digest; source = Keeper_carried_front.Ledger }
  ; unreadable = None
  ; boundary_error = None
  }

let test_resume_after_start_carries_the_range () =
  (* Both requests hold the same 64-message checkpoint. Start takes the
     turn's boundary; Resume gets the carried front reported by that first
     request, even when its own turn boundary cannot be read. *)
  with_fixture @@ fun ~run ~capture ~reports:_ ->
  let first = run ~initial_messages:large_history
    ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 60 })
    ~instructions:"Keeper instructions" ~world:"world" () in
  successful first;
  let before = List.length (read_requests capture) in
  successful (run ~initial_messages:large_history
    ~carried_front_seed:(seed_at 60)
    ~turn_start:(Keeper_carried_front.Turn_boundary_unknown { reason = "fixture" })
    ~instructions:"Keeper instructions" ~world:"world" ());
  let first_rows = read_requests capture |> List.filteri (fun index _ -> index < before) in
  let resumed_rows = read_requests capture |> List.filteri (fun index _ -> index >= before) in
  let start_messages = match params_of "thread/inject_items" first_rows with
    | [params] -> params |> member "items" |> items
    | rows -> fail (Printf.sprintf "expected one Start injection, saw %d" (List.length rows)) in
  let resume_messages = match params_of "thread/resume" resumed_rows with
    | [params] -> params |> member "developerInstructions" |> text
      |> snapshot_of_instructions |> member "messages" |> items
    | rows -> fail (Printf.sprintf "expected one Resume, saw %d" (List.length rows)) in
  let start_carries index = snapshot_carries start_messages index in
  List.iter (fun (label, carries, messages) ->
    check (list bool) (label ^ " carries atoms 60..63") [ true; true; true; true ]
      (List.map carries [ 60; 61; 62; 63 ]);
    check bool (label ^ " excludes earlier atoms") false
      (carries 59 || carries 0);
    check int (label ^ " sends only the range") 4 (List.length messages))
    [ "Start", start_carries, start_messages;
      "Resume", snapshot_carries resume_messages, resume_messages ]

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

(* A response accepted no prior history, but the next request can retain the
   Librarian's fitting summary and its separately delivered current goal. The
   summary must not resurrect the omitted final atom or bypass a real ceiling. *)
let test_empty_history_keeps_a_fitting_summary ?max_prompt_bytes ~oversized () =
  with_fixture ?max_prompt_bytes @@ fun ~run ~capture ~reports ->
  let trace_id = "accepted-empty-summary" in
  let summary_marker = "KEEP_CONTINUITY_WITHOUT_OLD_ATOMS" in
  let working_state = summary_marker ^
    if oversized then String.make (2 * declared_limit) 's' else ": prior work is complete." in
  let position = match Keeper_turn_boundaries.position_of_messages large_history with
    | Ok position -> position | Error detail -> fail detail in
  let lines = [ 1, Ok
    { Keeper_turn_boundaries.recorded_at = 1.
    ; event = Keeper_turn_boundaries.Turn_ended
        { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1
        ; history_at_start = Fresh_history; position }
    } ] in
  let snapshot = match Librarian_continuity_snapshot.capture
    ~trace_id ~lines ~messages:large_history ~working_state with
    | Ok snapshot -> snapshot
    | Error error -> fail (Librarian_continuity_snapshot.error_to_string error) in
  let librarian_front messages =
    (match Librarian_continuity_snapshot.restore ~trace_id ~lines ~messages snapshot with
     | Ok _ -> ()
     | Error error -> fail (Librarian_continuity_snapshot.error_to_string error));
    Ok (Keeper_turn_driver_try_provider.Librarian_snapshot snapshot)
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
  check bool "a fitting summary survives; an oversized summary stays out"
    (not oversized) (String_util.contains_substring instructions summary_marker);
  (match params_of "turn/start" requests with
   | [params] -> check string "current goal is still sent separately" goal (turn_input params)
   | _ -> fail "summary handling should not need another provider attempt");
  (match !reports with
   | [Keeper_official_client_host.Whole_input_transmitted messages] ->
     check (list int) "no omitted atom was resurrected" [] (carried_indices messages);
     check bool "reported composition agrees with the native instructions"
       (not oversized) (List.exists Runtime_model_input_tail_window.is_working_state messages)
   | _ -> fail "expected one transmitted input observation")

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

let test_declared_limit_above_history_changes_nothing () =
  (* (b) A limit the history fits under sends exactly what an undeclared lane
     sends. *)
  let _, undeclared = resume_wire ~max_prompt_bytes:None in
  let _, declared = resume_wire ~max_prompt_bytes:(Some 10_000_000) in
  check (list string) "a limit above the history leaves the request unchanged"
    undeclared declared


let () = run "Keeper current Codex context" ["native requests",[
  test_case "a declared prompt limit windows a Resume before it is sent" `Quick test_declared_limit_windows_resume_before_send;
  test_case "a declared prompt limit windows a Start" `Quick test_declared_limit_windows_start;
  test_case "a Start carries the range, not the whole history" `Quick test_start_carries_the_range_not_the_whole_history;
  test_case "a Resume after a Start carries the range" `Quick test_resume_after_start_carries_the_range;
  test_case "the seed decides the range" `Quick test_the_seed_decides_the_range;
  test_case "a later Librarian position decides the range" `Quick test_a_later_librarian_position_decides_the_range;
  test_case "accepted empty history retains its summary without a ceiling" `Quick
    (test_empty_history_keeps_a_fitting_summary ~oversized:false);
  test_case "accepted empty history retains a summary under a fitting ceiling" `Quick
    (test_empty_history_keeps_a_fitting_summary ~max_prompt_bytes:declared_limit ~oversized:false);
  test_case "accepted empty history still omits an oversized summary" `Quick
    (test_empty_history_keeps_a_fitting_summary ~max_prompt_bytes:declared_limit ~oversized:true);
  test_case "a declared limit cuts inside the range" `Quick test_a_declared_limit_cuts_inside_the_range;
  test_case "an overflow floor never restores the last atom" `Quick test_the_overflow_floor_does_not_restore_the_newest_atom;
  test_case "an unknown turn start carries the newest atom" `Quick test_an_unknown_turn_start_carries_the_newest_atom;
  test_case "a turn without a session trace opens on the newest atom" `Quick test_a_turn_without_a_session_trace_opens_on_the_newest_atom;
  test_case "no declared prompt limit sends the whole history" `Quick test_undeclared_limit_sends_whole_history;
  test_case "a prompt limit above the history changes nothing" `Quick test_declared_limit_above_history_changes_nothing;
  test_case "resumed context overflow shrinks replacement configuration" `Quick test_resumed_context_overflow_shrinks_configuration;
  test_case "cooperative native resume does not replay original input" `Quick test_cooperative_resume_sends_only_remaining_work_instruction;
  test_case "a resumed native thread is not written to per turn" `Quick test_resume_persists_no_per_turn_context;
  test_case "context injection must be acknowledged before model turn" `Quick test_rejected_context_never_submits_turn]]

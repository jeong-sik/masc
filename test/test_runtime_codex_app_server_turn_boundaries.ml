open Alcotest
open Masc

let init_result =
  {|{"id":1,"result":{"userAgent":"fixture/0.147.0","codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"linux"}}|}
;;

let account_chatgpt =
  {|{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.test","planType":"pro"},"requiresOpenaiAuth":true}}|}
;;

let thread_result =
  {|{"id":3,"result":{"thread":{"id":"thread-1"},"model":"gpt-fixture"}}|}
;;

let turn_result = {|{"id":4,"result":{"turn":{"id":"turn-1"}}}|}

let item_completed =
  {|{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":1,"item":{"type":"agentMessage","id":"message-1","text":"MASC_SUBSCRIPTION_OK","phase":"final_answer"}}}|}
;;

let turn_completed =
  {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[{"type":"agentMessage","id":"message-1","text":"MASC_SUBSCRIPTION_OK","phase":"final_answer"}],"status":"completed"}}}|}
;;

let turn_failed =
  {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"fixture provider rejection"}}}}|}
;;

let shell_quote value =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' value) ^ "'"
;;

let rec drop count values =
  if count <= 0
  then values
  else
    match values with
    | [] -> []
    | _ :: rest -> drop (count - 1) rest
;;

(* macOS charges a one-time check on the first exec of every freshly written
   executable — measured at 0.26-0.33s (tail past 0.5s under load) on the
   reference machine, against 5-16ms for a re-run of the same file. The
   sub-100ms admission timeouts in this suite sat under that cost and timed
   out during the handshake (#31220). Every fixture script therefore takes a
   [--masc-warmup] first argument that exits before touching stdin, and is
   executed once with it right after creation, so the measured run pays only
   the re-run cost. *)

(* Two orders of magnitude above the measured first-exec cost. Only a wedged
   system check should ever reach it. *)
let warmup_deadline_s = 10.0

(* The warmup must be bounded: under full-suite load the first-exec check
   itself can wedge — a stack sample of this binary stuck for 5+ minutes
   showed 100% of samples inside [Sys.command]'s wait4 on the warmup child
   (#32181), so the unbounded wait turned a latency workaround into a
   suite-wide hang. The warmup is best-effort by design: on deadline the
   child is killed and the measured run pays the first-exec cost itself,
   which costs accuracy on one admission timing, not the whole suite. The
   child is spawned directly rather than through [Sys.command]'s shell so
   the deadline kill reaches the script, not an intermediate [sh]. *)
let warm_fresh_executable path =
  match
    Unix.create_process
      path
      [| path; "--masc-warmup" |]
      Unix.stdin
      Unix.stdout
      Unix.stderr
  with
  | exception Unix.Unix_error _ -> ()
  | pid ->
    let deadline = Unix.gettimeofday () +. warmup_deadline_s in
    let rec reap_blocking () =
      match Unix.waitpid [] pid with
      | _ -> ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap_blocking ()
      | exception Unix.Unix_error _ -> ()
    in
    let rec wait () =
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ ->
        if Unix.gettimeofday () >= deadline
        then begin
          (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
          reap_blocking ()
        end
        else begin
          Unix.sleepf 0.01;
          wait ()
        end
      | _, _ -> ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
      | exception Unix.Unix_error _ -> ()
    in
    wait ()
;;

let fixture_script ?(await_dynamic_tools = true) ?(close_before_turn = false) ?(close_after_injection = false) ?(inject_items = false) ?(model_pages = []) ?(model_pages_before_thread = false) ?capture_path ?initial_line_delay_s ?terminal_line_delay_s
    ?(terminal_line_delay_start_index = 0) ?(line_delays = []) ?before_final_stdin_drain_s
    ?pipe_holder_s ?break_raw_trace_path lines =
  let path = Filename.temp_file "masc-codex-app-server-" ".sh" in
  let output = open_out_bin path in
  let read_request ?(expect_version = false) () =
    output_string output "IFS= read -r request || exit 98\n";
    if expect_version
    then
      output_string output
        (Printf.sprintf
           "printf '%%s' \"$request\" | grep -F %s >/dev/null || exit 97\n"
           (shell_quote (Printf.sprintf {|"version":"%s"|} Runtime_build_version.current)));
    Option.iter
      (fun capture_path ->
         output_string
           output
           ("printf '%s\\n' \"$request\" >> " ^ shell_quote capture_path ^ "\n"))
      capture_path
  in
  let capture_request () =
    output_string output "IFS= read -r request || exit 98\n";
    Option.iter
      (fun capture_path ->
         output_string
           output
           ("printf '%s\\n' \"$request\" >> " ^ shell_quote capture_path ^ "\n"))
      capture_path
  in
  output_string output "#!/bin/sh\n";
  output_string output "case \"$1\" in --masc-warmup) exit 0 ;; esac\n";
  read_request ~expect_version:true ();
  Option.iter (fun path ->
    output_string output ("mv " ^ shell_quote path ^ " " ^ shell_quote (path ^ ".before")
      ^ " && mkdir " ^ shell_quote path ^ "\n")) break_raw_trace_path;
  Option.iter
    (fun seconds -> output_string output (Printf.sprintf "sleep %.3f\n" seconds))
    initial_line_delay_s;
  output_string output ("printf '%s\\n' " ^ shell_quote (List.nth lines 0) ^ "\n");
  read_request ();
  read_request ();
  output_string output ("printf '%s\\n' " ^ shell_quote (List.nth lines 1) ^ "\n");
  if model_pages_before_thread then List.iter (fun page ->
    read_request ();
    output_string output ("printf '%s\\n' " ^ shell_quote page ^ "\n")) model_pages;
  read_request ();
  if close_before_turn then output_string output "exec 0<&-\n";
  output_string output ("printf '%s\\n' " ^ shell_quote (List.nth lines 2) ^ "\n");
  if close_before_turn then output_string output "exit 62\n";
  capture_request ();
  if not model_pages_before_thread then List.iter (fun page ->
    output_string output ("printf '%s\\n' " ^ shell_quote page ^ "\n");
    capture_request ()) model_pages;
  let remaining_lines =
    if inject_items then (
      (* Acknowledge thread/inject_items before reading/capturing turn/start.
         Sending all replies up front lets the host finish before the fixture
         has observed the request whose exact bytes the test asserts. *)
      if close_after_injection then output_string output "exec 0<&-\n";
      output_string output ("printf '%s\\n' " ^ shell_quote (List.nth lines 3) ^ "\n");
      if close_after_injection then output_string output "exit 63\n";
      read_request ();
      drop 4 lines)
    else drop 3 lines
  in
  List.iter
    (fun (index, _) ->
       if index < 0 || index >= List.length remaining_lines
       then
         invalid_arg
           (Printf.sprintf
              "line_delays index %d is outside the %d lines after the handshake"
              index
              (List.length remaining_lines)))
    line_delays;
  (* A background child that inherits stdout and stderr and outlives the
     CLI, the shape an orphaned MCP server leaves behind. It starts before
     the terminal lines so the race with termination cannot skip it. *)
  Option.iter
    (fun seconds -> output_string output (Printf.sprintf "sleep %.3f &\n" seconds))
    pipe_holder_s;
  List.iteri
    (fun index line ->
       (* A pause before one chosen line, by its index among the lines after
          the handshake, so one silent gap can sit inside or after an item. *)
       Option.iter
         (fun seconds -> output_string output (Printf.sprintf "sleep %.3f\n" seconds))
         (List.assoc_opt index line_delays);
       if index >= terminal_line_delay_start_index
       then
         Option.iter
           (fun seconds ->
              output_string output (Printf.sprintf "sleep %.3f\n" seconds))
           terminal_line_delay_s;
       output_string output ("printf '%s\\n' " ^ shell_quote line ^ "\n");
       if await_dynamic_tools then
         match (try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None) with
         | Some (`Assoc fields) when List.assoc_opt "method" fields = Some (`String "item/tool/call") ->
           output_string output "IFS= read -r tool_result || exit 98\n"
         | Some _ | None -> ())
    remaining_lines;
  Option.iter
    (fun seconds -> output_string output (Printf.sprintf "sleep %.3f\n" seconds))
    before_final_stdin_drain_s;
  output_string output "while IFS= read -r ignored; do :; done\n";
  close_out output;
  Unix.chmod path 0o700;
  warm_fresh_executable path;
  path
;;

let with_fixture ?await_dynamic_tools ?close_before_turn ?close_after_injection ?inject_items ?model_pages ?model_pages_before_thread ?capture_path ?initial_line_delay_s ?terminal_line_delay_s
    ?terminal_line_delay_start_index ?line_delays ?before_final_stdin_drain_s ?pipe_holder_s ?break_raw_trace_path lines f =
  let path =
    fixture_script
      ?await_dynamic_tools
      ?close_before_turn
      ?close_after_injection
      ?inject_items
      ?model_pages
      ?model_pages_before_thread
      ?capture_path
      ?initial_line_delay_s
      ?terminal_line_delay_s
      ?terminal_line_delay_start_index
      ?line_delays
      ?before_final_stdin_drain_s
      ?pipe_holder_s
      ?break_raw_trace_path
      lines
  in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let codex_runtime_toml ~model cli_path =
  Printf.sprintf
    "[providers.codex]\n\
     protocol = \"codex-app-server\"\n\
     command = %S\n\
     is-non-interactive = true\n\
     \n\
     [models.codex]\n\
     api-name = %S\n\
     max-context = 400000\n\
     \n\
     [codex.codex]\n\
     \n\
     [runtime]\n\
     default = \"codex.codex\"\n"
    cli_path
    model
;;

let with_runtime_config ~model cli_path f =
  let path = Filename.temp_file "masc-codex-runtime-" ".toml" in
  let output = open_out_bin path in
  output_string output (codex_runtime_toml ~model cli_path);
  close_out output;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let temp_workspace prefix =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let cleanup_tree root =
  let rec remove path =
    if Sys.file_exists path
    then if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path)
      else Unix.unlink path
  in
  try remove root with
  | _ -> ()
;;

let write_fixture_file path content =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output content)
;;

let production_keeper_meta ~base_path ~trace_id =
  let name = "codex-production-fixture" in
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String name
         ; "trace_id", `String trace_id
         ])
  with
  | Ok meta -> meta
  | Error detail -> fail ("production Keeper meta fixture failed: " ^ detail)
;;

type production_http_fixture =
  { candidates : string list
  ; respond : Yojson.Safe.t -> Cohttp.Code.status_code * string
  }

let projection_http_fixture requests =
  { candidates=["projection.http";"codex.codex"]
  ; respond=(fun _ ->
      incr requests;
      (* Empty HTTP completion is rejected before AfterTurn. *)
      `OK,
      {|{"id":"projection-a","model":"projection-http-fixture","choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"stop"}]}|}) }

(* What every fixture turn is admitted with, so a test can read it back from
   the turn log's [Opened]. *)
let production_fixture_woken_by : Keeper_event_queue.stimulus list =
  [ { post_id = "workspace-message:fixture-request"
    ; urgency = Normal
    ; arrived_at = 0.0
    ; payload =
        Workspace_message { wmsg_request_id = "fixture-request"; wmsg_from = "fixture-sender" }
    }
  ]
;;

(* The sources of a turn's input and of its answer, which decide the history
   file each is written to ({!Keeper_context_core_history}). A direct turn
   writes both to the main file. A turn the Keeper started itself writes its
   answer to the internal file and does not write its wake cue. *)
let direct_history = Keeper_types_support.Direct_user, Keeper_types_support.Direct_assistant

(* Where the fixture's turns keep their sessions, one directory for a trace. *)
let production_fixture_session_base ~base_path = Filename.concat base_path "keeper-sessions"

let run_production_keeper_turn_as ~keeper_turn_id
    ~history:(history_user_source, history_assistant_source)
    ~input_speaker ~turn_kind ~write_cost_ledger ~after_turn
    ~dynamic_context_for_tools
    ~http_fixture ~base_path ~trace_id
    ~user_message ~cli_path ~model ~turn_instructions =
  Masc_test_deps.declare_fixture_keeper
    ~base_path ~sandbox_profile:None "codex-production-fixture";
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
       with_runtime_config ~model cli_path (fun runtime_path ->
         Eio_main.run (fun env ->
                Eio.Switch.run (fun sw ->
                  Fs_compat.set_fs (Eio.Stdenv.fs env);
                  Eio_context.set_env env;
                  (match Runtime_agent_execution_runtime.initialize
                     ~sw ~domain_mgr:env#domain_mgr ~domain_count:1 with
                   | Ok () -> ()
                   | Error error ->
                     fail (Runtime_agent_execution_runtime.initialization_error_to_string error));
                  Eio_context.with_test_env
                    ~net:(Eio.Stdenv.net env)
                    ~clock:(Eio.Stdenv.clock env)
                    ~mono_clock:(Eio.Stdenv.mono_clock env)
                    ~sw
                    (fun () ->
                       let runtime_id = match http_fixture with
                         | None -> "codex.codex"
                         | Some fixture ->
                           let callback _connection _request body =
                             let request=Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all)
                               |> Yojson.Safe.from_string in
                             let status,body=fixture.respond request in
                             Cohttp_eio.Server.respond_string ~status ~body ()
                           in
                           let socket = Eio.Net.listen env#net ~sw ~backlog:1
                             (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
                           let port = match Eio.Net.listening_addr socket with
                             | `Tcp (_, port) -> port
                             | `Unix _ -> fail "expected loopback TCP socket" in
                           Eio.Fiber.fork_daemon ~sw (fun () ->
                             Cohttp_eio.Server.run socket
                               (Cohttp_eio.Server.make ~callback ()) ~on_error:raise);
                           let last_model =
                             if List.mem "projection.http_last" fixture.candidates then {|
[models.http_last]
api-name = "projection-last-fixture"
max-context = 400000
streaming = false
[projection.http_last]
|} else "" in
                           write_fixture_file runtime_path
                             (codex_runtime_toml ~model cli_path ^ Printf.sprintf {|
[providers.projection]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:%d"
[models.http]
api-name = "projection-http-fixture"
max-context = 400000
streaming = false
[projection.http]
%s
[runtime.lanes.projection_then_codex]
candidates = [%s]
|} port last_model (String.concat ", " (List.map (Printf.sprintf "%S") fixture.candidates)));
                           "projection_then_codex"
                       in
                       match Runtime.init_default ~config_path:runtime_path with
                       | Error error -> fail error
                       | Ok () ->
                         let config = Workspace.default_config base_path in
                         (* The call ledger is initialized by the server
                            bootstrap, which this fixture does not run; initialize it to
                            capture the fixture's actual tool receipts. *)
                         Keeper_tool_call_log.init ~base_path ();
                         let meta = production_keeper_meta ~base_path ~trace_id in
                         (match Keeper_meta_store.replace_snapshot config meta with
                          | Ok () -> ()
                          | Error detail -> fail detail);
                         (match Keeper_owner_registry.install_from_store ~sw
                            ~operation_runner:None ~on_turn_slot_released:None config with
                          | Ok _ -> ()
                          | Error _ -> fail "production fixture Owner installation failed");
                         ignore
                           (Keeper_registry.For_testing.register
                              ~base_path
                              meta.name
                              meta);
                         Eio.Switch.on_release sw (fun () ->
                           Keeper_registry.For_testing.unregister
                             ~base_path
                             meta.name);
                         Masc_test_deps.with_publication_recovery_registry
                           ~sw
                           ~fs:(Eio.Stdenv.fs env)
                           ~registry_root:base_path
                           (fun publication_recovery_registry ->
                              let publication_recovery =
                                { Keeper_publication_recovery_availability.provider =
                                    Masc_test_deps.publication_recovery_provider
                                      publication_recovery_registry
                                ; keeper_name = meta.name
                                }
                              in
                              (* The cost ledger is written only with a
                                 trajectory accumulator, as a scheduled
                                 Keeper turn runs. *)
                              let trajectory_acc =
                                if write_cost_ledger
                                then
                                  Some
                                    (Trajectory.create_accumulator
                                       ~masc_root:(Workspace.masc_dir config)
                                       ~keeper_name:meta.name
                                       ~trace_id
                                       ())
                                else None
                              in
                              let run () = Keeper_agent_run.run_turn ~keeper_turn_id
                                ~history_user_source ~history_assistant_source
                                ~approval_admission:Keeper_approval_origin.Unavailable
                                ?trajectory_acc
                                ~config
                                ~meta
                                ~publication_recovery
                                ~profile_defaults:
                                  Keeper_types_profile_defaults.empty_keeper_profile_defaults
                                ~turn_ctx_cell:
                                  (Keeper_tool_call_log.create_turn_ctx_cell ())
                                ~base_dir:(production_fixture_session_base ~base_path)
                                ~max_context:400_000
                                ~build_turn_prompt:
                                  (fun ~base_system_prompt:_ ~messages:_ ->
                                    { Keeper_agent_run.dynamic_context_for_tools
                                    ; dynamic_context =
                                        (match turn_instructions with
                                         | None -> ""
                                         | Some ti ->
                                           "--- Turn-specific instructions ---\n" ^ ti)
                                    })
                                ~user_message
                                ~input_speaker
                                ~woken_by:production_fixture_woken_by
                                ~turn_kind
                                ~skill_snapshot:
                                  (Skill_catalog_snapshot.config_unreadable
                                     ~detail:"test fixture has no Skill publication")
                                ~task_skill_selection:(Ok Keeper_task_skill_turn.empty)
                                ~runtime_id
                                () in
                              let settlement = match Keeper_owner_registry.run_autonomous_if_idle
                                  ~base_path ~keeper_name:meta.name run with
                                | Ok (`Ran settlement) -> settlement
                                | Ok (`Busy block) -> fail (Keeper_owner.autonomous_block_to_string block)
                                | Ok `Interrupted -> fail "production fixture Owner child was interrupted"
                                | Error error -> fail (Keeper_owner_registry.command_error_to_string error) in
                              (* Read while the turn's runtime catalog is
                                 still the published one. *)
                              after_turn settlement;
                              settlement.Keeper_agent_run.result))))))
;;

let run_production_keeper_turn_with_projection ~write_cost_ledger ~after_turn
    ~dynamic_context_for_tools ~http_requests ~base_path ~trace_id
    ~user_message ~cli_path ~model ~turn_instructions =
  run_production_keeper_turn_as ~keeper_turn_id:1 ~history:direct_history
    ~input_speaker:(Keeper_input_speaker.Person Keeper_input_speaker.Owner)
    ~turn_kind:Turn_record.Direct
    ~write_cost_ledger ~after_turn ~dynamic_context_for_tools
    ~http_fixture:(Option.map projection_http_fixture http_requests)
    ~base_path ~trace_id ~user_message ~cli_path ~model ~turn_instructions
;;

let run_production_keeper_turn_with_predecessor ~http_requests ~base_path ~trace_id
    ~user_message ~cli_path ~model ~turn_instructions =
  run_production_keeper_turn_with_projection ~write_cost_ledger:false ~after_turn:ignore ~dynamic_context_for_tools:None
    ~http_requests ~base_path ~trace_id ~user_message ~cli_path ~model ~turn_instructions
;;

let run_production_keeper_turn ~base_path ~trace_id ~user_message ~cli_path ~model
    ~turn_instructions =
  run_production_keeper_turn_with_predecessor ~http_requests:None ~base_path
    ~trace_id ~user_message ~cli_path ~model ~turn_instructions
;;

(* The same turn with its number and its history files chosen. *)
let run_production_keeper_turn_numbered ~keeper_turn_id ~history ~base_path ~trace_id
    ~user_message ~cli_path =
  run_production_keeper_turn_as ~keeper_turn_id ~history
    ~input_speaker:(Keeper_input_speaker.Person Keeper_input_speaker.Owner)
    ~turn_kind:Turn_record.Direct ~write_cost_ledger:false ~after_turn:ignore
    ~dynamic_context_for_tools:None ~http_fixture:None ~base_path ~trace_id ~user_message
    ~cli_path ~model:"gpt-fixture" ~turn_instructions:None
;;

(* Four complete Keeper turns, with the real checkpoint reader, observation
   collector, TurnRecord writer and next-turn seed reader. The fake provider
   retains the first thread's history, refuses its Resume on turn two, and
   rejects fresh Start retries until their carried range is empty. Turn three
   starts a new vendor lifecycle and must reuse the persisted empty boundary;
   a fourth ordinary Resume reports no newly transmitted history. Each turn
   recreates the runtime catalog, and no test-supplied seed can conceal a
   missing durable boundary. *)
let test_production_empty_retry_boundary_survives_the_next_turn () =
  let base_path = temp_workspace "masc-codex-empty-boundary-" in
  Fun.protect ~finally:(fun () -> cleanup_tree base_path) (fun () ->
    let keeper_name = "codex-production-fixture" in
    let trace_id = "empty-boundary-trace" in
    let capture = Filename.concat base_path "requests.jsonl" in
    let phase = Filename.concat base_path "phase" in
    let cli_path = Filename.concat base_path "codex-empty-fixture" in
    write_fixture_file cli_path (Printf.sprintf {|#!/usr/bin/env python3
import json, sys
from pathlib import Path
if '--masc-warmup' in sys.argv:
    sys.exit(0)
capture, phase_path = %S, %S
with open(phase_path) as source:
    phase = int(source.read())
vendor_path = Path(capture + '.vendor-state')
state = json.loads(vendor_path.read_text()) if vendor_path.exists() else {'threads': {}}
thread = None
contains_history = False
def save_thread():
    state['threads'][thread] = {'contains_history': contains_history}
    vendor_path.write_text(json.dumps(state))
def emit(value):
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    with open(capture, 'a') as output:
        output.write(json.dumps({'phase': phase, 'request': request, 'thread': thread, 'held_history': contains_history}) + '\n')
    method, ident = request.get('method'), request.get('id')
    params = request.get('params', {})
    if method == 'initialize':
        emit({'id': ident, 'result': {'userAgent': 'fixture/0.147.0', 'codexHome': '/tmp/codex', 'platformFamily': 'unix', 'platformOs': 'linux'}})
    elif method == 'account/read':
        emit({'id': ident, 'result': {'account': {'type': 'chatgpt', 'email': 'fixture@example.test', 'planType': 'pro'}, 'requiresOpenaiAuth': True}})
    elif method == 'thread/start':
        thread = 'empty-thread-' + str(len(state['threads']) + 1)
        contains_history = 'OMITTED_HISTORY_' in params.get('developerInstructions', '')
        save_thread()
        emit({'id': ident, 'result': {'thread': {'id': thread}, 'model': 'gpt-fixture'}})
    elif method == 'thread/resume':
        thread = params['threadId']
        contains_history = state['threads'][thread]['contains_history']
        emit({'id': ident, 'result': {'thread': {'id': thread}, 'model': 'gpt-fixture'}})
    elif method == 'thread/inject_items':
        payload = json.dumps(params)
        contains_history = contains_history or ('OMITTED_HISTORY_' in payload or 'Continue operation' in payload or 'MASC_SUBSCRIPTION_OK' in payload)
        save_thread()
        emit({'id': ident, 'result': {}})
    elif method == 'turn/start':
        turn = thread + '-turn-' + str(phase)
        emit({'id': ident, 'result': {'turn': {'id': turn}}})
        if phase == 2 and contains_history:
            emit({'method': 'turn/completed', 'params': {'threadId': thread, 'turn': {'id': turn, 'items': [], 'status': 'failed', 'error': {'message': 'context is full', 'codexErrorInfo': 'contextWindowExceeded'}}}})
        else:
            item = {'type': 'agentMessage', 'id': 'answer', 'text': 'MASC_SUBSCRIPTION_OK', 'phase': 'final_answer'}
            emit({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': turn, 'completedAtMs': 1, 'item': item}})
            emit({'method': 'turn/completed', 'params': {'threadId': thread, 'turn': {'id': turn, 'items': [item], 'status': 'completed'}}})
|} capture phase);
    Unix.chmod cli_path 0o700;
    let history = List.init 8 (fun index -> Agent_core.Types.user_msg
      (Printf.sprintf "OMITTED_HISTORY_%d:%s" index (String.make 4096 'x'))) in
    let checkpoint = Keeper_context_runtime.create ~eio:false
      ~system_prompt:"Synthetic retained history."
      |> fun ctx -> List.fold_left Keeper_context_runtime.append ctx history
      |> Keeper_context_runtime.checkpoint_of_context in
    let checkpoint = { checkpoint with session_id = trace_id; turn_count = 1 } in
    let session_dir = Filename.concat (Filename.concat base_path "keeper-sessions") trace_id in
    (* A completed turn closed the first four atoms; the retained turn holds
       the last four open. The turn log starts at the closed ones when the
       first run is admitted, and the request opens there. *)
    (match Keeper_checkpoint_store.save_agent_core_if_absent ~boundary:Agent_core.Checkpoint_objects.Turn_closes
      ~session_dir
      { checkpoint with messages = List.filteri (fun index _ -> index < 4) checkpoint.messages } with
     | Installed { auxiliary = []; _ } -> ()
     | Installed _ | Not_installed _ -> fail "could not seed the completed turn");
    (match Keeper_checkpoint_store.save_agent_core_classified ~session_dir ~history_retained:0
      ~boundary:Agent_core.Checkpoint_objects.Turn_continues checkpoint with
     | Ok (Keeper_checkpoint_store.Saved _) -> ()
     | Ok (Keeper_checkpoint_store.Stale_noop _) -> fail "the retained turn was read as stale"
     | Error detail -> fail ("could not seed retained history: " ^ detail));
    let config = Workspace.default_config base_path in
    let digest_at = Runtime_model_input_tail_window.atom_opening_digest history in
    let boundary : Keeper_turn_boundaries.record =
      { recorded_at = 1.
      ; event = Keeper_turn_boundaries.Turn_ended
          { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:0
          ; history_at_start = Fresh_history
          ; position = Atom_history
              { end_atom = 4; last_atom_digest = Option.get (digest_at 3) }
          }
      } in
    (match Keeper_turn_boundaries.append
       ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name boundary with
     | Ok () -> ()
     | Error error -> fail (Keeper_turn_boundaries.append_error_to_string error));
    let run phase_number =
      write_fixture_file phase (string_of_int phase_number);
      (match run_production_keeper_turn_numbered ~keeper_turn_id:phase_number
        ~history:direct_history ~base_path ~trace_id
        ~user_message:(Printf.sprintf "Continue operation %d." phase_number)
        ~cli_path with
       | Ok _ -> ()
       | Error error -> fail (Agent_core.Error.to_string error));
      match Dated_jsonl.read_recent
        (Keeper_types_support.keeper_turn_record_store config keeper_name) 1 with
      | [row] -> (match Turn_record.of_json row with
        | Ok record -> record | Error detail -> fail detail)
      | _ -> fail "expected the actual turn writer's newest record"
    in
    let keepers_dir = Workspace.keepers_runtime_dir config in
    let bridged_history () =
      match Keeper_turn_bridge.uncheckpointed_official_turns ~keepers_dir
        ~keeper_name ~trace_id ~session_dir ~existing_messages:history with
      | Ok msgs -> history @ msgs
      | Error error -> fail (Keeper_turn_bridge.bridge_load_error_to_string error)
    in
    let first = run 1 in
    (match first.response_observed_model_input with
     | Some { window = { transmitted_atoms = 4; total_atoms = 8; _ }; _ } -> ()
     | _ -> fail "first turn must establish the carried range 4..7");
    let after_turn1 = bridged_history () in
    check int "turn one adds two bridged atoms on disk" 10 (List.length after_turn1);
    let digest_after_turn1 = Runtime_model_input_tail_window.atom_opening_digest after_turn1 in
    let second = run 2 in
    let expected_empty : Turn_record.model_input_window =
      { transmitted_atoms = 0; total_atoms = 10; measurement = Durable_shape
      ; model_input_front = Model_input_front.After_history (Option.get (digest_after_turn1 9))
      } in
    check bool "empty retry replaces the last rejected projection" true
      (second.model_input_window = Some expected_empty);
    (match second.response_observed_model_input with
     | Some observed -> check bool "response certifies the empty request only" true
         (observed.window = expected_empty)
     | None -> fail "successful empty retry must have response evidence");
    let after_turn2 = bridged_history () in
    check int "turn two adds two more bridged atoms on disk" 12 (List.length after_turn2);
    let digest_after_turn2 = Runtime_model_input_tail_window.atom_opening_digest after_turn2 in
    let settled_thread () =
      match Keeper_official_client_session_store.load ~base_path ~keeper_name |> Result.map_error Keeper_official_client_session_store.read_error_to_string with
      | Ok (Some { phase = Settled settlement; _ }) -> settlement.session_id
      | Ok (Some _) | Ok None -> fail "the successful turn must settle its vendor thread"
      | Error detail -> fail detail
    in
    let second_thread = settled_thread () in
    (* Only the synthetic vendor binding is cleared. TurnRecords and the
       canonical checkpoint survive, so the real runner must read the seed
       again rather than inheriting context from the successful vendor thread. *)
    (match Keeper_official_client_session_store.clear_then
      ~base_path ~keeper_name (fun () -> ()) with
     | Ok () -> ()
     | Error detail -> fail detail);
    let expected_third : Turn_record.model_input_window =
      { transmitted_atoms = 2; total_atoms = 12; measurement = Durable_shape
      ; model_input_front = Model_input_front.At_atom (Option.get (digest_after_turn2 10))
      } in
    let third = run 3 in
    check bool "next fresh lifecycle preserves the durable empty boundary" true
      (third.model_input_window = Some expected_third);
    (match third.response_observed_model_input with
     | Some observed -> check bool "fresh response certifies only post-boundary turns" true
         (observed.window = expected_third)
     | None -> fail "fresh Start must report its accepted post-boundary projection");
    let third_thread = settled_thread () in
    check bool "turn three really starts another vendor thread" true
      (not (String.equal second_thread third_thread));
    let resumed = run 4 in
    check bool "ordinary Resume reports no newly projected history" true
      (Option.is_none resumed.model_input_window);
    check bool "ordinary Resume does not certify an unsent projection" true
      (Option.is_none resumed.response_observed_model_input);
    check string "ordinary Resume keeps the fresh vendor thread" third_thread
      (settled_thread ());
    let seed_read = Keeper_carried_front.read_seed ~config ~keeper_name ~trace_id in
    (match seed_read.seed with
     | Some seed ->
       check int "an unobserved Resume preserves the post-boundary front" 10 seed.first_atom;
       check bool "the boundary still begins at turn two" true
         (seed.front = expected_third.model_input_front)
     | None -> fail "ordinary Resume concealed the prior accepted boundary");
    let rows = In_channel.with_open_bin capture In_channel.input_lines
      |> List.map Yojson.Safe.from_string in
    let requests phase_number method_name =
      let open Yojson.Safe.Util in
      rows |> List.filter_map (fun row ->
        let request = member "request" row in
        if member "phase" row = `Int phase_number
           && member "method" request = `String method_name
        then Some (member "params" request) else None)
    in
    check int "turn two first resumes the vendor-held history" 1
      (List.length (requests 2 "thread/resume"));
    check bool "turn two makes fresh Start shrink attempts" true
      (List.length (requests 2 "thread/start") > 1);
    let second_attempts =
      let open Yojson.Safe.Util in
      rows |> List.filter_map (fun row ->
        if member "phase" row = `Int 2
           && (member "request" row |> member "method") = `String "turn/start"
        then Some (member "held_history" row |> to_bool) else None) in
    (match second_attempts with
     | true :: rest ->
       check bool "fresh retries include a rejected nonempty history" true
         (List.exists Fun.id rest);
       check bool "the successful final attempt holds no old history" false
         (List.hd (List.rev rest))
     | _ -> fail "turn two must overflow the history already held by the Resume");
    check int "turn three is a fresh lifecycle" 1 (List.length (requests 3 "thread/start"));
    check int "turn three does not Resume past the durable seed read" 0
      (List.length (requests 3 "thread/resume"));
    check int "turn three needed no corrective retry" 1
      (List.length (requests 3 "turn/start"));
    List.iter (fun params ->
      check bool "the new current instruction still reaches the provider" true
        (String_util.contains_substring (Yojson.Safe.to_string params) "Continue operation 3."))
      (requests 3 "turn/start");
    let history_requests =
      requests 3 "thread/start" @ requests 3 "thread/resume"
      @ requests 3 "thread/inject_items" in
    check bool "turn three actually wrote history-bearing request frames" true
      (history_requests <> []);
    List.iter (fun params ->
      check bool "third wire never resurrects an omitted history atom" false
        (String_util.contains_substring (Yojson.Safe.to_string params) "OMITTED_HISTORY_");
      check bool "third wire never resurrects pre-empty turn one" false
        (String_util.contains_substring (Yojson.Safe.to_string params) "Continue operation 1."))
      history_requests;
    check bool "third wire carries post-empty turn two" true
      (List.exists (fun params ->
         String_util.contains_substring (Yojson.Safe.to_string params) "Continue operation 2.")
         (requests 3 "thread/inject_items"));
    check int "turn four is one ordinary Resume" 1
      (List.length (requests 4 "thread/resume"));
    check int "ordinary Resume starts no replacement thread" 0
      (List.length (requests 4 "thread/start"));
    check int "ordinary Resume injects no old history" 0
      (List.length (requests 4 "thread/inject_items"));
    check int "ordinary Resume answers without a corrective retry" 1
      (List.length (requests 4 "turn/start"));
    List.iter (fun params ->
      check bool "ordinary Resume receives its new instruction" true
        (String_util.contains_substring (Yojson.Safe.to_string params) "Continue operation 4.");
      check bool "ordinary Resume does not repeat omitted history" false
        (String_util.contains_substring (Yojson.Safe.to_string params) "OMITTED_HISTORY_"))
      (requests 4 "turn/start");
    (* The transmission boundary does not mutate the checkpoint. *)
    match Keeper_checkpoint_store.load_agent_core
      ~session_dir:(Filename.concat (Filename.concat base_path "keeper-sessions") trace_id)
      ~session_id:trace_id with
    | Ok stored -> check bool "the original checkpoint stays intact" true
        (stored.messages = history)
    | Error error -> fail (Keeper_checkpoint_store.checkpoint_load_error_to_string error))
;;

let assert_production_keeper_result result =
  check string
    "production Keeper response"
    "MASC_SUBSCRIPTION_OK"
    result.Keeper_agent_run.response_text;
  check int "production Keeper turn count" 1 result.turn_count;
  check (option int) "production after-turn ordinal" (Some 1) result.final_agent_core_turn_ordinal;
  check bool "production measured observation" true
    (Option.is_some result.runtime_observation);
  check bool "official client does not fabricate AGENT_CORE checkpoint" true
    (Option.is_none result.checkpoint)
;;

(* The same turn in the turn log, written beside the boundary line: the log's
   start, the turn's admission, and an end that says how the turn ended. *)
let turn_log_lines ~keepers_dir =
  let path =
    Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id:"codex-production-fixture"
  in
  String.split_on_char '\n' (Fs_compat.load_file path)
  |> List.filter (fun row -> not (String.equal row ""))
  |> List.map (fun row ->
    match Keeper_turn_log_codec.of_json (Yojson.Safe.from_string row) with
    | Ok line -> line
    | Error error -> fail (Keeper_memory_os_types.wire_error_to_string error))
;;

(* The units the turns of a log ended, in the order they were written: the
   turn, the mark its unit starts at and the mark it ends at. A unit starts
   where the unit before it ended, or where the log started
   ({!Keeper_turn_log.boundary}). *)
let turn_units lines =
  let (_ : Keeper_turn_log.mark option), (_ : Ids.Turn_ref.t option), units =
    List.fold_left
      (fun (point, opened, units) (line : Keeper_turn_log.line) ->
         match Keeper_turn_log.boundary line, line with
         | Starts_at mark, (Log_started _ | Opened _ | Closed _ | Reset _) ->
           Some mark, opened, units
         | Moves_nothing, Opened { turn_ref; _ } -> point, Some turn_ref, units
         | Moves_nothing, (Log_started _ | Closed _ | Reset _) -> point, opened, units
         | Ends_unit { through; next }, Closed _ ->
           (match point, opened with
            | Some from, Some turn_ref -> Some next, None, (turn_ref, from, through) :: units
            | None, (Some _ | None) | Some _, None ->
              fail "a turn's end with no start of the log or no admission before it")
         | Ends_unit { next; through = (_ : Keeper_turn_log.mark) }, (Log_started _ | Opened _ | Reset _)
           -> Some next, opened, units)
      (None, None, [])
      lines
  in
  List.rev units
;;

(* The byte offset at which each whole line of [raw] starts, by its number
   from 1. *)
let line_starts raw =
  let rec go number offset starts =
    match String.index_from_opt raw offset '\n' with
    | None -> List.rev starts
    | Some stop -> go (number + 1) (stop + 1) ((number, offset) :: starts)
  in
  go 1 0 []
;;

(* One official-client file against the units of the turn log. The bytes of a
   unit hold the lines that name its turn, every one of them and no other
   line, and the last unit ends where the file ends. Returns how many lines
   each unit holds. *)
let official_client_lines_in_units ~session_dir file ~bytes units =
  let path = Keeper_turn_fragments.path ~session_dir file in
  let raw = if Sys.file_exists path then Fs_compat.load_file path else "" in
  let starts = line_starts raw in
  let lines =
    match Keeper_turn_fragments.read ~session_dir file with
    | Ok lines -> lines
    | Error detail -> fail detail
  in
  (match List.rev units with
   | (_, _, last) :: _ ->
     check int "the last unit ends where the file ends" (String.length raw) (bytes last)
   | [] -> fail "the turn log ends no unit");
  List.map
    (fun (turn_ref, from, through) ->
       let named = Ids.Turn_ref.to_string turn_ref in
       let in_unit =
         List.filter
           (fun (number, (_ : (Keeper_turn_fragments.line, Keeper_turn_fragments.read_error) result)) ->
              let start = List.assoc number starts in
              start >= bytes from && start < bytes through)
           lines
       in
       List.iter
         (fun (number, line) ->
            match line with
            | Ok (Keeper_turn_fragments.Fragment fragment) ->
              check string
                (Printf.sprintf "line %d lies in the unit of the turn it names" number)
                named
                (Ids.Turn_ref.to_string (Keeper_turn_fragments.fragment_turn_ref fragment))
            | Ok Keeper_turn_fragments.Untagged ->
              fail (Printf.sprintf "line %d of the unit of %s names no turn" number named)
            | Error error -> fail (Keeper_turn_fragments.read_error_to_string error))
         in_unit;
       check int
         (Printf.sprintf "the unit of %s holds every line that names it" named)
         (List.length (Keeper_turn_fragments.of_turn turn_ref lines))
         (List.length in_unit);
       List.length in_unit)
    units
;;

(* Both official-client files of [trace_id] against the turn log: for each
   unit, the lines it holds in the main file and in the internal one. *)
let official_client_units ~base_path ~trace_id =
  let keepers_dir =
    Filename.concat (Workspace.backend_config_for base_path).base_path
      Common.keepers_runtime_dirname
  in
  let session_dir = Filename.concat (production_fixture_session_base ~base_path) trace_id in
  let units = turn_units (turn_log_lines ~keepers_dir) in
  let main =
    official_client_lines_in_units ~session_dir Keeper_turn_fragments.Main
      ~bytes:(fun (mark : Keeper_turn_log.mark) -> mark.history_bytes)
      units
  in
  let internal =
    official_client_lines_in_units ~session_dir Keeper_turn_fragments.Internal
      ~bytes:(fun (mark : Keeper_turn_log.mark) -> mark.internal_bytes)
      units
  in
  List.map2
    (fun (turn_ref, (_ : Keeper_turn_log.mark), (_ : Keeper_turn_log.mark)) lines ->
       Ids.Turn_ref.to_string turn_ref, lines)
    units
    (List.combine main internal)
;;

let assert_turn_log ~keepers_dir ~trace_id ~ended =
  match turn_log_lines ~keepers_dir with
  | [ Keeper_turn_log.Log_started _; Opened { turn_ref; stimuli; _ }; Closed { outcome; _ } ] ->
    check string "turn log turn" (trace_id ^ "#1") (Ids.Turn_ref.to_string turn_ref);
    check bool "the admission names what the turn was woken by" true
      (stimuli
       = [ Keeper_turn_log.Workspace_message
             { request = "fixture-request"; from = "fixture-sender" }
         ]);
    check bool "the turn's end says how it ended" true (outcome = ended)
  | lines ->
    fail
      (Printf.sprintf
         "expected the log's start, an admission and an end, read %d lines"
         (List.length lines))
;;

(* A turn of a new workspace starts from a history with no atom, and says so
   before it runs: that is the first line, and it is there whether or not the
   turn reaches its end. An official-client turn saves no AGENT_CORE checkpoint,
   so the line it leaves at its end names the turn, repeats that the history
   was fresh, and states that there is no atom history. *)
let assert_official_client_turn_boundary ~base_path ~trace_id ~ended =
  let keepers_dir =
    Filename.concat (Workspace.backend_config_for base_path).base_path
      Common.keepers_runtime_dirname
  in
  match
    Keeper_turn_boundaries.read ~keepers_dir ~keeper_id:"codex-production-fixture"
  with
  | Error detail -> fail ("turn boundary store: " ^ detail)
  | Ok
      [ ( 1
        , Ok
            { Keeper_turn_boundaries.recorded_at = _
            ; event = Keeper_turn_boundaries.History_restarted { trace_id = empty_trace }
            } )
      ; ( 2
        , Ok
            { Keeper_turn_boundaries.recorded_at = _
            ; event =
                Keeper_turn_boundaries.Turn_ended { turn_ref; history_at_start; position }
            } )
      ] ->
    check string "the turn said at its start that its history held no atom" trace_id
      empty_trace;
    check string "turn boundary turn" (trace_id ^ "#1") (Ids.Turn_ref.to_string turn_ref);
    check bool "the first turn of a new workspace began from a fresh history" true
      (history_at_start = Keeper_turn_boundaries.Fresh_history);
    check bool "an official client turn has no atom history" true
      (position = Keeper_turn_boundaries.No_atom_history);
    assert_turn_log ~keepers_dir ~trace_id ~ended
  | Ok lines ->
    fail
      (Printf.sprintf
         "expected a restart line and a turn line, read: %s"
         (String.concat
            "; "
            (List.map
               (fun (line, read) ->
                  match read with
                  | Ok written ->
                    Printf.sprintf
                      "%d %s"
                      line
                      (Yojson.Safe.to_string
                         (Keeper_turn_boundaries.record_to_json written))
                  | Error error ->
                    Printf.sprintf
                      "%d unreadable: %s"
                      line
                      (Keeper_turn_boundaries.read_error_to_string error))
               lines)))
;;

let test_production_keeper_dispatches_codex_runtime () =
  let base_path = temp_workspace "masc-codex-production-" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            match
              run_production_keeper_turn
                ~base_path
                ~trace_id:"codex-production-trace-1"
                ~user_message:
                  "Reply with exactly MASC_SUBSCRIPTION_OK and do not use tools."
                ~cli_path
                ~model:"gpt-fixture"
                ~turn_instructions:None
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok result ->
              assert_production_keeper_result result;
              assert_official_client_turn_boundary
                ~base_path
                ~trace_id:"codex-production-trace-1"
                ~ended:Keeper_turn_log.Completed;
              check
                (list (pair string (pair int int)))
                "the turn's unit holds its input and its answer, both in the main file"
                [ "codex-production-trace-1#1", (2, 0) ]
                (official_client_units ~base_path ~trace_id:"codex-production-trace-1")))
;;

(* An official-client turn that fails never reaches finalize. Its input is
   already a fragment of its turn, so it still leaves the line that names the
   turn; without it no Librarian round would read that input. *)
let test_production_keeper_failed_turn_leaves_its_end_line () =
  let base_path = temp_workspace "masc-codex-production-failed-" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ init_result; account_chatgpt; thread_result; turn_result; turn_failed ]
         (fun cli_path ->
            match
              run_production_keeper_turn
                ~base_path
                ~trace_id:"codex-production-failed-1"
                ~user_message:"This turn fails at the provider."
                ~cli_path
                ~model:"gpt-fixture"
                ~turn_instructions:None
            with
            | Ok _ -> fail "the fixture turn was expected to fail"
            | Error _ ->
              assert_official_client_turn_boundary
                ~base_path
                ~trace_id:"codex-production-failed-1"
                ~ended:Keeper_turn_log.Errored;
              check
                (list (pair string (pair int int)))
                "the failed turn's unit holds its input"
                [ "codex-production-failed-1#1", (1, 0) ]
                (official_client_units ~base_path ~trace_id:"codex-production-failed-1")))
;;

let () =
  run "runtime_codex_app_server_turn_boundaries"
    [ ( "last projection"
      , [ test_case "empty overflow retry survives the next production turn" `Quick
            test_production_empty_retry_boundary_survives_the_next_turn
        ] )
    ; ( "subscription boundary"
      , [ test_case
            "production Keeper dispatches Codex runtime"
            `Quick
            test_production_keeper_dispatches_codex_runtime
        ; test_case
            "production Keeper failed turn leaves its end line"
            `Quick
            test_production_keeper_failed_turn_leaves_its_end_line
        ] )
    ]
;;

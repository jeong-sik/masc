let frozen_librarian_position point : Masc.Keeper_turn_driver_try_provider.librarian_position =
  let snapshot=match point with
    | Masc.Keeper_turn_driver_try_provider.Librarian_snapshot snapshot -> snapshot.unread_messages
    | Masc.Keeper_turn_driver_try_provider.Librarian_progress _ | Masc.Keeper_turn_driver_try_provider.No_position -> [] in
  {point;unread=Masc.Keeper_librarian_request_unread.of_results ~snapshot:(Ok snapshot) ~memory:(Ok [])}
;;

open Alcotest
open Masc

let unavailable_native_unread = Keeper_librarian_request_unread.of_results
    ~snapshot:(Error "fixture has no snapshot reader")
    ~memory:(Error "fixture has no Memory reader")
;;

(* Native clients retain an explicit frozen observation even when it is empty
   or unavailable. Check that pinned carrier before comparing durable history. *)
let attach_native_unread
    ?(unread = unavailable_native_unread) messages =
  Keeper_librarian_request_unread.attach ~include_empty:true ~role:Agent_core.Types.System
    unread messages
;;

let without_native_unread
    ?(unread = unavailable_native_unread) messages =
  let carriers = List.filter Runtime_model_input_tail_window.is_unread_context messages in
  let encode = List.map Keeper_official_client_host.encode_history_message in
  check (list string) "native request carries exactly its frozen unread observation"
    (encode (attach_native_unread ~unread [])) (encode carriers);
  check int "the unread observation adds no durable atom" 0
    (snd (Runtime_model_input_tail_window.annotate carriers));
  List.filter (fun message -> not (Runtime_model_input_tail_window.is_unread_context message)) messages
;;

let carried_digest = function
  | Model_input_front.At_atom digest -> digest
  | Model_input_front.After_history _ | Model_input_front.Empty_history ->
    Alcotest.fail "expected a nonempty carried window"
;;

let shell_quote value =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' value) ^ "'"
;;

let temp_workspace () =
  let path = Filename.temp_file "masc-keeper-antigravity-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let cleanup_tree root =
  try Fs_compat.remove_tree root with
  | _ -> ()
;;

let write_file ~mode path contents =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output contents);
  Unix.chmod path mode
;;

let account_owner ~base_path =
  Runtime_antigravity_home.keeper_owner_leaf ~keeper_name:"antigravity-fixture"
    ~oauth_source:(Filename.concat base_path "operator-oauth-token")
;;

let account_store ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "official-clients/antigravity"
  |> fun root -> Filename.concat root (account_owner ~base_path)
;;

let prepared_account_home ~base_path =
  match Runtime_antigravity_home.prepare
      ~runtime_root:(Common.masc_dir_from_base_path ~base_path)
      ~owner_leaf:(account_owner ~base_path)
      ~oauth_source:(Filename.concat base_path "operator-oauth-token") with
  | Ok home -> home
  | Error error -> fail (Runtime_antigravity_home.error_to_string error)
;;

let fixture_script_with_tools ~argument_reader ~base_path =
  let path = Filename.concat base_path "agy-fixture.sh" in
  let prompt_path = Filename.concat base_path "antigravity-prompt.txt" in
  let script =
    Printf.sprintf
      {|#!/bin/sh
set -eu
test "$(dirname "$HOME")" = %s
printf '%%s\n' "$HOME" > %s
test -f "$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
test -f "$HOME/.gemini/config/mcp_config.json"
python3 - <<'POLICY'
import json, os
with open(os.path.join(os.environ["HOME"], ".gemini/antigravity-cli/settings.json")) as f:
    permissions = json.load(f)["permissions"]
cwd = os.getcwd()
assert permissions["allow"] == ["mcp(masc/*)", "read_file(" + cwd + ")"]
assert "write_file(*)" in permissions["deny"]
assert "command(*)" in permissions["deny"]
assert "unsandboxed(*)" not in permissions["deny"]
POLICY
conversation=conversation-antigravity-fixture
turns=1
resuming=0
turn_counter="$HOME/fixture-vendor-turn-count"
mode=
sandbox=0
slash_commands_disabled=0
new_project=0
expect_mode=0
for arg in "$@"; do
  if [ "$expect_mode" -eq 1 ]; then
    mode="$arg"
    expect_mode=0
    continue
  fi
  case "$arg" in
    --mode) expect_mode=1 ;;
    --sandbox) sandbox=1 ;;
    --disable-slash-commands) slash_commands_disabled=1 ;;
    --new-project) new_project=1 ;;
    --conversation) expect_conversation=1 ;;
    conversation-antigravity-fixture) resuming=1 ;;
  esac
done
test "$expect_mode" -eq 0
test "$mode" = plan
test "$sandbox" -eq 1
test "$slash_commands_disabled" -eq 1
if [ "$resuming" -eq 1 ]; then
  previous_turns=$(cat "$turn_counter")
  if [ "$previous_turns" -eq 1 ]; then turns=73; else turns=$((previous_turns + 1)); fi
fi
if [ "$turns" -eq 1 ]; then test "$new_project" -eq 1; else test "$new_project" -eq 0; fi
cat > %s
printf '{"event":"init","conversation_id":"%%s","init":{"model":"gemini-fixture","cwd":%s,"tools":["call_mcp_tool"],"permission_mode":"always-proceed"}}\n' "$conversation"
python3 - <<'PY'
import json
import os
import urllib.request

with open(os.path.join(os.environ["HOME"], ".gemini", "config", "mcp_config.json"), encoding="utf-8") as handle:
    server = json.load(handle)["mcpServers"]["masc"]

headers = dict(server["headers"])
headers["Content-Type"] = "application/json"
headers["Accept"] = "application/json, text/event-stream"

def post(message, protocol=None):
    current = dict(headers)
    if protocol is not None:
        current["MCP-Protocol-Version"] = protocol
    request = urllib.request.Request(
        server["url"],
        data=json.dumps(message).encode(),
        headers=current,
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read()
        return None if not body else json.loads(body)

version = "2025-11-25"
post({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":version,"capabilities":{},"clientInfo":{"name":"agy-fixture","version":"1"}}})
post({"jsonrpc":"2.0","method":"notifications/initialized","params":{}}, version)
tools = post({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}, version)
assert sorted(tool["name"] for tool in tools["result"]["tools"]) == %s
# Every tool masc serves is declared eager and nothing else is, or the model sees its name only.
assert sorted(server["tools"]) == sorted(tool["name"] for tool in tools["result"]["tools"]), server.get("tools")
assert all(v == {"eager": True} for v in server["tools"].values()), server["tools"]
called = post({"jsonrpc":"2.0","id":"call-1","method":"tools/call","params":{"name":"masc_probe","arguments":{"marker":"from-antigravity"}}}, version)
assert called["result"]["content"][0]["text"] == "MASC_TOOL_RESULT"
PY
printf '{"event":"step_update","step_update":{"conversation_id":"%%s","step_index":0,"state":"DONE","step_type":"system_message"}}\n' "$conversation"
printf '{"event":"step_update","step_update":{"conversation_id":"%%s","step_index":1,"state":"ACTIVE","step_type":"tool","tool_name":"call_mcp_tool"}}\n' "$conversation"
printf '{"event":"step_update","step_update":{"conversation_id":"%%s","step_index":1,"state":"DONE","step_type":"tool","tool_name":"call_mcp_tool"}}\n' "$conversation"
printf '%%s\n' "$turns" > "$turn_counter"
printf '{"event":"result","result":{"conversation_id":"%%s","status":"SUCCESS","response":"MASC_ANTIGRAVITY_KEEPER_OK","error":null,"num_turns":%%d,"usage":{"input_tokens":12,"output_tokens":4,"thinking_tokens":1,"cache_read_tokens":40,"total_tokens":16}}}\n' "$conversation" "$turns"
|}
      (shell_quote
         (account_store ~base_path))
      (shell_quote (Filename.concat base_path "antigravity-selected-home"))
      (shell_quote prompt_path)
      (Yojson.Safe.to_string (`String (Env_config_core.strip_trailing_slashes
         (Filename.concat base_path
           (Keeper_sandbox.host_root_rel_of_profile Keeper_types_profile_sandbox.Docker
             "antigravity-fixture")))))
      (Yojson.Safe.to_string (`List (List.map (fun name -> `String name)
         (if argument_reader then ["keeper_artifact_read";"masc_probe"] else ["masc_probe"]))))
  in
  write_file ~mode:0o700 path script;
  path
;;

let fixture_script ~base_path = fixture_script_with_tools ~argument_reader:false ~base_path
;;

let blank_then_success_fixture_script ~base_path =
  let path = Filename.concat base_path "agy-blank-then-success.sh" in
  let invocation_path = Filename.concat base_path "antigravity-invocation" in
  let script =
    Printf.sprintf
      {|#!/bin/sh
set -eu
test "$(dirname "$HOME")" = %s
case " $* " in *" --new-project "*) ;; *) exit 96 ;; esac
case " $* " in *" --conversation "*) exit 97 ;; esac
cat >/dev/null
if [ -e %s ]; then
  conversation=conversation-recovered
  response=MASC_ANTIGRAVITY_RECOVERED
else
  : > %s
  conversation=conversation-blank
  response='   '
fi
printf '{"event":"init","conversation_id":"%%s","init":{"model":"gemini-fixture","cwd":%s,"tools":[],"permission_mode":"always-proceed"}}\n' "$conversation"
printf '{"event":"result","result":{"conversation_id":"%%s","status":"SUCCESS","response":"%%s","error":null,"num_turns":1,"usage":{"input_tokens":12,"output_tokens":4,"thinking_tokens":1,"cache_read_tokens":40,"total_tokens":16}}}\n' "$conversation" "$response"
|}
      (shell_quote
         (account_store ~base_path))
      (shell_quote invocation_path)
      (shell_quote invocation_path)
      (Yojson.Safe.to_string (`String (Env_config_core.strip_trailing_slashes
         (Filename.concat base_path
           (Keeper_sandbox.host_root_rel_of_profile Keeper_types_profile_sandbox.Docker
             "antigravity-fixture")))))
  in
  write_file ~mode:0o700 path script;
  path
;;

let runtime_toml ~cli_path ~oauth_source =
  Printf.sprintf
    {|[providers.antigravity]
protocol = "antigravity-cli"
command = %S
is-non-interactive = true
timeout-s = 30.0

[providers.antigravity.credentials]
type = "file"
path = %S

[models.gemini]
api-name = "gemini-fixture"
max-context = 524288

[antigravity.gemini]

[runtime]
default = "antigravity.gemini"
|}
    cli_path
    oauth_source
;;

let keeper_response_text (result : Runtime_agent.run_result) =
  result.response.content
  |> List.filter_map (function Llm_provider.Types.Text text -> Some text | _ -> None)
  |> String.concat ""
;;

let seed_ambiguous_resumed_session ~base_path ~tool =
  let module Store = Keeper_official_client_session_store in
  let owner_epoch = "11111111-1111-4111-8111-111111111111" in
  let runtime_id = "antigravity.gemini" in
  let tool_surface_sha256 =
    Store.tool_surface_sha256
      ~account_home:(Runtime_antigravity_home.home_dir (prepared_account_home ~base_path))
      ~native_posture:Runtime_native_tools.antigravity_default
      [ tool ]
  in
  let claimed =
    Store.claim
      ~base_path
      ~keeper_name:"antigravity-fixture"
      ~expected:None
      ~client_kind:Antigravity
      ~owner_epoch
      ~runtime_id
      ~tool_surface_sha256
      ~updated_at:1.0
    |> Result.get_ok
  in
  let active =
    Store.mark_active
      ~base_path
      ~keeper_name:"antigravity-fixture"
      ~expected:claimed
      ~session_id:"conversation-stale"
      ~updated_at:2.0
    |> Result.get_ok
  in
  let starting =
    Store.mark_turn_starting
      ~base_path
      ~keeper_name:"antigravity-fixture"
      ~expected:active
      ~session_id:"conversation-stale"
      ~updated_at:3.0
    |> Result.get_ok
  in
  let inflight =
    Store.mark_turn_started
      ~base_path
      ~keeper_name:"antigravity-fixture"
      ~expected:starting
      ~session_id:"conversation-stale"
      ~turn_id:"conversation-stale:ordinal:1"
      ~turn_count:1
      ~updated_at:4.0
    |> Result.get_ok
  in
  let settled =
    Store.settle
      ~base_path
      ~keeper_name:"antigravity-fixture"
      ~expected:inflight
      ~session_id:"conversation-stale"
      ~turn_id:"conversation-stale:ordinal:1"
      ~updated_at:5.0
    |> Result.get_ok
  in
  let resumed =
    Store.claim
      ~base_path
      ~keeper_name:"antigravity-fixture"
      ~expected:(Some settled)
      ~client_kind:Antigravity
      ~owner_epoch
      ~runtime_id
      ~tool_surface_sha256
      ~updated_at:6.0
    |> Result.get_ok
  in
  Store.require_recovery
    ~base_path
    ~keeper_name:"antigravity-fixture"
    ~expected:resumed
    ~failure:Protocol_failed
    ~detail:"provider conversation advanced without a local settlement"
    ~required_at:7.0
  |> Result.get_ok
  |> ignore
;;

let test_keeper_projects_mcp_tool_and_settles () =
  let base_path = temp_workspace () |> Unix.realpath in
  let workspace_key = Prompt_names.keeper_antigravity_workspace_shared in
  let workspace_template = "MANAGED_SHARED_WORKSPACE {{host_workspace}} / {{keeper_workspace}}" in
  let directory_label_key = Prompt_names.keeper_antigravity_additional_directories_label in
  let install_workspace_guidance () =
    List.iter (fun (key, text) -> match Prompt_registry.set_override key text with
      | Ok () -> () | Error detail -> fail detail)
      [workspace_key, workspace_template; directory_label_key, "MANAGED_EXTRA_DIRS"] in
  install_workspace_guidance ();
  Fun.protect
    ~finally:(fun () ->
      List.iter Prompt_registry.clear_prompt_override [workspace_key; directory_label_key];
      cleanup_tree base_path)
    (fun () ->
      let mascot_root = Filename.concat base_path ".masc" in
      Unix.mkdir mascot_root 0o700;
      (* #36066: the runtime resolves the keeper's native posture from its
         declaration before any turn, so the fixture keeper is declared. *)
      Masc_test_deps.declare_fixture_keeper
        ~base_path ~sandbox_profile:(Some Keeper_types_profile_sandbox.Docker) "antigravity-fixture";
      let oauth_source = Filename.concat base_path "operator-oauth-token" in
      write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "operator-oauth-fixture");
      let raw_trace_path = Filename.concat base_path "antigravity-raw-trace.jsonl" in
      let raw_trace =
        Agent_core.Raw_trace.create ~path:raw_trace_path ()
        |> Result.map_error (fun error -> fail (Agent_core.Error.to_string error))
        |> Result.get_ok
      in
      let observed_trace_ref = ref None in
      let transmitted_inputs = ref [] in
      let response_observed_model_inputs = ref [] in
      let input_window_observations = ref [] in
      let record_transmitted ~runtime_id:_ ~tools:_ ~transmitted =
        transmitted_inputs := transmitted :: !transmitted_inputs
      in
      let observed_initial_prompt = ref None in
      let observed_resumed_prompt = ref None in
      let stream_events = ref [] in
      let native_actions = ref [] in
      let cli_path = fixture_script ~base_path in
      let runtime_path = Filename.concat base_path "runtime.toml" in
      write_file ~mode:0o600 runtime_path (runtime_toml ~cli_path ~oauth_source);
      let observed = ref `Null in
      let marker_param : Agent_core.Types.tool_param =
        { name = "marker"
        ; description = "Fixture marker"
        ; param_type = String
        ; required = true
        }
      in
      let tool =
        Agent_core.Tool.create
          ~name:"masc_probe"
          ~description:"Return a deterministic fixture marker"
          ~parameters:[ marker_param ]
          (fun input ->
            observed := input;
            Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; content_blocks = None; _meta = None })
      in
      let dynamic_context = "ANTIGRAVITY_DYNAMIC_SYSTEM\nsecond line" in
      let hooks =
        { Agent_core.Hooks.empty with
          before_turn_params =
            Some
              (fun event ->
                 match event with
                 | Agent_core.Hooks.BeforeTurnParams { current_params; _ } ->
                   Agent_core.Hooks.AdjustParams
                     { current_params with
                       extra_system_context = Some dynamic_context
                     }
                 | _ -> Agent_core.Hooks.Continue)
        }
      in
      seed_ambiguous_resumed_session ~base_path ~tool;
      let tool_history : Agent_core.Types.message =
        { origin = Llm_provider.Types.Conversation;  role = Tool
        ; content =
            [ ToolResult
                { tool_use_id = "prior-call"
                ; content = "prior tool output"
                ; outcome = Tool_succeeded
                ; json = None
                ; content_blocks = None
                }
            ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      in
      let large_history =
        List.init 70 (fun index ->
          let marker = Printf.sprintf "history-%02d" index in
          { origin = Llm_provider.Types.Conversation;  Agent_core.Types.role = User
          ; content = [ Text (marker ^ ":" ^ String.make 4096 'x') ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          })
        @ [ tool_history ]
      in
      let runtime_snapshot = Runtime.For_testing.snapshot () in
      Fun.protect
        ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
        (fun () ->
          Eio_main.run (fun env ->
            Eio.Switch.run (fun sw ->
              Eio_context.set_env env;
              Eio_context.with_test_env
                ~net:(Eio.Stdenv.net env)
                ~clock:(Eio.Stdenv.clock env)
                ~mono_clock:(Eio.Stdenv.mono_clock env)
                ~sw
                (fun () ->
                  Runtime.init_default ~config_path:runtime_path
                  |> Result.map_error (fun error -> fail error)
                  |> Result.get_ok;
                  match
                    Keeper_turn_driver.run_named ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "fixture-trace-no-completed-turn" }) ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
                      ~runtime_id:"antigravity.gemini"
                      ~keeper_name:"antigravity-fixture"
                      ~base_path ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
                      (* A trace with no completed turn: the range is the whole
                         history, which the prompt checks below read. *)

                      ~goal:"Call masc_probe once"
                      ~system_prompt:"pre-dispatch fixture system prompt"
                      ~tools:[ tool ]
                      ~agent_core_tools:[ tool ]
                      ~initial_messages:large_history
                      ~on_request_attribution:record_transmitted
                      ~on_response_observed_model_input:(fun observed ->
                        response_observed_model_inputs :=
                          observed :: !response_observed_model_inputs)
                      ~on_model_input_window_observation:
                        (fun ~measurement:_ reading ->
                           input_window_observations :=
                             reading :: !input_window_observations)
                      ~hooks
                      ~context:(Agent_core.Context.create ())
                      ~raw_trace:(Some raw_trace)
                      ~on_event:(fun event -> stream_events := event :: !stream_events)
                      ~on_official_client_native_action:
                        (fun ~runtime_id ~official_turn ~identity ~tool_name ->
                           native_actions :=
                             (runtime_id, official_turn, identity, tool_name)
                             :: !native_actions)
                      ~sw
                      ~net:(Eio.Stdenv.net env)
                      ()
                  with
                  | Error error -> fail (Agent_core.Error.to_string error)
                  | Ok selected ->
                    let turn = selected.Keeper_turn_driver.run_result in
                    observed_trace_ref := turn.trace_ref;
                    check string
                      "response"
                      "MASC_ANTIGRAVITY_KEEPER_OK"
                      (keeper_response_text turn);
                    check int "turn count" 1 turn.turns;
                    (match turn.runtime_observation with
                     | Some observation ->
                       check bool
                         "Antigravity usage is conversation cumulative"
                         true
                         (observation.usage_scope
                          = Runtime_usage_scope.Conversation_cumulative)
                     | None -> fail "Antigravity runtime observation is missing");
                    (* The exact event order below is not hand-guessed: the MCP
                       tool_use block comes from the fixture's own HTTP call to
                       this process's MCP server (synchronous, inside the
                       python heredoc), while the native tool_use block comes
                       from parsing the CLI's step_update stdout lines -- two
                       different channels whose relative interleaving under Eio
                       is not a contract either channel promises. The WP1
                       completion trigger only asks for typed counts (native
                       tool count 1, MASC/MCP tool count 1, unknown-origin
                       count 0), not a byte-exact transcript, so that is what
                       is checked here instead of one brittle exhaustive
                       pattern match. *)
                    (match List.rev !stream_events with
                     | Agent_core.Types.MessageStart
                         { id = "conversation-antigravity-fixture:ordinal:1"
                         ; model = "gemini-fixture"
                         ; usage = None
                         }
                       :: rest ->
                       (match List.rev rest with
                        | Agent_core.Types.MessageStop
                          :: MessageDelta
                               { stop_reason = Some EndTurn; usage = None }
                          :: _ ->
                          let starts =
                            List.filter_map
                              (function
                                | Agent_core.Types.ContentBlockStart
                                    { content_type; _ } -> Some content_type
                                | _ -> None)
                              rest
                          in
                          let count_of value =
                            List.length (List.filter (String.equal value) starts)
                          in
                          let native_count =
                            count_of Runtime_native_tools.stream_content_type
                          in
                          let mcp_count = count_of "tool_use" in
                          check int "native tool count" 1 native_count;
                          check
                            bool
                            "MCP wrapper is not a second Skill action"
                            true
                            (List.is_empty !native_actions);
                          check int "MASC tool count" 1 mcp_count;
                          check
                            int
                            "unknown-origin tool count"
                            0
                            (List.length starts - native_count - mcp_count);
                          let arguments =
                            List.find_map
                              (function
                                | Agent_core.Types.ContentBlockDelta
                                    { delta =
                                        Agent_core.Types.InputJsonSnapshot
                                          arguments
                                    ; _
                                    } -> Some arguments
                                | _ -> None)
                              rest
                          in
                          (match arguments with
                           | Some arguments ->
                             check string
                               "streamed tool arguments"
                               {|{"marker":"from-antigravity"}|}
                               arguments
                           | None ->
                             fail "no tool_use input snapshot in Antigravity stream")
                        | _ ->
                          fail
                            "Antigravity stream did not end with EndTurn then MessageStop")
                     | _ ->
                       fail "Antigravity stream did not open with the expected MessageStart");
                    observed_initial_prompt :=
                      Some
                        (In_channel.with_open_bin
                           (Filename.concat base_path "antigravity-prompt.txt")
                           In_channel.input_all);
                    match
                      Keeper_turn_driver.run_named ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "antigravity-fixture" }) ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
                        ~runtime_id:"antigravity.gemini"
                        ~keeper_name:"antigravity-fixture"
                        ~base_path ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
                        ~goal:"Call masc_probe once"
                        ~system_prompt:"pre-dispatch fixture system prompt"
                        ~tools:[ tool ]
                        ~agent_core_tools:[ tool ]
                        ~initial_messages:large_history
                        ~on_request_attribution:record_transmitted
                        ~on_response_observed_model_input:(fun observed ->
                          response_observed_model_inputs :=
                            observed :: !response_observed_model_inputs)
                        ~on_model_input_window_observation:
                          (fun ~measurement:_ reading ->
                             input_window_observations :=
                               reading :: !input_window_observations)
                        ~hooks
                        ~context:(Agent_core.Context.create ())
                        ~raw_trace:(Some raw_trace)
                        ~sw
                        ~net:(Eio.Stdenv.net env)
                        ()
                    with
                    | Error error -> fail (Agent_core.Error.to_string error)
                    | Ok resumed ->
                      let resumed = resumed.Keeper_turn_driver.run_result in
                      observed_trace_ref := resumed.trace_ref;
                      observed_resumed_prompt :=
                        Some
                          (In_channel.with_open_bin
                             (Filename.concat base_path "antigravity-prompt.txt")
                             In_channel.input_all);
                      check int
                        "provider cumulative turn count"
                        73
                        resumed.turns;
                      (* A Gate continuation is bound to the vendor session
                         that opened it; a fresh session would run the effects
                         and then fail completion. A changed prompt keeps the
                         refusal there, before anything reaches the CLI. *)
                      let gate_checkpoint =
                        match Keeper_official_client_session_store.load ~base_path
                                ~keeper_name:"antigravity-fixture" with
                        | Ok (Some {phase=Settled {session_id; turn_id}; tool_surface_sha256; _}) ->
                          { Keeper_semantic_execution.client_kind = Antigravity
                          ; runtime_id = "antigravity.gemini"; session_id; turn_id
                          ; tool_surface_sha256; frame = Keeper_repetition_snapshot.empty }
                        | Ok _ | Error _ -> fail "resumed session did not settle" in
                      let prompt_before_gate = In_channel.with_open_bin
                        (Filename.concat base_path "antigravity-prompt.txt") In_channel.input_all in
                      (match Keeper_turn_driver.run_named ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "antigravity-fixture" }) ~raw_trace:None ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
                          ~runtime_id:"antigravity.gemini" ~keeper_name:"antigravity-fixture"
                          ~base_path ~media_store:(Tool_blob_media_store.of_base_path ~base_path) ~goal:"Resume the approved call"
                          ~official_client_continuation:gate_checkpoint
                          ~system_prompt:"changed core instructions" ~tools:[tool] ~agent_core_tools:[tool]
                          ~initial_messages:large_history ~hooks ~context:(Agent_core.Context.create ())
                          ~sw ~net:(Eio.Stdenv.net env) () with
                       | Error (Agent_core.Error.Config (InvalidConfig {field; _})) ->
                         check string "a Gate continuation keeps the context refusal"
                           "official_client_session.context_admission" field
                       | Error error -> fail (Agent_core.Error.to_string error)
                       | Ok _ -> fail "a Gate continuation ran in a fresh vendor session");
                      check string "the refused Gate continuation never reaches the CLI"
                        prompt_before_gate (In_channel.with_open_bin
                          (Filename.concat base_path "antigravity-prompt.txt") In_channel.input_all);
                      (* The fixture jumps to 73 on the first resume to prove
                         provider counts differ from the local ordinal, then
                         increments on later resumes. Fresh starts reset to 1.
                         The final control is a first resume, settled at 73. *)
                      let run_context_result ?official_client_composed_context ?(hooks = hooks) ~goal (system_prompt, initial_messages) =
                        Keeper_turn_driver.run_named ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "antigravity-fixture" }) ~raw_trace:None ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
                          ~runtime_id:"antigravity.gemini" ~keeper_name:"antigravity-fixture"
                          ~base_path ~media_store:(Tool_blob_media_store.of_base_path ~base_path) ~goal ?official_client_composed_context
                          ~system_prompt ~tools:[tool] ~agent_core_tools:[tool]
                          ~initial_messages ~hooks ~context:(Agent_core.Context.create ())
                          ~sw ~net:(Eio.Stdenv.net env) ()
                      in
                      let run_context ?official_client_composed_context ?hooks ~goal source =
                        match run_context_result ?official_client_composed_context ?hooks ~goal source with
                        | Error error -> fail (Agent_core.Error.to_string error)
                        | Ok run -> run.Keeper_turn_driver.run_result.turns
                      in
                      List.iter (fun changed ->
                        check int "changed context starts a fresh vendor session" 1
                          (run_context ~goal:"New goal must not run with stale context" changed))
                        ["changed core instructions", large_history;
                         "pre-dispatch fixture system prompt", large_history @ [Agent_core.Types.user_msg "new native correction"]];
                      let unchanged_context =
                        ("pre-dispatch fixture system prompt",
                         large_history @ [Agent_core.Types.user_msg "new native correction"]) in
                      let old_home = prepared_account_home ~base_path in
                      write_file ~mode:0o600 (Runtime_antigravity_home.oauth_path old_home)
                        (Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "operator-oauth-fixture");
                      check int "native refresh keeps the existing session" 73
                        (run_context ~goal:"Unchanged source, native-refreshed token" unchanged_context);
                      check string "native refresh is not overwritten" (Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "operator-oauth-fixture")
                        (Fs_compat.load_file (Runtime_antigravity_home.oauth_path old_home));
                      write_file ~mode:0o600 oauth_source
                        (Masc_test_deps.antigravity_oauth_fixture ~revision:"source-refresh" "operator-oauth-fixture");
                      check int "ordinary source OAuth refresh resumes the existing session" 74
                        (run_context ~goal:"Keep this account after OAuth refresh" unchanged_context);
                      check string "source refresh retains native credential rotation"
                        (Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "operator-oauth-fixture")
                        (Fs_compat.load_file (Runtime_antigravity_home.oauth_path old_home));
                      write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "external-relogin-account");
                      check int "same-path external login starts a fresh session" 1
                        (run_context ~goal:"Use externally re-logged account" unchanged_context);
                      let selected_home = String.trim (Fs_compat.load_file
                        (Filename.concat base_path "antigravity-selected-home")) in
                      check bool "actual spawned HOME is a new generation" true
                        (selected_home <> Runtime_antigravity_home.home_dir old_home);
                      check string "actual child used externally selected account" (Masc_test_deps.antigravity_oauth_fixture "external-relogin-account")
                        (Fs_compat.load_file (Filename.concat selected_home
                           ".gemini/antigravity-cli/antigravity-oauth-token"));
                      check string "old in-flight generation is preserved" (Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "operator-oauth-fixture")
                        (Fs_compat.load_file (Runtime_antigravity_home.oauth_path old_home));
                      let unchanged = ("pre-dispatch fixture system prompt",
                        large_history @ [Agent_core.Types.user_msg "new native correction"]) in
                      let hook_ordinals = ref [] in
                      let observe_hook name turn = hook_ordinals := (name, turn) :: !hook_ordinals in
                      let composed_hooks ?nudge ?(world = dynamic_context) instruction =
                        { Agent_core.Hooks.empty with
                          before_turn = Some (fun event ->
                            (match event with Agent_core.Hooks.BeforeTurn {turn; _} ->
                              observe_hook "before" turn | _ -> fail "unexpected before hook event");
                            match nudge with None -> Agent_core.Hooks.Continue
                            | Some text -> Agent_core.Hooks.Nudge text);
                          before_turn_params = Some (fun event ->
                            (match event with Agent_core.Hooks.BeforeTurnParams {turn; _} ->
                              observe_hook "params" turn | _ -> fail "unexpected params hook event");
                            Agent_core.Hooks.AdjustParams
                              { Agent_core.Hooks.default_turn_params with
                                system_prompt_override = Some instruction;
                                extra_system_context = Some world });
                          pre_tool_use = Some (fun event ->
                            (match event with Agent_core.Hooks.PreToolUse {invocation; _} ->
                              observe_hook "tool" (Agent_core.Tool_contract.Invocation.turn invocation)
                             | _ -> fail "unexpected tool hook event"); Agent_core.Hooks.Continue);
                          after_turn = Some (fun event ->
                            (match event with Agent_core.Hooks.AfterTurn {turn; _} ->
                              observe_hook "after" turn | _ -> fail "unexpected completion hook event");
                            Agent_core.Hooks.Continue) } in
                      let effective instruction ?nudge ?world ?hook_turn expected =
                        hook_ordinals := [];
                        let hooks = composed_hooks ?nudge ?world instruction in
                        check int "hook composition controls fresh versus resume" expected
                          (run_context ~hooks ~goal:"Call masc_probe once" unchanged);
                        let observations = List.rev !hook_ordinals in
                        check (list string) "hooks run once per attempt"
                          ["before"; "params"; "tool"; "after"] (List.map fst observations);
                        let ordinal = snd (List.hd observations) in
                        List.iter (fun (_, turn) -> check int "one host hook ordinal" ordinal turn) observations;
                        Option.iter (fun expected -> check int "host ordinal survives vendor reset" expected ordinal) hook_turn in
                      let supplied_hooks = composed_hooks "SUPPLIED_EFFECTIVE_INSTRUCTION" in
                      check int "a hook can supply the final system for a blank raw input" 1
                        (run_context ~hooks:supplied_hooks ~goal:"Call masc_probe once"
                          ("", snd unchanged));
                      let before_blank = In_channel.with_open_bin
                        (Filename.concat base_path "antigravity-prompt.txt") In_channel.input_all in
                      let blank_hooks = composed_hooks "   " in
                      (match Keeper_turn_driver.run_named ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "antigravity-fixture" }) ~raw_trace:None
                          ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
                          ~runtime_id:"antigravity.gemini" ~keeper_name:"antigravity-fixture"
                          ~base_path ~media_store:(Tool_blob_media_store.of_base_path ~base_path) ~goal:"A blank effective prompt must not run"
                          ~system_prompt:"nonblank raw system" ~tools:[tool] ~agent_core_tools:[tool]
                          ~initial_messages:(snd unchanged) ~hooks:blank_hooks
                          ~context:(Agent_core.Context.create ()) ~sw ~net:(Eio.Stdenv.net env) () with
                       | Error (Agent_core.Error.Config (InvalidConfig {field; _})) ->
                         check string "blank final system is refused by the shared host"
                           "system_prompt" field
                       | Error error -> fail (Agent_core.Error.to_string error)
                       | Ok _ -> fail "mandatory workspace note concealed a blank effective system");
                      check string "blank effective system never reaches the CLI" before_blank
                        (In_channel.with_open_bin
                          (Filename.concat base_path "antigravity-prompt.txt") In_channel.input_all);
                      effective "FIRST_EFFECTIVE_INSTRUCTION" 1;
                      let final_prompt = In_channel.with_open_bin
                        (Filename.concat base_path "antigravity-prompt.txt") In_channel.input_all in
                      check bool "hook override reaches the native client" true
                        (String_util.contains_substring final_prompt "FIRST_EFFECTIVE_INSTRUCTION");
                      check bool "managed workspace guidance survives hook override" true
                        (String_util.contains_substring final_prompt "MANAGED_SHARED_WORKSPACE");
                      let shared_path = Filename.concat base_path
                          (Keeper_sandbox.host_root_rel_of_profile
                             Keeper_types_profile_sandbox.Docker "antigravity-fixture") in
                      check bool "shared workspace guidance receives the typed host path" true
                        (String_util.contains_substring final_prompt shared_path);
                      check bool "shared workspace guidance receives the Keeper mount path" true
                        (String_util.contains_substring final_prompt
                           (Keeper_sandbox.container_root "antigravity-fixture"));
                      check bool "editable label retains the explicit additional-directory JSON" true
                        (String_util.contains_substring final_prompt "MANAGED_EXTRA_DIRS []");
                      let module Store = Keeper_official_client_session_store in
                      let session_before = match Store.load ~base_path ~keeper_name:"antigravity-fixture" with
                        | Ok (Some {phase=Store.Settled _; _}) as observed -> observed
                        | Ok _ -> fail "fixture has no settled native session"
                        | Error detail -> fail (Store.read_error_to_string detail) in
                      let empty_prompts = Filename.concat base_path "empty-prompts" in
                      Unix.mkdir empty_prompts 0o700;
                      let preparation_calls = ref 0 in
                      let missing_policy_hooks = {Agent_core.Hooks.empty with
                        before_turn_params=Some (fun _ -> incr preparation_calls; Agent_core.Hooks.Continue)} in
                      Prompt_registry.clear ();
                      Prompt_registry.set_markdown_dir empty_prompts;
                      Fun.protect ~finally:(fun () ->
                        Prompt_registry.clear ();
                        Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
                        install_workspace_guidance ()) (fun () ->
                        (match run_context_result ~hooks:missing_policy_hooks
                            ~goal:"Missing workspace guidance" unchanged with
                         | Error error ->
                           check bool "managed render returns a positive preparation failure" true
                             (Option.is_some (Keeper_internal_error.guidance_preparation_failure error));
                           (match Keeper_internal_error.without_guidance_preparation_authority error with
                            | Agent_core.Error.Config (InvalidConfig {field;_}) ->
                              check string "original configuration field is retained"
                                "antigravity.native_workspace_guidance" field
                            | cause -> fail (Agent_core.Error.to_string cause))
                         | Ok _ -> fail "missing workspace guidance launched a native turn");
                        check int "policy resolves before hooks and session claim" 0 !preparation_calls;
                        check bool "missing policy preserves the settled native session" true
                          (Store.load ~base_path ~keeper_name:"antigravity-fixture" = session_before);
                        check string "missing policy never launches the native CLI" final_prompt
                          (Fs_compat.load_file (Filename.concat base_path "antigravity-prompt.txt")));
                      effective "SECOND_EFFECTIVE_INSTRUCTION" 1;
                      effective "SECOND_EFFECTIVE_INSTRUCTION" 73;
                      effective "SECOND_EFFECTIVE_INSTRUCTION" ~nudge:"first correction" ~hook_turn:74 1;
                      effective "SECOND_EFFECTIVE_INSTRUCTION" ~nudge:"changed correction" 1;
                      effective "SECOND_EFFECTIVE_INSTRUCTION" ~nudge:"changed correction" 73;
                      effective "SECOND_EFFECTIVE_INSTRUCTION" 1;
                      effective "SECOND_EFFECTIVE_INSTRUCTION" ~world:"changed live world" 73;
                      List.iteri (fun index recall ->
                        let composed = ref None in
                        let clock = Printf.sprintf "ANTIGRAVITY_CLOCK_%d" index in
                        let blocks =
                          [ Prompt_block_id.Memory_os_recall, recall
                          ; Prompt_block_id.Temporal_summary, clock
                          ; Prompt_block_id.Operator_note, "REPEATED_OPERATOR_NOTE" ] in
                        let carrier = String.concat "\n\n" (List.map snd blocks) in
                        let hooks = { Agent_core.Hooks.empty with before_turn_params = Some (fun _ ->
                          composed := Some (Keeper_context_assembly.assemble ~dynamic_context_partition:None ~existing_extra_system_context:None ~blocks);
                          Agent_core.Hooks.AdjustParams { Agent_core.Hooks.default_turn_params with
                            extra_system_context = Some carrier }) } in
                        ignore (run_context ~hooks
                          ~official_client_composed_context:(fun () -> !composed)
                          ~goal:"Observe recall delivery" ("recall fixture system", snd unchanged));
                        let prompt = Fs_compat.load_file
                          (Filename.concat base_path "antigravity-prompt.txt") in
                        check bool "recall remains available without a compaction witness" true
                          (String_util.contains_substring prompt recall);
                        check bool "changing clock survives" true
                          (String_util.contains_substring prompt clock);
                        check bool "operator note deliberately repeats" true
                          (String_util.contains_substring prompt "REPEATED_OPERATOR_NOTE"))
                        ["RECALL_REVISION_ONE"; "RECALL_REVISION_ONE";
                         "RECALL_REVISION_TWO"; "RECALL_REVISION_TWO"];
                      check int "restoring the ordinary system starts fresh" 1
                        (run_context ~goal:"Call masc_probe once" unchanged);
                      check int "control: unchanged context resumes the fresh session" 73
                        (run_context ~goal:"Call masc_probe once"
                           ("pre-dispatch fixture system prompt",
                            large_history @ [Agent_core.Types.user_msg "new native correction"]))))));
      (match List.rev !transmitted_inputs with
       | [ Keeper_official_client_host.Whole_input_transmitted messages;
           Keeper_official_client_host.Held_by_client_session ] ->
         check bool "fresh transmission contains prepared history" true
           (List.length messages > 0)
       | _ -> fail "successful start/resume did not each report their exact input mode");
      check int "only the fresh transmission certifies its offered range" 1
        (List.length !response_observed_model_inputs);
      List.iter
        (fun (observed : Turn_record.response_observed_model_input) ->
           check string "the response names the official runtime"
             "antigravity.gemini"
             observed.runtime_profile;
           check bool "the official-client range has durable shape" true
             (observed.window.measurement = Turn_record.Durable_shape))
        !response_observed_model_inputs;
      check int
        "only the fresh input reports a history window"
        1
        (List.length !input_window_observations);
      check string
        "tool arguments"
        {|{"marker":"from-antigravity"}|}
        (Yojson.Safe.to_string !observed);
      let prompt =
        match !observed_initial_prompt with
        | Some prompt -> prompt
        | None -> fail "initial Antigravity prompt was not captured"
      in
      check bool
        "fresh prompt preserves oldest atom"
        true
        (String_util.contains_substring prompt "history-00");
      check bool
        "fresh prompt keeps newest atom"
        true
        (String_util.contains_substring prompt "history-69");
      check bool
        "prompt preserves prior tool role"
        true
        (String_util.contains_substring prompt {|"role":"tool"|});
      check bool
        "prompt preserves prior tool output"
        true
        (String_util.contains_substring prompt "prior tool output");
      check bool
        "fresh prompt carries dynamic System context"
        true
        (String_util.contains_substring
           prompt
           (Keeper_official_client_host.encode_history_message
              { origin = Llm_provider.Types.System_context;  Agent_core.Types.role = System
              ; content = [ Text dynamic_context ]
              ; name = None
              ; tool_call_id = None
              ; metadata = []
              }));
      let resumed_prompt =
        match !observed_resumed_prompt with
        | Some prompt -> prompt
        | None -> fail "resumed Antigravity prompt was not captured"
      in
      check bool
        "resume carries dynamic System context without a compaction witness"
        true
        (String_util.contains_substring
           resumed_prompt
           (Keeper_official_client_host.encode_history_message
              { origin = Llm_provider.Types.System_context;  Agent_core.Types.role = System
              ; content = [ Text dynamic_context ]
              ; name = None
              ; tool_call_id = None
              ; metadata = []
              }));
      check bool
        "resume keeps the goal"
        true
        (String.ends_with ~suffix:"Call masc_probe once" resumed_prompt);
      check bool
        "resume does not replay seeded history"
        false
        (String_util.contains_substring resumed_prompt "history-00");
      check bool
        "resume does not replay prior tool output"
        false
        (String_util.contains_substring resumed_prompt "prior tool output");
      let trace_ref =
        match !observed_trace_ref with
        | Some trace_ref -> trace_ref
        | None -> fail "Antigravity turn did not expose its RAW trace reference"
      in
      check string "RAW trace path" raw_trace_path trace_ref.path;
      let input = open_in_bin raw_trace_path in
      let raw =
        Fun.protect
          ~finally:(fun () -> close_in input)
          (fun () -> really_input_string input (in_channel_length input))
      in
      check bool
        "RAW trace contains tool input"
        true
        (String_util.contains_substring raw "from-antigravity");
      check bool
        "RAW trace contains tool output"
        true
        (String_util.contains_substring raw "MASC_TOOL_RESULT");
      let native_starts =
        Agent_core.Raw_trace.read_all ~path:raw_trace_path ()
        |> Result.map_error (fun error -> fail (Agent_core.Error.to_string error))
        |> Result.get_ok
        |> List.filter (fun (record : Agent_core.Raw_trace.record) ->
          record.record_type = Agent_core.Raw_trace.Native_tool_started)
      in
      check int "RAW trace keeps both provider wrapper steps" 2
        (List.length native_starts);
      check bool "RAW trace keeps exact provider step and typed wrapper origin" true
        (List.for_all
           (fun (record : Agent_core.Raw_trace.record) ->
              record.native_tool_identity
              = Some
                  (Agent_core.Raw_trace.Provider_step
                     { conversation_id = "conversation-antigravity-fixture"
                     ; step_index = 1
                     })
              && record.native_tool_origin = Some Agent_core.Raw_trace.Mcp_wrapper
              && record.tool_name = Some "call_mcp_tool")
           native_starts);
      let session =
        Keeper_official_client_session_store.load
          ~base_path
          ~keeper_name:"antigravity-fixture"
        |> Result.get_ok
        |> Option.get
      in
      (match session.phase with
       | Settled
           { session_id = "conversation-antigravity-fixture"
           ; turn_id = "conversation-antigravity-fixture:ordinal:73"
           } -> ()
       | _ -> fail "Antigravity Keeper turn did not settle");
      check int "durable provider turn count" 73 session.turn_count;
      let next_plan =
        Keeper_official_client_session_store.plan_claim
          ~expected:(Some session)
          ~client_kind:Keeper_official_client_session_store.Antigravity
          ~runtime_id:"antigravity.gemini"
        |> Result.get_ok
      in
      check int "next durable turn count" 74 next_plan.turn_count;
      let mcp_path =
        Filename.concat
          (Runtime_antigravity_home.home_dir (prepared_account_home ~base_path))
          ".gemini/config/mcp_config.json"
      in
      check bool "turn capability cleared" false (Sys.file_exists mcp_path))
;;

let test_blank_success_requires_fresh_conversation () =
  let base_path = temp_workspace () |> Unix.realpath in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
      Unix.mkdir (Filename.concat base_path ".masc") 0o700;
      Masc_test_deps.declare_fixture_keeper
        ~base_path ~sandbox_profile:(Some Keeper_types_profile_sandbox.Docker) "antigravity-fixture";
      let oauth_source = Filename.concat base_path "operator-oauth-token" in
      write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "operator-oauth-fixture");
      let cli_path = blank_then_success_fixture_script ~base_path in
      let runtime_path = Filename.concat base_path "runtime.toml" in
      write_file ~mode:0o600 runtime_path (runtime_toml ~cli_path ~oauth_source);
      let runtime_snapshot = Runtime.For_testing.snapshot () in
      Fun.protect
        ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
        (fun () ->
          Eio_main.run (fun env ->
            Eio.Switch.run (fun sw ->
              Eio_context.set_env env;
              Eio_context.with_test_env
                ~net:(Eio.Stdenv.net env)
                ~clock:(Eio.Stdenv.clock env)
                ~mono_clock:(Eio.Stdenv.mono_clock env)
                ~sw
                (fun () ->
                  Runtime.init_default ~config_path:runtime_path |> Result.get_ok;
                  let run () =
                    Keeper_turn_driver.run_named ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "antigravity-fixture" }) ~raw_trace:None ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
                      ~runtime_id:"antigravity.gemini"
                      ~keeper_name:"antigravity-fixture"
                      ~base_path ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
                      ~goal:"Return a non-empty completion"
                      ~system_prompt:"pre-dispatch fixture system prompt"
                      ~agent_core_tools:[]
                      ~context:(Agent_core.Context.create ())
                      ~sw
                      ~net:(Eio.Stdenv.net env)
                      ()
                  in
                  (match run () with
                   | Error error ->
                     (match Keeper_turn_driver.classify_masc_internal_error error with
                      | None ->
                        check bool
                          "blank success remains a provider failure before any tool effect"
                          true
                          (String_util.contains_substring
                             (Agent_core.Error.to_string error)
                             "successful result response has no deliverable content");
                        check bool
                          "diagnostic fields ride in the provider error"
                          true
                          (let rendered = Agent_core.Error.to_string error in
                           String_util.contains_substring rendered "model="
                           && String_util.contains_substring rendered "tool_steps=")
                      | Some other ->
                        fail
                          (Keeper_turn_driver.kind_of_masc_internal_error other)
                      )
                   | Ok _ -> fail "blank Antigravity result settled as success");
                  let failed_session =
                    Keeper_official_client_session_store.load
                      ~base_path
                      ~keeper_name:"antigravity-fixture"
                    |> Result.get_ok
                    |> Option.get
                  in
                  (match failed_session.phase with
                   | Recovery_required { failure = Provider_rejected; _ } -> ()
                   | _ -> fail "blank Antigravity result did not require a fresh session");
                  match run () with
                  | Error error -> fail (Agent_core.Error.to_string error)
                  | Ok selected ->
                    let result = selected.Keeper_turn_driver.run_result in
                    check string
                      "recovered response"
                      "MASC_ANTIGRAVITY_RECOVERED"
                      (keeper_response_text result);
                    check string
                      "fresh conversation"
                      "conversation-recovered"
                      result.session_id))));
      let session =
        Keeper_official_client_session_store.load
          ~base_path
          ~keeper_name:"antigravity-fixture"
        |> Result.get_ok
        |> Option.get
      in
      match session.phase with
      | Settled
          { session_id = "conversation-recovered"
          ; turn_id = "conversation-recovered:ordinal:1"
          } ->
        ()
      | _ -> fail "fresh Antigravity conversation did not settle")
;;

let test_spawn_failure_is_pre_dispatch () =
  let base_path = temp_workspace () |> Unix.realpath in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
      Unix.mkdir (Filename.concat base_path ".masc") 0o700;
      Masc_test_deps.declare_fixture_keeper
        ~base_path ~sandbox_profile:(Some Keeper_types_profile_sandbox.Docker) "antigravity-pre-dispatch";
      let oauth_source = Filename.concat base_path "operator-oauth-token" in
      write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "operator-oauth-fixture");
      let missing_cli = Filename.concat base_path "missing-antigravity" in
      let runtime_path = Filename.concat base_path "runtime.toml" in
      write_file
        ~mode:0o600
        runtime_path
        (runtime_toml ~cli_path:missing_cli ~oauth_source);
      let runtime_snapshot = Runtime.For_testing.snapshot () in
      Fun.protect
        ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
        (fun () ->
          Eio_main.run (fun env ->
            Eio.Switch.run (fun sw ->
              Eio_context.set_env env;
              Eio_context.with_test_env
                ~net:(Eio.Stdenv.net env)
                ~clock:(Eio.Stdenv.clock env)
                ~mono_clock:(Eio.Stdenv.mono_clock env)
                ~sw
                (fun () ->
                  Runtime.init_default ~config_path:runtime_path |> Result.get_ok;
                  let config =
                    match Runtime.get_runtime_by_id "antigravity.gemini" with
                    | Some
                        { Runtime_instance.execution =
                            Runtime_execution.Antigravity_cli config
                        ; _
                        } ->
                      config
                    | Some _ | None -> fail "Antigravity runtime fixture did not resolve"
                  in
                  let reports = ref [] in
                  let attempt =
                    Keeper_antigravity_runtime.run ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "antigravity-pre-dispatch" })
                    ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
                    ~accepts_image_input:(Runtime_agent.runtime_accepts_image_input
                      ~runtime:(Runtime.get_runtime_by_id "antigravity.gemini" |> Option.get))
                      ~pre_tool_rejects:(ref [])
                      ~runtime_id:"antigravity.gemini"
                      ~keeper_name:"antigravity-pre-dispatch"
                      ~base_path
                      ~goal:"spawn should fail"
                      ~goal_blocks:None
                      (* Non-empty on purpose. The keeper mainline refuses a
                         composed system prompt that comes out blank before
                         it spawns, so [""] would fail on config here instead
                         of reaching the spawn failure this case asserts. The
                         text is a don't-care; only its non-emptiness is
                         load-bearing. *)
                      ~system_prompt:"pre-dispatch fixture system prompt"
                      ~tools:[]
                      ~initial_messages:[]
                      ~model_input_projection:None
                      ~on_transmitted_model_input:
                        (fun report -> reports := report :: !reports)
                      ~hooks:None
                      ~context_injector:None
                      ~context:None
                      ~event_bus:None
                      ~raw_trace:None
                      ~on_event:None
                      ~config
                      ()
                  in
                  (match attempt.result with
                   | Error
                       (Agent_core.Error.Provider
                          (Llm_provider.Error.ProviderUnavailable _)) ->
                     ()
                   | Error error -> fail (Agent_core.Error.to_string error)
                   | Ok _ -> fail "missing Antigravity CLI unexpectedly ran");
                  check string
                    "spawn is proven pre-dispatch"
                    "no_effect_observed"
                    (Keeper_provider_attempt_effect.to_string
                       attempt.effect_disposition);
                  (* Preparation succeeded, but the CLI never spawned. A
                     prepared prompt is not evidence of transmitted input. *)
                  check int
                    "a turn that never spawned reports no transmitted input"
                    0
                    (List.length !reports))))))
;;

(* A blank composed system prompt must be refused before the CLI is spawned.
   [Keeper_official_client_host.framed_prompt_for_turn] renders the
   system-instructions section only when the prompt trims non-empty, so a
   blank one would open the conversation with the
   goal alone under the CLI's own harness prompt while masc's tool surface
   stayed projected. The refusal is checked on the typed [InvalidConfig] field
   rather than a substring of the detail, and against the working CLI fixture:
   the refusal has to land before spawn, so reaching the fixture here would
   mean the check ran too late. The transmitted-input reporter must stay
   silent too -- a refused turn transmits nothing (masc#32995). Same case as
   the Codex and Claude Code lanes (#33086). *)
let test_blank_system_prompt_is_refused_not_defaulted () =
  let base_path = temp_workspace () |> Unix.realpath in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
      Unix.mkdir (Filename.concat base_path ".masc") 0o700;
      Masc_test_deps.declare_fixture_keeper
        ~base_path ~sandbox_profile:(Some Keeper_types_profile_sandbox.Docker) "antigravity-blank-prompt";
      let oauth_source = Filename.concat base_path "operator-oauth-token" in
      write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "operator-oauth-fixture");
      let cli_path = fixture_script ~base_path in
      let runtime_path = Filename.concat base_path "runtime.toml" in
      write_file ~mode:0o600 runtime_path (runtime_toml ~cli_path ~oauth_source);
      let runtime_snapshot = Runtime.For_testing.snapshot () in
      Fun.protect
        ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
        (fun () ->
          Eio_main.run (fun env ->
            Eio.Switch.run (fun sw ->
              Eio_context.set_env env;
              Eio_context.with_test_env
                ~net:(Eio.Stdenv.net env)
                ~clock:(Eio.Stdenv.clock env)
                ~mono_clock:(Eio.Stdenv.mono_clock env)
                ~sw
                (fun () ->
                  Runtime.init_default ~config_path:runtime_path |> Result.get_ok;
                  let config =
                    match Runtime.get_runtime_by_id "antigravity.gemini" with
                    | Some
                        { Runtime_instance.execution =
                            Runtime_execution.Antigravity_cli config
                        ; _
                        } ->
                      config
                    | Some _ | None -> fail "Antigravity runtime fixture did not resolve"
                  in
                  let reports = ref [] in
                  let attempt =
                    Keeper_antigravity_runtime.run ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "antigravity-blank-prompt" })
                    ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
                    ~accepts_image_input:(Runtime_agent.runtime_accepts_image_input
                      ~runtime:(Runtime.get_runtime_by_id "antigravity.gemini" |> Option.get))
                      ~pre_tool_rejects:(ref [])
                      ~runtime_id:"antigravity.gemini"
                      ~keeper_name:"antigravity-blank-prompt"
                      ~base_path
                      ~goal:"the prompt is blank"
                      ~goal_blocks:None
                      ~system_prompt:"   "
                      ~tools:[]
                      ~initial_messages:[]
                      ~model_input_projection:None
                      ~on_transmitted_model_input:
                        (fun report -> reports := report :: !reports)
                      ~hooks:None
                      ~context_injector:None
                      ~context:None
                      ~event_bus:None
                      ~raw_trace:None
                      ~on_event:None
                      ~config
                      ()
                  in
                  (match attempt.result with
                   | Error
                       (Agent_core.Error.Config
                          (Agent_core.Error.InvalidConfig { field; _ })) ->
                     check string "refused field" "system_prompt" field
                   | Error error ->
                     fail
                       ("blank system prompt produced the wrong error: "
                        ^ Agent_core.Error.to_string error)
                   | Ok _ -> fail "blank system prompt ran under the client default");
                  check string
                    "the refusal is pre-dispatch"
                    "no_effect_observed"
                    (Keeper_provider_attempt_effect.to_string
                       attempt.effect_disposition);
                  check int
                    "a refused turn reports no transmitted input"
                    0
                    (List.length !reports))))))
;;

let plain_user_message text : Agent_core.Types.message =
  { origin = Llm_provider.Types.Conversation;  role = User
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let carried_projection ?on_model_input_window_observation ?carried_front_seed ?librarian_front
    ?on_carried_front ?(turn_start = Keeper_carried_front.Turn_boundary { end_atom = 0 })
    source =
  Keeper_official_client_host.carried_history_projection ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "alpha" })
    ?on_model_input_window_observation
    ?carried_front_seed
    ?librarian_front
    ?on_carried_front
    ~turn_start
    ~keeper_name:"alpha"
    ~runtime_id:"antigravity_subscription.gemini"
    source
;;

(* The Gate replay reference the source projection appends goes out after the
   carried range, and the reading counts only the durable history: the
   reference is no atom a later seed could reopen. *)
let test_appended_gate_reference_is_no_durable_atom () =
  let observed = ref None in
  let history =
    List.init 10 (fun index ->
      plain_user_message
        (Printf.sprintf "history-%02d:%s" index (String.make 1024 'x')))
  in
  let marker = plain_user_message "gate replay reference" in
  let source = Some (fun messages -> Ok (messages @ [ marker ])) in
  let seed_first_atom = 2 in
  let seed_front_digest =
    Runtime_model_input_tail_window.atom_opening_digest history seed_first_atom
    |> Option.get
  in
  let seed_read : Keeper_carried_front.seed_read =
    { seed =
        Some
          { first_atom = seed_first_atom
          ; front = Model_input_front.At_atom seed_front_digest
          ; source = Keeper_carried_front.Turn_record { turn = 40 }
          }
    ; unreadable = None
    ; boundary_error = None
    }
  in
  let project =
    carried_projection
      ~on_model_input_window_observation:(fun reading -> observed := Some reading)
      ~carried_front_seed:(fun () -> seed_read)
      source
  in
  match project history with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok projected ->
    (match List.rev projected with
     | last :: _ ->
       check bool "the appended Gate reference goes last" true
         (last.Agent_core.Types.content = marker.content)
     | [] -> fail "the projection removed the appended Gate reference");
    (match !observed with
     | None -> fail "the projection reported no durable-history window"
     | Some reading ->
       check int "the Gate reference is not a durable-history atom" 10
         reading.total_atoms;
       check int "the seeded range is carried whole" (10 - seed_first_atom)
         reading.transmitted_atoms;
       check int "the final list adds only the Gate atom to the durable suffix"
         (reading.transmitted_atoms + 1)
         (snd (Runtime_model_input_tail_window.annotate projected));
       let expected_front = reading.total_atoms - reading.transmitted_atoms in
       check (option string) "the front digest uses the original history coordinate"
         (Runtime_model_input_tail_window.atom_opening_digest history expected_front)
         (Some (carried_digest reading.model_input_front));
       let next_seed : Keeper_carried_front.seed =
         { first_atom = expected_front
         ; front = reading.model_input_front
         ; source = Keeper_carried_front.Turn_record { turn = 41 }
         }
       in
       (match
          Keeper_carried_front.for_history
            ~digest_at:(Runtime_model_input_tail_window.atom_opening_digest history)
            next_seed
        with
        | Ok admitted ->
          check int "the next seed reopens the same durable front" expected_front
            admitted.first_atom
        | Error _ -> fail "the projected observation did not seed the same history"))
;;

let carried_front_history () =
  List.init 60 (fun index -> plain_user_message (Printf.sprintf "history-%02d" index))
;;

let seed_read_at ~messages first_atom =
  let front_digest =
    match Runtime_model_input_tail_window.atom_opening_digest messages first_atom with
    | Some digest -> digest
    | None -> fail "the fixture front must name an atom in its history"
  in
  { Keeper_carried_front.seed =
      Some
        { Keeper_carried_front.first_atom
        ; front = Model_input_front.At_atom front_digest
        ; source = Keeper_carried_front.Turn_record { turn = 41 }
        }
  ; unreadable = None
  ; boundary_error = None
  }
;;

let encoded_history messages =
  List.map Keeper_official_client_host.encode_history_message messages
;;

let agent_core_range ?(turn_start = Keeper_carried_front.Turn_boundary { end_atom = 0 }) ~front messages =
  (Keeper_turn_driver_try_provider.For_testing.compose_carried_model_input
     ~measure_message_bytes:(Keeper_context_core.message_measurer ())
     ~accepted:None ~front
     ~history_digest_at:(Runtime_model_input_tail_window.atom_opening_digest messages)
     ~current_turn_results:Keeper_turn_driver_try_provider.Current_turn_verbatim
     ~base_path:""
     ~demote_before:0
     ~turn_boundary:turn_start
     messages)
    .Keeper_turn_driver_try_provider.projection
    .Runtime_model_input_tail_window.messages
;;

let project_range ?on_model_input_window_observation ?carried_front_seed ?librarian_front
    ?on_carried_front ?turn_start messages =
  let project =
    carried_projection
      ?on_model_input_window_observation
      ?carried_front_seed
      ?librarian_front
      ?on_carried_front
      ?turn_start
      None
  in
  match project messages with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok projected -> projected
;;

let test_seeded_start_matches_the_agent_core_range () =
  let observed = ref None in
  let messages = carried_front_history () in
  let seed_read = seed_read_at ~messages 53 in
  let projected =
    project_range
      ~on_model_input_window_observation:(fun reading -> observed := Some reading)
      ~carried_front_seed:(fun () -> seed_read)
      messages
  in
  check (list string) "the same durable range is carried"
    (encoded_history (agent_core_range ~front:seed_read.seed messages))
    (encoded_history (without_native_unread projected));
  match !observed with
  | None -> fail "the seeded projection reported no window"
  | Some reading ->
    check int "the reading keeps the full durable denominator" 60 reading.total_atoms;
    check int "the reading reports the seven seeded atoms" 7 reading.transmitted_atoms
;;

let test_cold_start_with_no_completed_turn_carries_everything () =
  let messages = carried_front_history () in
  let projected = project_range messages in
  check (list string) "without a seed and with no completed turn, everything is carried"
    (encoded_history messages)
    (encoded_history (without_native_unread projected))
;;

(* Without a seed on a history with completed turns, the range starts where
   the last of them ended: the same range the Agent Core path composes for
   that turn start (RFC keeper-context-window-in-tokens §13.4). *)
let test_cold_start_begins_at_the_turn_start () =
  let messages = carried_front_history () in
  let projected = project_range ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 53 }) messages in
  check (list string) "without a seed the range starts at the turn start"
    (encoded_history (agent_core_range ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 53 }) ~front:None messages))
    (encoded_history (without_native_unread projected));
  check int "seven atoms of sixty went" 7 (List.length (without_native_unread projected))
;;

(* The Librarian front reaches the list this lane renders -- a read position
   as the start -- and a list the turn's choice no longer describes refuses
   the request, as it refuses an Agent Core request. *)
let test_the_librarian_front_reaches_the_list_and_its_error_refuses () =
  let messages = carried_front_history () in
  let seen_front = ref None in
  let projected =
    project_range
      ~librarian_front:(fun _ ->
        Ok (frozen_librarian_position (Keeper_turn_driver_try_provider.Librarian_progress { end_atom = 53 })))
      ~on_carried_front:(fun front ~transmitted_bytes -> seen_front := Some (front, transmitted_bytes))
      messages
  in
  check (list string) "the range starts at the read position"
    (encoded_history (List.filteri (fun index _ -> index >= 53) messages))
    (encoded_history (without_native_unread ~unread:Keeper_librarian_request_unread.empty projected));
  (match !seen_front with
   | Some (Keeper_official_client_host.Librarian_progress { end_atom = 53 }, bytes) ->
     check bool "the front is reported with the range's bytes" true (bytes > 0)
   | Some _ -> fail "the reported front is not the read position"
   | None -> fail "the composition reported no front");
  let refused _ =
    Error
      (Agent_core.Error.Config
         (Agent_core.Error.InvalidConfig
            { field = "librarian.continuity"; detail = "Covered conversation changed during dispatch" }))
  in
  let project = carried_projection ~librarian_front:refused None in
  match project messages with
  | Error _ -> ()
  | Ok _ -> fail "a list the turn's choice no longer describes went out"
;;

let working_state_not_carried ~reason =
  Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string WorkingStateNotCarried)
    ~labels:
      [ "keeper", "alpha"; "runtime", "antigravity_subscription.gemini"; "reason", reason ]
    ()
;;

let snapshot_of ~messages ~end_atom ~working_state =
  let covered = List.filteri (fun index _ -> index < end_atom) messages in
  let position =
    match Keeper_turn_boundaries.position_of_messages covered with
    | Ok position -> position
    | Error detail -> fail detail
  in
  let line =
    ( 1
    , Ok
        { Keeper_turn_boundaries.recorded_at = 1.
        ; event =
            Keeper_turn_boundaries.Turn_ended
              { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:1
              ; history_at_start = Keeper_turn_boundaries.Fresh_history
              ; position
              }
        } )
  in
  match
    Librarian_continuity_snapshot.capture ~unread_messages:[] ~trace_id:"trace-1" ~lines:[ line ]
      ~messages:covered ~working_state
  with
  | Ok snapshot -> snapshot
  | Error error -> fail (Librarian_continuity_snapshot.error_to_string error)
;;

(* A Librarian snapshot sends its working state and the whole range it
   leads: the summary in front, then every atom from where the Librarian
   read. *)
let test_a_librarian_snapshot_leads_with_its_working_state () =
  let messages = carried_front_history () in
  let snapshot = snapshot_of ~messages ~end_atom:53 ~working_state:"Fifty asks answered so far." in
  let working_state = Keeper_turn_driver_try_provider.working_state_text snapshot in
  let before = working_state_not_carried ~reason:"displaces_atoms" in
  let seen_front = ref None in
  let projected =
    project_range
      ~librarian_front:(fun _ ->
        Ok (frozen_librarian_position (Keeper_turn_driver_try_provider.Librarian_snapshot snapshot)))
      ~on_carried_front:(fun front ~transmitted_bytes:_ -> seen_front := Some front)
      messages
  in
  (match without_native_unread ~unread:Keeper_librarian_request_unread.empty projected with
   | ({ role = System; content = [ Text text ]; _ } : Agent_core.Types.message) :: rest ->
     check string "the working state leads the list" working_state text;
     check (list string) "and every atom from the Librarian's position follows"
       (encoded_history (List.filteri (fun index _ -> index >= 53) messages))
       (encoded_history rest)
   | _ -> fail "the working state did not lead the list");
  (match !seen_front with
   | Some (Keeper_official_client_host.Librarian_snapshot _) -> ()
   | Some _ -> fail "the reported front is not the working state"
   | None -> fail "the composition reported no front");
  check (float 0.) "and nothing is counted as left out" before
    (working_state_not_carried ~reason:"displaces_atoms")
;;

(* A range that opens on an assistant turn is composed with the omission
   preamble in front, and the preamble is no durable atom. The reading must
   count only the history's atoms that went out, or its front names the atom
   after the one sent and the next request's seed starts one atom late. *)
let test_a_preamble_is_not_a_durable_atom () =
  let history =
    List.init 40 (fun index ->
      if index mod 2 = 0
      then plain_user_message (Printf.sprintf "turn-%02d" index)
      else
        ({ origin = Llm_provider.Types.Conversation;  role = Assistant
         ; content = [ Text (Printf.sprintf "reply-%02d" index) ]
         ; name = None
         ; tool_call_id = None
         ; metadata = []
         }
         : Agent_core.Types.message))
  in
  let observed = ref None in
  (* The range opens at 21, an assistant turn, so it goes with a preamble. *)
  let sent =
    project_range
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 21 })
      ~on_model_input_window_observation:(fun reading -> observed := Some reading)
      history
  in
  let sent = without_native_unread sent in
  check bool "the range opens on the preamble" true
    (match sent with
     | first :: _ -> Runtime_model_input_tail_window.is_synthetic_preamble first
     | [] -> false);
  let durable =
    List.filter
      (fun message -> not (Runtime_model_input_tail_window.is_synthetic_preamble message))
      sent
  in
  check (list string) "the atoms from 21 go"
    (encoded_history (List.filteri (fun index _ -> index >= 21) history))
    (encoded_history durable);
  match !observed with
  | None -> fail "the projection reported no window"
  | Some reading ->
    check int "the reading counts the atoms that went, not the preamble"
      (List.length durable) reading.transmitted_atoms;
    check (option string) "so its front is the first atom sent"
      (Runtime_model_input_tail_window.atom_opening_digest history 21)
      (Some (carried_digest reading.model_input_front))
;;

let test_a_front_from_another_history_is_dropped () =
  let messages = carried_front_history () in
  let other =
    List.init 60 (fun index -> plain_user_message (Printf.sprintf "other-%02d" index))
  in
  let seed_read = seed_read_at ~messages:other 53 in
  let projected =
    project_range
      ~carried_front_seed:(fun () -> seed_read)
      messages
  in
  check (list string) "a mismatched seed restarts from the whole history"
    (encoded_history messages)
    (encoded_history (without_native_unread projected))
;;

(* The projection keys an Antigravity usage report as the completion hook
   keys the turn: the CLI's own turn count, the identity built from it, the
   conversation-cumulative scope, and the inclusive input (100 exclusive +
   50 cache read). The Keeper's claim counter (turn_count) is not the key.
   The report names the conversation, whether this turn resumed it, and the
   CLI's own total. *)
let test_stream_usage_is_keyed_by_the_clis_turn () =
  let reports = ref [] in
  let report (report : Keeper_client_usage_report.t) =
    let usage =
      match report.count with
      | Keeper_client_usage_report.Running_count usage -> usage
      | Keeper_client_usage_report.Count_replaced ->
        Alcotest.fail "an Antigravity count was reported as replaced"
    in
    reports :=
      ( ( report.official_turn
        , report.response_id
        , report.model
        , Runtime_usage_scope.to_string report.usage_scope )
      , ( report.conversation_id
        , Keeper_usage_resolution.position_to_string report.position
        , report.vendor_total_tokens )
      , ( usage.input_tokens
        , usage.output_tokens
        , usage.cache_read_input_tokens ) )
      :: !reports
  in
  Keeper_antigravity_runtime.For_testing.report_stream_usage
    ~turn_count:2
    ~position:Keeper_usage_resolution.Resumed
    ~report
    (Runtime_antigravity.Usage_reported
       { conversation_id = "conversation-1"
       ; model = "gemini-fixture"
       ; num_turns = 73
       ; usage =
           { input_tokens = 100
           ; output_tokens = 7
           ; thinking_tokens = 3
           ; cache_read_tokens = 50
           ; total_tokens = 107
           }
       });
  match !reports with
  | [ ( (73, "conversation-1:ordinal:73", "gemini-fixture", "conversation_cumulative")
      , ("conversation-1", "resumed", Some 107)
      , (150, 7, 50) ) ]
    -> ()
  | reports ->
    failf "expected one report keyed by the CLI turn, got %d" (List.length reports)
;;

let test_losing_claim_cannot_publish_native_policy () =
  let base_path = temp_workspace () |> Unix.realpath in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect ~finally:(fun () -> Runtime.For_testing.restore snapshot; cleanup_tree base_path) (fun () ->
    let runtime_root = Common.masc_dir_from_base_path ~base_path in
    Unix.mkdir runtime_root 0o700;
    let keeper_name = "antigravity-policy-race" in
    Masc_test_deps.declare_fixture_keeper ~base_path
      ~sandbox_profile:(Some Keeper_types_profile_sandbox.Docker) keeper_name;
    let oauth_source = Filename.concat base_path "operator-oauth-token" in
    write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "synthetic-policy-account");
    let marker = Filename.concat base_path "unexpected-spawn" in
    let cli_path = Filename.concat base_path "agy-never-spawn" in
    write_file ~mode:0o700 cli_path ("#!/bin/sh\ntouch " ^ shell_quote marker ^ "\nexit 0\n");
    let runtime_path = Filename.concat base_path "runtime.toml" in
    write_file ~mode:0o600 runtime_path (runtime_toml ~cli_path ~oauth_source);
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw (fun () ->
        Eio_context.set_env env;
        Runtime.init_default ~config_path:runtime_path |> Result.get_ok;
        let config = match Runtime.get_runtime_by_id "antigravity.gemini" with
          | Some {Runtime_instance.execution=Runtime_execution.Antigravity_cli config; _} -> config
          | _ -> fail "Antigravity binding missing" in
        let owner_leaf = Runtime_antigravity_home.keeper_owner_leaf ~keeper_name ~oauth_source in
        let home, _ = Runtime_antigravity_home.prepare_native ~runtime_root ~owner_leaf ~oauth_source
            ~posture:Runtime_native_tools.Native_full
            ~workspace:Runtime_antigravity_home.Private_workspace ~additional_workspaces:[]
          |> Result.get_ok in
        let settings = (Runtime_antigravity_home.For_testing.paths home).settings_path in
        let winner_policy = Fs_compat.load_file settings in
        let won = ref false in
        let hooks = {Agent_core.Hooks.empty with before_turn_params=Some (fun _ ->
          let module Store = Keeper_official_client_session_store in
          let surface = Store.tool_surface_sha256
              ~account_home:(Runtime_antigravity_home.home_dir home)
              ~native_posture:Runtime_native_tools.Native_full [] in
          (match Store.claim ~base_path ~keeper_name ~expected:None ~client_kind:Store.Antigravity
              ~owner_epoch:(Store.process_epoch ()) ~runtime_id:"antigravity.gemini"
              ~tool_surface_sha256:surface ~updated_at:0. with
           | Ok _ -> won := true
           | Error detail -> fail detail);
          Agent_core.Hooks.Continue)} in
        let attempt = Keeper_antigravity_runtime.run ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = keeper_name })
          ~turn_start:(Keeper_carried_front.Turn_boundary {end_atom=0})
          ~accepts_image_input:false ~required_native_posture:Runtime_native_tools.Native_read
          ~runtime_id:"antigravity.gemini" ~keeper_name ~pre_tool_rejects:(ref []) ~base_path
          ~goal:"Losing candidate" ~goal_blocks:None ~system_prompt:"Policy race fixture."
          ~tools:[] ~initial_messages:[] ~model_input_projection:None
          ~on_transmitted_model_input:(fun _ -> ()) ~hooks:(Some hooks)
          ~context_injector:None ~context:None ~event_bus:None ~raw_trace:None ~on_event:None
          ~config () in
        check bool "competing owner claimed after the candidate snapshot" true !won;
        (match attempt.result with
         | Error (Agent_core.Error.Internal detail) ->
           check bool "stale candidate specifically loses the session claim" true
             (String.starts_with ~prefix:"Antigravity session claim failed:" detail)
         | Error error -> fail (Agent_core.Error.to_string error)
         | Ok _ -> fail "stale candidate unexpectedly won its session claim");
        check bool "loser never launches its CLI" false (Sys.file_exists marker);
        check string "loser cannot replace the winner's Full policy with Read"
          winner_policy (Fs_compat.load_file settings)))))
;;

let test_native_policy_failure_releases_claim () =
  let base_path = temp_workspace () |> Unix.realpath in
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect ~finally:(fun () -> Runtime.For_testing.restore snapshot; cleanup_tree base_path) (fun () ->
    let runtime_root = Common.masc_dir_from_base_path ~base_path in
    Unix.mkdir runtime_root 0o700;
    let keeper_name = "antigravity-policy-failure" in
    Masc_test_deps.declare_fixture_keeper ~base_path
      ~sandbox_profile:(Some Keeper_types_profile_sandbox.Docker) keeper_name;
    let oauth_source = Filename.concat base_path "operator-oauth-token" in
    write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "synthetic-policy-account");
    let marker = Filename.concat base_path "unexpected-spawn" in
    let cli_path = Filename.concat base_path "agy-never-spawn" in
    write_file ~mode:0o700 cli_path ("#!/bin/sh\ntouch " ^ shell_quote marker ^ "\nexit 0\n");
    let runtime_path = Filename.concat base_path "runtime.toml" in
    write_file ~mode:0o600 runtime_path (runtime_toml ~cli_path ~oauth_source);
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw (fun () ->
        Eio_context.set_env env;
        Runtime.init_default ~config_path:runtime_path |> Result.get_ok;
        let config = match Runtime.get_runtime_by_id "antigravity.gemini" with
          | Some {Runtime_instance.execution=Runtime_execution.Antigravity_cli config; _} -> config
          | _ -> fail "Antigravity binding missing" in
        let owner_leaf = Runtime_antigravity_home.keeper_owner_leaf ~keeper_name ~oauth_source in
        let home = Runtime_antigravity_home.prepare ~runtime_root ~owner_leaf ~oauth_source
          |> Result.get_ok in
        let _ = Runtime_antigravity_home.prepare_native_tools home
            ~posture:Runtime_native_tools.Native_full
            ~workspace:Runtime_antigravity_home.Private_workspace ~additional_workspaces:[]
          |> Result.get_ok in
        let settings = (Runtime_antigravity_home.For_testing.paths home).settings_path in
        let hooks = {Agent_core.Hooks.empty with before_turn_params=Some (fun _ ->
          Unix.unlink settings;
          Unix.mkdir settings 0o700;
          Agent_core.Hooks.Continue)} in
        let attempt = Keeper_antigravity_runtime.run ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = keeper_name })
          ~turn_start:(Keeper_carried_front.Turn_boundary {end_atom=0})
          ~accepts_image_input:false ~required_native_posture:Runtime_native_tools.Native_read
          ~runtime_id:"antigravity.gemini" ~keeper_name ~pre_tool_rejects:(ref []) ~base_path
          ~goal:"Losing candidate" ~goal_blocks:None ~system_prompt:"Policy race fixture."
          ~tools:[] ~initial_messages:[] ~model_input_projection:None
          ~on_transmitted_model_input:(fun _ -> ()) ~hooks:(Some hooks)
          ~context_injector:None ~context:None ~event_bus:None ~raw_trace:None ~on_event:None
          ~config () in
        (match attempt.result with
         | Error (Agent_core.Error.Config (InvalidConfig {field; _})) ->
           check string "native policy publication failure" "antigravity_home" field
         | Error error -> fail (Agent_core.Error.to_string error)
         | Ok _ -> fail "invalid policy destination unexpectedly launched a turn");
        check bool "policy refusal precedes CLI launch" false (Sys.file_exists marker);
        let module Store = Keeper_official_client_session_store in
        (match Store.load ~base_path ~keeper_name |> Result.map_error Store.read_error_to_string with
         | Ok (Some {phase=Ready; last_transient_release=Some {failure=Pre_dispatch_failed; _}; _}) -> ()
         | Ok _ -> fail "pre-dispatch failure retained a recovery fence"
         | Error detail -> fail detail)))))
;;

let test_every_declared_loading_is_eager_on_antigravity () =
  let tool name loading : Keeper_official_client_host.dynamic_tool =
    { name
    ; description = name
    ; input_schema = `Assoc [ "type", `String "object" ]
    ; loading
    ; result_bound = Runtime_official_client_tool.Unbounded
    ; execution_mode = (fun _ -> Agent_core.Tool_contract.Serial)
    ; call_effect = (fun _ -> Agent_core.Tool.Effect_possible)
    ; call = (fun ~call_id:_ _ -> Alcotest.fail "not called")
    }
  in
  check (list string) "upfront and on-demand tools are both eager"
    [ "upfront_tool"; "on_demand_tool" ]
    (Keeper_antigravity_runtime.eager_tool_names
       [ tool "upfront_tool" Runtime_official_client_tool.Upfront
       ; tool "on_demand_tool" Runtime_official_client_tool.On_demand
       ])
;;

(* #39768: the Antigravity runtime boundary catches unexpected exceptions the
   same way as Claude Code's, and they are masc internal failures, not parse
   errors of the CLI's reply. *)
let test_an_unhandled_runtime_exception_is_internal () =
  let exn_repr = "Unix.Unix_error(Unix.EPERM, \"kill\", \"\")" in
  let core =
    Keeper_antigravity_runtime.For_testing.runtime_error_to_core_error
      (Runtime_antigravity.Unhandled_exception exn_repr)
  in
  match Keeper_internal_error.classify_masc_internal_error core with
  | Some
      (Keeper_internal_error.Internal_unhandled_exception
         { site; exn_repr = recorded; transport_error_kind }) ->
    check string "site" "antigravity.runtime_boundary" site;
    check string "exception" exn_repr recorded;
    check bool "not a transport failure" true (Option.is_none transport_error_kind)
  | Some _ | None ->
    fail
      ("an unhandled runtime exception must be a masc internal error, got "
       ^ Agent_core.Error.to_string core)
;;

(* No recovery kind names a host exception. It takes the one whose disposition
   is Ambiguous -- what the CLI did is unknown -- so the next claim starts a
   fresh conversation rather than resuming one of unknown state. *)
let test_an_unhandled_runtime_exception_recovers_as_protocol_failed () =
  check bool "the recovery kind"
    (Keeper_antigravity_runtime.For_testing.recovery_failure_of_runtime_error
       (Runtime_antigravity.Unhandled_exception "Failure(\"boom\")")
    = Keeper_official_client_session_store.Protocol_failed)
    true
;;

(* #43259: a file-table safety kill is the provider's terminal failure, not
   an unavailable provider — refiring the same turn re-kills it, so the
   mapping must not invite blind retries. Recovery is Ambiguous
   (Transport_interrupted), never Transient. *)
let test_child_fd_ceiling_reports_and_recovers () =
  let open Keeper_antigravity_runtime.For_testing in
  let counted =
    Runtime_antigravity.Child_fd_ceiling_exceeded { count = Some 45000; ceiling = 16000 }
  in
  let pressured =
    Runtime_antigravity.Child_fd_ceiling_exceeded { count = None; ceiling = 16000 }
  in
  let check_reported error =
    match runtime_error_to_core_error error with
    | Agent_core.Error.Provider
        (Llm_provider.Error.ProviderReportedError { provider; error_type; detail }) ->
      check string "provider" "antigravity_cli" provider;
      check
        (option string)
        "error type"
        (Some "child_fd_ceiling_exceeded")
        error_type;
      check bool "detail names the ceiling" true (detail <> "")
    | core -> fail ("expected ProviderReportedError, got " ^ Agent_core.Error.to_string core)
  in
  check_reported counted;
  check_reported pressured;
  check bool "counted recovery"
    (recovery_failure_of_runtime_error counted
    = Keeper_official_client_session_store.Transport_interrupted)
    true;
  check bool "pressured recovery"
    (recovery_failure_of_runtime_error pressured
    = Keeper_official_client_session_store.Transport_interrupted)
    true
;;

(* Exercise the actual adapter writer, then recover its serialized argument
   through the same canonical reader tool that the prepared surface advertises. *)
module Argument_start_fixture = struct
  module T = Agent_core.Types
  module Host = Keeper_official_client_host
  let old_input = `Assoc ["command", `String (String.make 4000 'a')]
  let current_input = `Assoc ["command", `String (String.make 4000 'c')]
  let exchange id input =
    [ T.make_message ~role:T.Assistant [T.ToolUse {id;name="record";input}]
    ; T.tool_result_msg ~tool_use_id:id ~content:"done" () ]
  let seed = T.make_message ~role:T.User [T.Text "Earlier completed work"]
             :: exchange "historical-argument" old_input
  let history = seed @ [T.make_message ~role:T.User [T.Text "Current work"]]
                @ exchange "current-argument" current_input
  let boundary messages = Keeper_carried_front.Turn_boundary
      {end_atom=snd (Runtime_model_input_tail_window.annotate messages)}
  let source ~base_path ~keeper_name seed =
    Host.create_argument_source ~input_policy:Keeper_input_policy.Small ~base_path ~keeper_name
      ~seed:(Some seed) ~replay_prefix:Keeper_replay_prefix.unchanged ~turn_start:(boundary seed)
  let librarian_front _ : (Host.librarian_position, Agent_core.Error.t) result = Ok
      {point=Keeper_turn_driver_try_provider.Librarian_progress {end_atom=1};
       unread=Keeper_librarian_request_unread.empty}
  let snapshot () = List.map Agent_core.Checkpoint.message_to_json history
  let reader base_path =
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
  let envelopes prompt =
    String.split_on_char '\n' prompt |> List.filter_map (fun line ->
      try match Yojson.Safe.from_string line with
        | `Assoc fields as envelope when List.assoc_opt "schema" fields =
            Some (`String Keeper_official_client_context_codec.schema) -> Some envelope
        | _ -> None
      with Yojson.Json_error _ -> None)

  let check_resume prompt =
    let open Yojson.Safe.Util in
    let messages = List.map (member "message") (envelopes prompt) in
    check int "Resume carries exactly one recognized envelope" 1 (List.length messages);
    let historical = List.filter (fun message ->
      member "origin" message = `String "conversation") messages in
    check int "Resume omits canonical conversation history" 0 (List.length historical);
    List.iter (fun marker ->
      check bool "Resume does not replay fixture history" false
        (String_util.contains_substring prompt marker))
      ["historical-argument"; "current-argument"; "Earlier completed work"; "Current work"];
    let receipts = List.filter (fun message ->
      member "role" message = `String "system"
      && member "origin" message = `String "agent_instruction"
      && member "masc_retained_tool_results" (member "metadata" message) = `Bool true)
      messages in
    let receipt_text = match receipts with
      | [message] ->
        (match member "content_blocks" message with
         | `List [block] ->
           check string "retained result carrier uses a text block" "text"
             (member "type" block |> to_string);
           member "text" block |> to_string
         | _ -> fail "retained result carrier has unexpected content")
      | _ -> fail "Resume must carry the retained tool result once" in
    let receipt_json = match String.index_opt receipt_text '\n' with
      | None -> fail "retained result has no receipt payload"
      | Some at -> String.sub receipt_text (at + 1) (String.length receipt_text - at - 1)
        |> Yojson.Safe.from_string in
    let receipt = match receipt_json with
      | `List [receipt] -> receipt
      | _ -> fail "expected one retained tool receipt" in
    check string "retained tool name" "masc_probe" (receipt |> member "tool_name" |> to_string);
    check bool "retained tool arguments" true
      (member "arguments" receipt = `Assoc ["marker", `String "from-antigravity"]);
    check bool "retained tool succeeded" true
      (receipt |> member "response" |> member "success" = `Bool true);
    check string "retained original tool result" "MASC_TOOL_RESULT"
      (receipt |> member "response" |> member "content" |> to_string)

  let wire_input id envelopes =
    let open Yojson.Safe.Util in
    let blocks = List.concat_map (fun envelope ->
      envelope |> member "message" |> member "content_blocks" |> to_list) envelopes in
    match List.find_opt (fun block -> member "type" block=`String "tool_use"
      && member "id" block=`String id) blocks with
    | Some block -> member "input" block
    | None -> fail ("actual wire omitted tool occurrence " ^ id)
  let check_start ~enabled ~reader envelopes =
    check bool "current-turn argument is exact on the actual wire" true
      (wire_input "current-argument" envelopes=current_input);
    let historical = wire_input "historical-argument" envelopes in
    if not enabled then
      check bool "without the actual reader the historical argument stays raw" true
        (historical=old_input)
    else match Tool_output.normalized_artifact_ref_of_json historical with
      | Tool_output.Not_normalized_artifact_ref | Invalid_normalized_artifact_ref _ ->
        fail "actual Start did not serialize a normalized argument reference"
      | Tool_output.Decoded_normalized_artifact_ref reference ->
        check string "argument MIME" "application/json" reference.mime;
        let bytes = Buffer.create reference.bytes in
        let rec read offset =
          let result = match Agent_core.Tool.execute reader
              (`Assoc ["sha256",`String reference.sha256;"offset",`Int offset]) with
            | Ok result -> result | Error error -> fail error.message in
          let page = Yojson.Safe.from_string result.content in
          let open Yojson.Safe.Util in
          let content = page |> member "content" |> to_string in
          Buffer.add_string bytes (match page |> member "encoding" |> to_string with
            | "utf-8" -> content | "base64" -> Base64.decode_exn content
            | other -> fail ("unexpected page encoding " ^ other));
          if not (page |> member "eof" |> to_bool) then
            read (page |> member "next_offset" |> to_int) in
        read 0;
        check string "canonical tool reconstructs exact original JSON"
          (Yojson.Safe.to_string old_input) (Buffer.contents bytes)
  let check_resume_did_not_store base_path =
    let sha256=Agent_core_sha256.(to_hex (digest_string (Yojson.Safe.to_string current_input))) in
    match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256 with
    | Ok None -> ()
    | Ok (Some _) -> fail "Resume materialized the newly eligible argument"
    | Error error -> fail (Tool_blob_store.fetch_error_to_string error)
end

let test_projection_refusal_emits_no_carried_observations () =
  let projected = ref 0 and observed = ref 0 in
  let result = Keeper_official_client_host.carried_history_projection ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "refusal-fixture" })
    ~on_model_input_window_observation:(fun _ -> incr observed)
    ~on_carried_front:(fun _ ~transmitted_bytes:_ -> incr observed)
    ~librarian_front:Argument_start_fixture.librarian_front
    ~turn_start:(Argument_start_fixture.boundary Argument_start_fixture.seed)
    ~keeper_name:"refusal-fixture" ~runtime_id:"antigravity.gemini"
    (Some (fun _ -> incr projected;Error (Agent_core.Error.Internal "projection refused")))
    Argument_start_fixture.history in
  (match result with
   | Error (Agent_core.Error.Internal "projection refused") -> ()
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok _ -> fail "source projection refusal was lost");
  check int "source projection runs once" 1 !projected;
  check int "a refused range publishes no continuity or window" 0 !observed
;;

let test_actual_start_demotes_arguments_but_resume_keeps_them_held () =
  let module F = Argument_start_fixture in
  List.iter (fun enabled ->
    let base_path = temp_workspace () |> Unix.realpath in
    let snapshot = Runtime.For_testing.snapshot () in
    Fun.protect ~finally:(fun () -> Runtime.For_testing.restore snapshot; cleanup_tree base_path) (fun () ->
      Unix.mkdir (Filename.concat base_path ".masc") 0o700;
      let keeper_name="antigravity-fixture" in
      Masc_test_deps.declare_fixture_keeper ~base_path
        ~sandbox_profile:(Some Keeper_types_profile_sandbox.Docker) keeper_name;
      let oauth_source=Filename.concat base_path "operator-oauth-token" in
      write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "argument-account");
      let cli_path=fixture_script_with_tools ~argument_reader:enabled ~base_path in
      let runtime_path=Filename.concat base_path "runtime.toml" in
      write_file ~mode:0o600 runtime_path (runtime_toml ~cli_path ~oauth_source);
      Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
        Eio_context.set_env env;
        Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw (fun () ->
          Runtime.init_default ~config_path:runtime_path |> Result.get_ok;
          let config=match Runtime.get_runtime_by_id "antigravity.gemini" with
            | Some {Runtime_instance.execution=Runtime_execution.Antigravity_cli config;_} -> config
            | Some _ | None -> fail "Antigravity binding missing" in
          let reader=F.reader base_path in
          let marker : Agent_core.Types.tool_param =
            {name="marker";description="Fixture marker";param_type=String;required=true} in
          let probe=Agent_core.Tool.create ~name:"masc_probe" ~description:"Return fixture marker"
            ~parameters:[marker] (fun _ -> Ok
              {Agent_core.Types.content="MASC_TOOL_RESULT";content_blocks=None;_meta=None}) in
          let tools=if enabled then [probe;reader] else [probe] in
          let before=F.snapshot () in
          let transmissions=ref [] in
          let run seed =
            let attempt=Keeper_antigravity_runtime.run ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = keeper_name })
              ?argument_source:(F.source ~base_path ~keeper_name seed)
              ~accepts_image_input:false ~runtime_id:"antigravity.gemini" ~keeper_name
              ~pre_tool_rejects:(ref []) ~base_path ~goal:"Continue the work" ~goal_blocks:None
              ~system_prompt:"Argument writer fixture" ~tools ~initial_messages:F.history
              ~turn_start:(F.boundary seed) ~librarian_front:F.librarian_front
              ~model_input_projection:None
              ~on_transmitted_model_input:(fun input -> transmissions:=input :: !transmissions)
              ~hooks:None ~context_injector:None ~context:(Some (Agent_core.Context.create ()))
              ~event_bus:None ~raw_trace:None ~on_event:None ~config () in
            match attempt.result with
            | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error) in
          run F.seed;
          let prompt_path=Filename.concat base_path "antigravity-prompt.txt" in
          let envelopes=In_channel.with_open_bin prompt_path In_channel.input_all |> F.envelopes in
          F.check_start ~enabled ~reader envelopes;
          F.check_resume_did_not_store base_path;
          (* A fresh completed seed covers more of the same raw history;
             Resume must neither bind nor materialize its newly eligible SHA. *)
          run F.history;
          (match List.rev !transmissions with
           | [Keeper_official_client_host.Whole_input_transmitted _;
              Keeper_official_client_host.Held_by_client_session] -> ()
           | _ -> fail "expected one Start and one client-held Resume");
          let resumed=In_channel.with_open_bin prompt_path In_channel.input_all in
          (* This fixture does not ACK the first tool result. Its System
             carrier uses the same envelope schema as conversation history. *)
          F.check_resume resumed;
          F.check_resume_did_not_store base_path;
          check bool "raw checkpoint source remains unchanged" true (F.snapshot ()=before))))))
    [true;false]
;;

let test_operator_interrupt_preserves_previous_native_settlement () =
  let base_path = temp_workspace () |> Unix.realpath in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
      Unix.mkdir (Filename.concat base_path ".masc") 0o700;
      Masc_test_deps.declare_fixture_keeper
        ~base_path ~sandbox_profile:(Some Keeper_types_profile_sandbox.Docker) "antigravity-fixture";
      let oauth_source = Filename.concat base_path "operator-oauth-token" in
      write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "operator-oauth-fixture");
      let cli_path = Filename.concat base_path "agy-interrupt-fixture.sh" in
      let cwd_json =
        Yojson.Safe.to_string
          (`String
             (Env_config_core.strip_trailing_slashes
                (Filename.concat base_path
                   (Keeper_sandbox.host_root_rel_of_profile
                      Keeper_types_profile_sandbox.Docker
                      "antigravity-fixture"))))
      in
      write_file ~mode:0o700 cli_path
        (Printf.sprintf
           "#!/bin/sh\nset -eu\ntest \"$(dirname \"$HOME\")\" = %s\nconversation=conversation-antigravity-fixture\nturns=1\nfor arg in \"$@\"; do\n  case \"$arg\" in\n    conversation-antigravity-fixture) turns=2 ;;\n  esac\ndone\ncat >/dev/null\nprintf '{\"event\":\"init\",\"conversation_id\":\"%%s\",\"init\":{\"model\":\"gemini-fixture\",\"cwd\":%s,\"tools\":[],\"permission_mode\":\"always-proceed\"}}\\n' \"$conversation\"\nprintf '{\"event\":\"result\",\"result\":{\"conversation_id\":\"%%s\",\"status\":\"SUCCESS\",\"response\":\"MASC_ANTIGRAVITY_OK\",\"error\":null,\"num_turns\":%%d,\"usage\":{\"input_tokens\":12,\"output_tokens\":4,\"thinking_tokens\":1,\"cache_read_tokens\":40,\"total_tokens\":16}}}\\n' \"$conversation\" \"$turns\"\n"
           (shell_quote (account_store ~base_path))
           cwd_json);
      let runtime_path = Filename.concat base_path "runtime.toml" in
      write_file ~mode:0o600 runtime_path (runtime_toml ~cli_path ~oauth_source);
      let runtime_snapshot = Runtime.For_testing.snapshot () in
      Fun.protect
        ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
        (fun () ->
          Eio_main.run (fun env ->
            Eio.Switch.run (fun sw ->
              Eio_context.set_env env;
              Eio_context.with_test_env
                ~net:(Eio.Stdenv.net env)
                ~clock:(Eio.Stdenv.clock env)
                ~mono_clock:(Eio.Stdenv.mono_clock env)
                ~sw
                (fun () ->
                  Runtime.init_default ~config_path:runtime_path |> Result.get_ok;
                  let run ?on_event goal =
                    Keeper_turn_driver.run_named ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "antigravity-fixture" }) ~raw_trace:None
                      ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
                      ~runtime_id:"antigravity.gemini"
                      ~keeper_name:"antigravity-fixture"
                      ~base_path ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
                      ~goal
                      ~system_prompt:"pre-dispatch fixture system prompt"
                      ~agent_core_tools:[]
                      ?on_event
                      ~context:(Agent_core.Context.create ())
                      ~sw
                      ~net:(Eio.Stdenv.net env)
                      ()
                  in
                  (match run "ORIGINAL" with
                   | Ok _ -> ()
                   | Error error -> fail (Agent_core.Error.to_string error));
                  let original =
                    Keeper_official_client_session_store.load
                      ~base_path ~keeper_name:"antigravity-fixture"
                    |> Result.get_ok |> Option.get
                  in
                  let observed : Keeper_semantic_execution.official_client_checkpoint =
                    match original.phase with
                    | Settled { session_id; turn_id } ->
                      { client_kind = original.client_kind
                      ; runtime_id = original.runtime_id
                      ; session_id
                      ; turn_id
                      ; tool_surface_sha256 = original.tool_surface_sha256
                      ; frame = Keeper_repetition_snapshot.empty
                      }
                    | Ready | Start _ | Active _ | Turn_inflight _ | Recovery_required _ ->
                      fail "original native turn did not settle"
                  in
                  let observed_terminal_event = ref false in
                  (match
                     run
                       ~on_event:(function
                         | Agent_core.Types.MessageStop ->
                           observed_terminal_event := true;
                           raise Keeper_registry_types.Operator_interrupt
                         | _ -> ())
                       "NEWER"
                   with
                   | exception exn when Keeper_registry_types.is_operator_interrupt exn -> ()
                   | exception exn -> fail (Printexc.to_string exn)
                   | Ok _ | Error _ ->
                     fail "operator interrupt was converted to a provider result");
                  check bool "native terminal callback was reached" true !observed_terminal_event;
                  let restored =
                    Keeper_official_client_session_store.load
                      ~base_path ~keeper_name:"antigravity-fixture"
                    |> Result.get_ok |> Option.get
                  in
                  check bool "operator interruption restores prior settlement" true
                    (restored.phase = original.phase);
                  (match restored.last_transient_release with
                   | Some release ->
                     check bool "typed owner stop was recorded" true
                       (release.failure = Owner_stopped_turn)
                   | None -> fail "owner stop release evidence was not persisted");
                  let resumed =
                    Keeper_direct_checkpoint_continuation.For_testing.prepare_official_resume
                      ~observed ~expected:(Some restored)
                    |> Result.get_ok
                  in
                  check string "previous checkpoint remains resumable"
                    observed.turn_id resumed.turn_id)))))
;;

let test_original_result_survives_a_vendor_session_change () =
  let base_path = temp_workspace () |> Unix.realpath in
  let saved = Runtime.For_testing.snapshot () in
  Fun.protect ~finally:(fun () -> Runtime.For_testing.restore saved; cleanup_tree base_path)
    (fun () ->
      Unix.mkdir (Filename.concat base_path ".masc") 0o700;
      let keeper_name = "antigravity-fixture" in
      Masc_test_deps.declare_fixture_keeper ~base_path
        ~sandbox_profile:(Some Keeper_types_profile_sandbox.Docker) keeper_name;
      let oauth_source = Filename.concat base_path "operator-oauth-token" in
      write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "outbox-account");
      let cli_path = fixture_script ~base_path in
      let runtime_path = Filename.concat base_path "runtime.toml" in
      write_file ~mode:0o600 runtime_path (runtime_toml ~cli_path ~oauth_source);
      Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
        Eio_context.set_env env;
        Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw (fun () ->
          Fs_compat.set_fs env#fs;
          Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
            let get = function Ok value -> value | Error detail -> fail detail in
            Runtime.init_default ~config_path:runtime_path |> get;
            let config = match Runtime.get_runtime_by_id "antigravity.gemini" with
              | Some {Runtime_instance.execution=Runtime_execution.Antigravity_cli config;_} -> config
              | Some _ | None -> fail "Antigravity fixture binding missing" in
            let marker : Agent_core.Types.tool_param =
              {name="marker";description="marker";param_type=String;required=true} in
            let tool = Agent_core.Tool.create ~name:"masc_probe" ~description:"Fixture result"
              ~parameters:[marker] (fun _ -> Ok
                {Agent_core.Types.content="MASC_TOOL_RESULT";content_blocks=None;_meta=None}) in
            let run () =
              let attempt = Keeper_antigravity_runtime.run
                ~input_source:(Keeper_request_source.Keeper_history {trace_id=keeper_name})
                ~accepts_image_input:false ~runtime_id:"antigravity.gemini" ~keeper_name
                ~pre_tool_rejects:(ref []) ~base_path ~goal:"Continue from the original result"
                ~goal_blocks:None ~system_prompt:"Use retained result data without replaying completed effects."
                ~tools:[tool] ~initial_messages:[]
                ~model_input_projection:(Some (fun messages -> Ok (List.filter
                  (fun message -> not (Keeper_client_tool_outbox.is_context_message message)) messages)))
                ~turn_start:(Keeper_carried_front.Turn_boundary {end_atom=0})
                ~on_transmitted_model_input:(fun _ -> ()) ~hooks:None ~context_injector:None
                ~context:(Some (Agent_core.Context.create ())) ~event_bus:None ~raw_trace:None
                ~on_event:None ~config () in
              match attempt.result with
              | Ok result ->
                (match attempt.pending_result_receipts with
                 | None -> ()
                 | Some pending -> Keeper_client_tool_outbox.settle_consumption pending
                     ~stop_reason:result.Runtime_agent.stop_reason |> get)
              | Error error -> fail (Agent_core.Error.to_string error) in
            let retain turn_id value = Keeper_client_tool_outbox.retain ~base_path ~keeper_name
              {thread_id="original-codex-session";turn_id;call_id="original-call";
               tool_name="Execute";arguments=`String "original-effect-no-replay";response=`String value}
              |> get in
            let count () = Keeper_client_tool_outbox.load ~base_path ~keeper_name
              |> get |> Keeper_client_tool_outbox.receipt_ids |> List.length in
            let prompt () = In_channel.with_open_bin
              (Filename.concat base_path "antigravity-prompt.txt") In_channel.input_all in
            retain "original-1" "ORIGINAL_RESULT_FOR_ANTIGRAVITY";
            run ();
            check bool "Start carries original other-runtime result" true
              (String_util.contains_substring (prompt ()) "ORIGINAL_RESULT_FOR_ANTIGRAVITY");
            check int "completed first consumer ACKs its original snapshot" 0 (count ());
            Keeper_official_client_session_store.clear_then ~base_path ~keeper_name (fun () -> ()) |> get;
            retain "original-2" "ORIGINAL_RESULT_FOR_REPLACEMENT";
            run ();
            check bool "a replacement session receives exact original result" true
              (String_util.contains_substring (prompt ()) "ORIGINAL_RESULT_FOR_REPLACEMENT");
            check int "completed replacement ACKs its loaded snapshot" 0 (count ()))))))
;;

let () =
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  run
    "keeper_antigravity_runtime"
    [ ( "async result outbox"
        , [test_case "original result survives vendor session replacement" `Quick
             test_original_result_survives_a_vendor_session_change])
    ; ( "lifecycle"
        , [ test_case "projection refusal publishes no range" `Quick test_projection_refusal_emits_no_carried_observations
          ; test_case "actual argument Start and held Resume" `Quick test_actual_start_demotes_arguments_but_resume_keeps_them_held
          ; test_case "native policy failure releases its claim" `Quick
            test_native_policy_failure_releases_claim
          ; test_case
            "projects MCP tool and settles"
            `Quick
            test_keeper_projects_mcp_tool_and_settles
          ; test_case
            "an unhandled runtime exception is a masc internal error"
            `Quick
            test_an_unhandled_runtime_exception_is_internal
          ; test_case
            "an unhandled runtime exception recovers as protocol failed"
            `Quick
            test_an_unhandled_runtime_exception_recovers_as_protocol_failed
          ; test_case
            "child fd ceiling reports and recovers without blind retry"
            `Quick
            test_child_fd_ceiling_reports_and_recovers
          ; test_case
            "every declared loading is eager on Antigravity"
            `Quick
            test_every_declared_loading_is_eager_on_antigravity
          ; test_case
              "blank result starts fresh next turn"
              `Quick
              test_blank_success_requires_fresh_conversation
          ; test_case
              "spawn failure is pre-dispatch"
              `Quick
              test_spawn_failure_is_pre_dispatch
          ; test_case
              "blank system prompt is refused not defaulted"
              `Quick
              test_blank_system_prompt_is_refused_not_defaulted
        ; test_case "losing claim cannot publish native policy" `Quick
            test_losing_claim_cannot_publish_native_policy
        ; test_case
            "operator interrupt preserves previous native settlement"
            `Quick
            test_operator_interrupt_preserves_previous_native_settlement
        ] )
    ; ( "model input window"
        , [ test_case
              "the appended Gate reference is no durable atom"
              `Quick
              test_appended_gate_reference_is_no_durable_atom
          ; test_case
              "a seeded start matches the Agent Core carried range"
              `Quick
              test_seeded_start_matches_the_agent_core_range
          ; test_case
              "a cold start with no completed turn carries everything"
              `Quick
              test_cold_start_with_no_completed_turn_carries_everything
          ; test_case
              "a cold start begins at the turn start"
              `Quick
              test_cold_start_begins_at_the_turn_start
          ; test_case
              "the Librarian front reaches the list and its error refuses"
              `Quick
              test_the_librarian_front_reaches_the_list_and_its_error_refuses
        ; test_case
            "a Librarian snapshot leads with its working state"
            `Quick
            test_a_librarian_snapshot_leads_with_its_working_state
        ; test_case
            "a preamble is not a durable atom"
            `Quick
            test_a_preamble_is_not_a_durable_atom
          ; test_case
              "a front from another history is dropped"
              `Quick
              test_a_front_from_another_history_is_dropped
          ; test_case
              "stream usage is keyed by the CLI's turn"
              `Quick
              test_stream_usage_is_keyed_by_the_clis_turn
        ] )
    ]
;;

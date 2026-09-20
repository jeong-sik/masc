open Alcotest
open Masc

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

let fixture_script ~base_path =
  let path = Filename.concat base_path "agy-fixture.sh" in
  let prompt_path = Filename.concat base_path "antigravity-prompt.txt" in
  let script =
    Printf.sprintf
      {|#!/bin/sh
set -eu
test "$HOME" = %s
test -f "$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
test -f "$HOME/.gemini/config/mcp_config.json"
conversation=conversation-antigravity-fixture
turns=1
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
    conversation-antigravity-fixture) turns=73 ;;
  esac
done
test "$expect_mode" -eq 0
test "$mode" = plan
test "$sandbox" -eq 1
test "$slash_commands_disabled" -eq 1
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
assert [tool["name"] for tool in tools["result"]["tools"]] == ["masc_probe"]
called = post({"jsonrpc":"2.0","id":"call-1","method":"tools/call","params":{"name":"masc_probe","arguments":{"marker":"from-antigravity"}}}, version)
assert called["result"]["content"][0]["text"] == "MASC_TOOL_RESULT"
PY
printf '{"event":"step_update","step_update":{"conversation_id":"%%s","step_index":0,"state":"DONE","step_type":"system_message"}}\n' "$conversation"
printf '{"event":"step_update","step_update":{"conversation_id":"%%s","step_index":1,"state":"ACTIVE","step_type":"tool","tool_name":"call_mcp_tool"}}\n' "$conversation"
printf '{"event":"step_update","step_update":{"conversation_id":"%%s","step_index":1,"state":"DONE","step_type":"tool","tool_name":"call_mcp_tool"}}\n' "$conversation"
printf '{"event":"result","result":{"conversation_id":"%%s","status":"SUCCESS","response":"MASC_ANTIGRAVITY_KEEPER_OK","error":null,"num_turns":%%d,"usage":{"input_tokens":12,"output_tokens":4,"thinking_tokens":1,"cache_read_tokens":40,"total_tokens":16}}}\n' "$conversation" "$turns"
|}
      (shell_quote
         (Filename.concat
            (Filename.concat
               (Filename.concat base_path ".masc")
               "official-clients")
            "antigravity/antigravity-fixture"))
      (shell_quote prompt_path)
      (Yojson.Safe.to_string (`String base_path))
  in
  write_file ~mode:0o700 path script;
  path
;;

let blank_then_success_fixture_script ~base_path =
  let path = Filename.concat base_path "agy-blank-then-success.sh" in
  let invocation_path = Filename.concat base_path "antigravity-invocation" in
  let script =
    Printf.sprintf
      {|#!/bin/sh
set -eu
test "$HOME" = %s
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
         (Filename.concat
            (Filename.concat
               (Filename.concat base_path ".masc")
               "official-clients")
            "antigravity/antigravity-fixture"))
      (shell_quote invocation_path)
      (shell_quote invocation_path)
      (Yojson.Safe.to_string (`String base_path))
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
max-context = 128000
max-prompt-bytes = 1048576

[antigravity.gemini]

[runtime]
default = "antigravity.gemini"
|}
    cli_path
    oauth_source
;;

let keeper_response_text (result : Runtime_agent.run_result) =
  result.response.content
  |> List.filter_map (function Agent_core.Types.Text text -> Some text | _ -> None)
  |> String.concat ""
;;

let seed_ambiguous_resumed_session ~base_path ~tool =
  let module Store = Keeper_official_client_session_store in
  let owner_epoch = "11111111-1111-4111-8111-111111111111" in
  let runtime_id = "antigravity.gemini" in
  let tool_surface_sha256 =
    Store.tool_surface_sha256
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
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
      let mascot_root = Filename.concat base_path ".masc" in
      Unix.mkdir mascot_root 0o700;
      (* #36066: the runtime resolves the keeper's native posture from its
         declaration before any turn, so the fixture keeper is declared. *)
      Masc_test_deps.declare_fixture_keeper
        ~base_path ~sandbox_profile:None "antigravity-fixture";
      let oauth_source = Filename.concat base_path "operator-oauth-token" in
      write_file ~mode:0o600 oauth_source "operator-oauth-fixture";
      let raw_trace_path = Filename.concat base_path "antigravity-raw-trace.jsonl" in
      let raw_trace =
        Agent_core.Raw_trace.create ~path:raw_trace_path ()
        |> Result.map_error (fun error -> fail (Agent_core.Error.to_string error))
        |> Result.get_ok
      in
      let observed_trace_ref = ref None in
      let transmitted_inputs = ref [] in
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
        { role = Tool
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
          { Agent_core.Types.role = User
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
                    Keeper_turn_driver.run_named
                      ~runtime_id:"antigravity.gemini"
                      ~keeper_name:"antigravity-fixture"
                      ~base_path
                      ~goal:"Call masc_probe once"
                      ~system_prompt:"pre-dispatch fixture system prompt"
                      ~tools:[ tool ]
                      ~agent_core_tools:[ tool ]
                      ~initial_messages:large_history
                      ~on_request_attribution:record_transmitted
                      ~on_model_input_window_observation:
                        (fun ~measurement:_ reading ->
                           input_window_observations :=
                             reading :: !input_window_observations)
                      ~hooks
                      ~context:(Agent_core.Context.create ())
                      ~raw_trace
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
                      Keeper_turn_driver.run_named
                        ~runtime_id:"antigravity.gemini"
                        ~keeper_name:"antigravity-fixture"
                        ~base_path
                        ~goal:"Call masc_probe once"
                        ~system_prompt:"pre-dispatch fixture system prompt"
                        ~tools:[ tool ]
                        ~agent_core_tools:[ tool ]
                        ~initial_messages:large_history
                        ~on_request_attribution:record_transmitted
                        ~on_model_input_window_observation:
                          (fun ~measurement:_ reading ->
                             input_window_observations :=
                               reading :: !input_window_observations)
                        ~hooks
                        ~context:(Agent_core.Context.create ())
                        ~raw_trace
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
                      let preserved_prompt = In_channel.with_open_bin
                        (Filename.concat base_path "antigravity-prompt.txt") In_channel.input_all in
                      List.iter (fun (system_prompt, initial_messages) ->
                        match Keeper_turn_driver.run_named
                          ~runtime_id:"antigravity.gemini" ~keeper_name:"antigravity-fixture"
                          ~base_path ~goal:"New goal must not run with stale context"
                          ~system_prompt ~tools:[tool] ~agent_core_tools:[tool]
                          ~initial_messages ~hooks ~context:(Agent_core.Context.create ())
                          ~sw ~net:(Eio.Stdenv.net env) () with
                        | Error (Agent_core.Error.Config (InvalidConfig {field; _})) ->
                          check string "changed context has explicit admission reason"
                            "official_client_session.context_admission" field
                        | Error error -> fail (Agent_core.Error.to_string error)
                        | Ok _ -> fail "Antigravity resumed stale canonical context")
                        ["changed core instructions", large_history;
                         "pre-dispatch fixture system prompt", large_history @ [Agent_core.Types.user_msg "new native correction"]];
                      check string "rejected context never reaches CLI prompt"
                        preserved_prompt (In_channel.with_open_bin
                          (Filename.concat base_path "antigravity-prompt.txt") In_channel.input_all)))));
      (match List.rev !transmitted_inputs with
       | [ Keeper_official_client_host.Whole_input_transmitted messages;
           Keeper_official_client_host.Held_by_client_session ] ->
         check bool "fresh transmission contains prepared history" true
           (List.length messages > 0)
       | _ -> fail "successful start/resume did not each report their exact input mode");
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
              { Agent_core.Types.role = System
              ; content = [ Text dynamic_context ]
              ; name = None
              ; tool_call_id = None
              ; metadata = Agent_core.Types.Extra_system_context_provenance.metadata
              }));
      let resumed_prompt =
        match !observed_resumed_prompt with
        | Some prompt -> prompt
        | None -> fail "resumed Antigravity prompt was not captured"
      in
      check bool
        "resume carries dynamic System context"
        true
        (String_util.contains_substring
           resumed_prompt
           (Keeper_official_client_host.encode_history_message
              { Agent_core.Types.role = System
              ; content = [ Text dynamic_context ]
              ; name = None
              ; tool_call_id = None
              ; metadata = Agent_core.Types.Extra_system_context_provenance.metadata
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
          mascot_root
          "official-clients/antigravity/antigravity-fixture/.gemini/config/mcp_config.json"
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
        ~base_path ~sandbox_profile:None "antigravity-fixture";
      let oauth_source = Filename.concat base_path "operator-oauth-token" in
      write_file ~mode:0o600 oauth_source "operator-oauth-fixture";
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
                    Keeper_turn_driver.run_named
                      ~runtime_id:"antigravity.gemini"
                      ~keeper_name:"antigravity-fixture"
                      ~base_path
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
                             "successful result response has no deliverable content")
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
        ~base_path ~sandbox_profile:None "antigravity-pre-dispatch";
      Masc_test_deps.declare_fixture_keeper
        ~base_path ~sandbox_profile:None "antigravity-capacity-override";
      let oauth_source = Filename.concat base_path "operator-oauth-token" in
      write_file ~mode:0o600 oauth_source "operator-oauth-fixture";
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
                        { Runtime.execution =
                            Runtime_execution.Antigravity_cli config
                        ; _
                        } ->
                      config
                    | Some _ | None -> fail "Antigravity runtime fixture did not resolve"
                  in
                  let reports = ref [] in
                  let oversized_system_prompt = String.make 1_048_577 'x' in
                  let hooks =
                    { Agent_core.Hooks.empty with
                      before_turn_params =
                        Some
                          (function
                            | Agent_core.Hooks.BeforeTurnParams
                                { current_params; _ } ->
                              Agent_core.Hooks.AdjustParams
                                { current_params with
                                  system_prompt_override =
                                    Some oversized_system_prompt
                                }
                            | _ -> Agent_core.Hooks.Continue)
                    }
                  in
                  let oversized_attempt =
                    Keeper_antigravity_runtime.run
                      ~accepts_image_input:
                        (Runtime_agent.runtime_accepts_image_input
                           ~runtime:
                             (Runtime.get_runtime_by_id "antigravity.gemini"
                              |> Option.get))
                      ~pre_tool_rejects:(ref [])
                      ~runtime_id:"antigravity.gemini"
                      ~keeper_name:"antigravity-capacity-override"
                      ~base_path
                      ~goal:"override must be bounded"
                      ~goal_blocks:None
                      ~system_prompt:"small original prompt"
                      ~tools:[]
                      ~initial_messages:[]
                      ~model_input_projection:None
                      ~on_transmitted_model_input:
                        (fun report -> reports := report :: !reports)
                      ~hooks:(Some hooks)
                      ~context_injector:None
                      ~context:None
                      ~event_bus:None
                      ~raw_trace:None
                      ~on_event:None
                      ~config
                      ()
                  in
                  (match oversized_attempt.result with
                   | Error
                       (Agent_core.Error.Config
                          (Agent_core.Error.InvalidConfig { field; _ })) ->
                     check string "override refused field" "max_prompt_bytes" field
                   | Error error ->
                     fail
                       ("oversized system prompt override produced the wrong error: "
                        ^ Agent_core.Error.to_string error)
                   | Ok _ -> fail "oversized system prompt override reached the CLI");
                  let attempt =
                    Keeper_antigravity_runtime.run
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
   [prompt_for_turn] renders the system-instructions section only when the
   prompt trims non-empty, so a blank one would open the conversation with the
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
        ~base_path ~sandbox_profile:None "antigravity-blank-prompt";
      let oauth_source = Filename.concat base_path "operator-oauth-token" in
      write_file ~mode:0o600 oauth_source "operator-oauth-fixture";
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
                        { Runtime.execution =
                            Runtime_execution.Antigravity_cli config
                        ; _
                        } ->
                      config
                    | Some _ | None -> fail "Antigravity runtime fixture did not resolve"
                  in
                  let reports = ref [] in
                  let attempt =
                    Keeper_antigravity_runtime.run
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
  { role = User
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let capacity_projection ?on_model_input_window_observation ?carried_front_seed
    ~declared_max_prompt_bytes ~system_prompt ~goal source =
  Keeper_antigravity_runtime.For_testing.capacity_bounded_model_input_projection
    ~declared_max_prompt_bytes
    ~system_prompt
    ~goal
    ?on_model_input_window_observation
    ?carried_front_seed
    ~keeper_name:"alpha"
    ~runtime_id:"antigravity_subscription.gemini"
    source
;;

let test_undeclared_capacity_is_refused () =
  match
    capacity_projection
      ~declared_max_prompt_bytes:None
      ~system_prompt:"system"
      ~goal:"goal"
      None
  with
  | Error
      (Agent_core.Error.Config
         (Agent_core.Error.InvalidConfig { field = "max_prompt_bytes"; _ })) ->
    ()
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok _ -> fail "Antigravity admitted history without max-prompt-bytes"
;;

let test_declared_capacity_windows_history_and_reports_the_cut () =
  let observed = ref None in
  let assistant_tool_use : Agent_core.Types.message =
    { role = Assistant
    ; content = [ ToolUse { id = "call-latest"; name = "lookup"; input = `Null } ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let tool_result : Agent_core.Types.message =
    { role = Tool
    ; content =
        [ ToolResult
            { tool_use_id = "call-latest"
            ; content = "latest result"
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
  let history =
    List.init 10 (fun index ->
      plain_user_message
        (Printf.sprintf "history-%02d:%s" index (String.make 1024 'x')))
    @ [ assistant_tool_use; tool_result ]
  in
  let _labelled, history_atoms = Runtime_model_input_tail_window.annotate history in
  match
    capacity_projection
      ~declared_max_prompt_bytes:(Some 8192)
      ~system_prompt:"system"
      ~goal:"goal"
      ~on_model_input_window_observation:(fun reading -> observed := Some reading)
      None
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok None -> fail "declared capacity produced no projection"
  | Ok (Some project) ->
    (match project history with
     | Error error -> fail (Agent_core.Error.to_string error)
     | Ok projected ->
       let _labelled, projected_atoms =
         Runtime_model_input_tail_window.annotate projected
       in
       let prompt_bytes =
         Keeper_antigravity_runtime.For_testing.start_prompt_bytes
           ~system_prompt:"system"
           ~goal:"goal"
           projected
         |> Result.get_ok
       in
       check bool "rendered prompt is bounded" true (prompt_bytes <= 8192);
       check bool "old history was dropped" true (List.length projected < List.length history);
       check bool "a recent suffix remains" true (List.length projected > 0);
       (match List.rev projected with
        | { Agent_core.Types.role = Tool; _ }
          :: { Agent_core.Types.role = Assistant; _ }
          :: _ ->
          ()
        | _ -> fail "the newest Assistant+Tool atom was split by the window");
       (match !observed with
        | None -> fail "the projection reported no window"
        | Some reading ->
          check
            int
            "all source atoms are counted"
            history_atoms
            reading.total_atoms;
          check int "reported count is what ships" projected_atoms
            reading.transmitted_atoms;
          check
            (option string)
            "the reported front is the first retained atom"
            (Runtime_model_input_tail_window.atom_opening_digest
               history
               (history_atoms - projected_atoms))
            (Some reading.front_atom_digest)))
;;

let test_appended_gate_reference_is_inside_the_window () =
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
          ; front_digest = seed_front_digest
          ; source = Keeper_carried_front.Turn_record { turn = 40 }
          }
    ; unreadable = None
    }
  in
  match
    capacity_projection
      ~declared_max_prompt_bytes:(Some 8192)
      ~system_prompt:"system"
      ~goal:"goal"
      ~on_model_input_window_observation:(fun reading -> observed := Some reading)
      ~carried_front_seed:(fun () -> seed_read)
      source
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok None -> fail "declared capacity produced no projection"
  | Ok (Some project) ->
    (match project history with
     | Error error -> fail (Agent_core.Error.to_string error)
     | Ok projected ->
       (match List.rev projected with
        | last :: _ ->
          check
            bool
            "the appended newest material survives the cut"
             true
             (last.Agent_core.Types.content = marker.content)
        | [] -> fail "the declared window removed the appended Gate reference");
       (match !observed with
       | None -> fail "the projection reported no durable-history window"
       | Some reading ->
          check int "the Gate reference is not a durable-history atom" 10
            reading.total_atoms;
          check bool "capacity cuts deeper than the seed" true
            (reading.transmitted_atoms < 10 - seed_first_atom);
          check int "the final list adds only the Gate atom to the durable suffix"
            (reading.transmitted_atoms + 1)
            (snd (Runtime_model_input_tail_window.annotate projected));
          let expected_front = reading.total_atoms - reading.transmitted_atoms in
          check (option string) "the front digest uses the original history coordinate"
            (Runtime_model_input_tail_window.atom_opening_digest history expected_front)
            (Some reading.front_atom_digest);
          let next_seed : Keeper_carried_front.seed =
            { first_atom = expected_front
            ; front_digest = reading.front_atom_digest
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
           | Error _ -> fail "the projected observation did not seed the same history")))
;;

let test_gate_only_floor_emits_no_durable_front () =
  let observed = ref None in
  let history =
    List.init 3 (fun index ->
      plain_user_message
        (Printf.sprintf "oversized-%02d:%s" index (String.make 20_000 'x')))
  in
  let marker = plain_user_message "gate replay reference" in
  let projected =
    match
      capacity_projection
        ~declared_max_prompt_bytes:(Some 8192)
        ~system_prompt:"system"
        ~goal:"goal"
        ~on_model_input_window_observation:(fun reading -> observed := Some reading)
        (Some (fun messages -> Ok (messages @ [ marker ])))
    with
    | Error error -> fail (Agent_core.Error.to_string error)
    | Ok None -> fail "declared capacity produced no projection"
    | Ok (Some project) ->
      (match project history with
       | Error error -> fail (Agent_core.Error.to_string error)
       | Ok projected -> projected)
  in
  (match List.rev projected with
   | last :: _ ->
     check bool "the Gate atom remains at the floor" true
       (last.Agent_core.Types.content = marker.content)
   | [] -> fail "the capacity floor removed the Gate atom");
  check (option reject) "a Gate-only suffix has no durable front" None !observed
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
        ; front_digest
        ; source = Keeper_carried_front.Turn_record { turn = 41 }
        }
  ; unreadable = None
  }
;;

let encoded_history messages =
  List.map Keeper_official_client_host.encode_history_message messages
;;

let agent_core_range ~front messages =
  (Keeper_turn_driver_try_provider.For_testing.compose_carried_model_input
     ~measure_message_bytes:(Keeper_context_core.message_measurer ())
     ~front
     ~history_digest_at:(Runtime_model_input_tail_window.atom_opening_digest messages)
     ~last_resort:false
     ~base_path:""
     ~demote_before:0
     messages)
    .Keeper_turn_driver_try_provider.projection
    .Runtime_model_input_tail_window.messages
;;

let project_with_capacity ?on_model_input_window_observation ?carried_front_seed
    ~capacity messages =
  match
    capacity_projection
      ?on_model_input_window_observation
      ?carried_front_seed
      ~declared_max_prompt_bytes:(Some capacity)
      ~system_prompt:"system"
      ~goal:"goal"
      None
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok None -> fail "declared capacity produced no projection"
  | Ok (Some project) ->
    (match project messages with
     | Error error -> fail (Agent_core.Error.to_string error)
     | Ok projected -> projected)
;;

let test_seeded_start_matches_the_agent_core_range () =
  let observed = ref None in
  let messages = carried_front_history () in
  let seed_read = seed_read_at ~messages 53 in
  let projected =
    project_with_capacity
      ~on_model_input_window_observation:(fun reading -> observed := Some reading)
      ~carried_front_seed:(fun () -> seed_read)
      ~capacity:1_000_000
      messages
  in
  check (list string) "the same durable range is carried"
    (encoded_history (agent_core_range ~front:seed_read.seed messages))
    (encoded_history projected);
  match !observed with
  | None -> fail "the seeded projection reported no window"
  | Some reading ->
    check int "the reading keeps the full durable denominator" 60 reading.total_atoms;
    check int "the reading reports the seven seeded atoms" 7 reading.transmitted_atoms
;;

let test_cold_start_is_capacity_bounded_from_the_whole_history () =
  let messages = carried_front_history () in
  let projected = project_with_capacity ~capacity:1_000_000 messages in
  check (list string) "without a seed the whole fitting history is carried"
    (encoded_history messages)
    (encoded_history projected)
;;

let test_a_front_from_another_history_is_dropped () =
  let messages = carried_front_history () in
  let other =
    List.init 60 (fun index -> plain_user_message (Printf.sprintf "other-%02d" index))
  in
  let seed_read = seed_read_at ~messages:other 53 in
  let projected =
    project_with_capacity
      ~carried_front_seed:(fun () -> seed_read)
      ~capacity:1_000_000
      messages
  in
  check (list string) "a mismatched seed restarts from the whole fitting history"
    (encoded_history messages)
    (encoded_history projected)
;;

let test_fixed_sections_at_capacity_are_refused () =
  let capacity =
    Keeper_antigravity_runtime.For_testing.reserved_prompt_bytes
      ~system_prompt:"system"
      ~goal:"goal"
  in
  match
    capacity_projection
      ~declared_max_prompt_bytes:(Some capacity)
      ~system_prompt:"system"
      ~goal:"goal"
      None
  with
  | Error
      (Agent_core.Error.Config
         (Agent_core.Error.InvalidConfig { field = "max_prompt_bytes"; _ })) ->
    ()
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok _ -> fail "fixed sections filled the declared capacity"
;;

let () =
  run
    "keeper_antigravity_runtime"
    [ ( "lifecycle"
        , [ test_case
            "projects MCP tool and settles"
            `Quick
            test_keeper_projects_mcp_tool_and_settles
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
        ] )
    ; ( "model input window"
        , [ test_case
              "an undeclared capacity is refused"
              `Quick
              test_undeclared_capacity_is_refused
          ; test_case
              "declared capacity windows history and reports the cut"
              `Quick
              test_declared_capacity_windows_history_and_reports_the_cut
          ; test_case
              "the appended Gate reference stays inside the window"
              `Quick
              test_appended_gate_reference_is_inside_the_window
          ; test_case
              "a Gate-only floor emits no durable front"
              `Quick
              test_gate_only_floor_emits_no_durable_front
          ; test_case
              "a seeded start matches the Agent Core carried range"
              `Quick
              test_seeded_start_matches_the_agent_core_range
          ; test_case
              "a cold start is bounded from the whole history"
              `Quick
              test_cold_start_is_capacity_bounded_from_the_whole_history
          ; test_case
              "a front from another history is dropped"
              `Quick
              test_a_front_from_another_history_is_dropped
          ; test_case
              "fixed sections at capacity are refused"
              `Quick
              test_fixed_sections_at_capacity_are_refused
        ] )
    ]
;;

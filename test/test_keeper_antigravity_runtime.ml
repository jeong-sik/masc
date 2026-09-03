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
      let oauth_source = Filename.concat base_path "operator-oauth-token" in
      write_file ~mode:0o600 oauth_source "operator-oauth-fixture";
      let raw_trace_path = Filename.concat base_path "antigravity-raw-trace.jsonl" in
      let raw_trace =
        Agent_core.Raw_trace.create ~path:raw_trace_path ()
        |> Result.map_error (fun error -> fail (Agent_core.Error.to_string error))
        |> Result.get_ok
      in
      let observed_trace_ref = ref None in
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
            Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; _meta = None })
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
                      ~tools:[ tool ]
                      ~agent_core_tools:[ tool ]
                      ~initial_messages:large_history
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
                        ~tools:[ tool ]
                        ~agent_core_tools:[ tool ]
                        ~initial_messages:large_history
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
                        resumed.turns))));
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
                  let attempt =
                    Keeper_antigravity_runtime.run
                      ~pre_tool_rejects:(ref [])
                      ~runtime_id:"antigravity.gemini"
                      ~keeper_name:"antigravity-pre-dispatch"
                      ~base_path
                      ~goal:"spawn should fail"
                      ~goal_blocks:None
                      ~system_prompt:""
                      ~tools:[]
                      ~initial_messages:[]
                      ~model_input_projection:None
                      ~on_transmitted_model_input:(fun _ -> ())
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
                       attempt.effect_disposition))))))
;;

let plain_user_message text : Agent_core.Types.message =
  { role = User
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let capacity_projection ~declared_max_prompt_bytes ~system_prompt ~goal source =
  Keeper_antigravity_runtime.For_testing.capacity_bounded_model_input_projection
    ~declared_max_prompt_bytes
    ~system_prompt
    ~goal
    source
;;

(* The window reading is what a turn record carries and what /context reads.
   Before this was wired, the official-client adapters made the same cut as
   the Agent Core path and threw the counts away, so every one of their turn
   records was written with no window -- and /context answered "no turn has an
   exact provider-input composition" for keepers that had been running all
   day. Assert the numbers, not that a callback fired: a reading that says
   nothing about how much was dropped would satisfy the latter. *)
let test_capacity_reports_what_the_window_carried () =
  let observed = ref None in
  let messages = List.init 40 (fun i -> plain_user_message (Printf.sprintf "m%02d" i)) in
  match
    Keeper_antigravity_runtime.For_testing.capacity_bounded_model_input_projection
      ~declared_max_prompt_bytes:(Some 4096)
      ~system_prompt:"system"
      ~goal:"goal"
      ~on_model_input_window_observation:(fun o -> observed := Some o)
      None
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok None -> fail "a declared capacity produced no projection"
  | Ok (Some project) ->
    (match project messages with
     | Error error -> fail (Agent_core.Error.to_string error)
     | Ok windowed ->
       (match !observed with
        | None -> fail "the projection cut the history and reported nothing"
        | Some observation ->
          check
            int
            "the reading counts the history it was offered"
            (List.length messages)
            observation.Runtime_model_input_tail_window.total_atoms;
          check
            int
            "the reading counts what survived the cut"
            (List.length windowed)
            observation.Runtime_model_input_tail_window.transmitted_atoms;
          check
            bool
            "a cut happened, so the two numbers differ"
            true
            (observation.Runtime_model_input_tail_window.transmitted_atoms
             < observation.Runtime_model_input_tail_window.total_atoms)))
;;

let test_capacity_undeclared_passes_source_through () =
  (match
     capacity_projection
       ~declared_max_prompt_bytes:None
       ~system_prompt:"system"
       ~goal:"goal"
       None
   with
   | Ok None -> ()
   | Ok (Some _) -> fail "undeclared capacity invented a projection"
   | Error error -> fail (Agent_core.Error.to_string error));
  let marker = plain_user_message "source-projection-marker" in
  let source = Some (fun messages -> Ok (messages @ [ marker ])) in
  match
    capacity_projection
      ~declared_max_prompt_bytes:None
      ~system_prompt:"system"
      ~goal:"goal"
      source
  with
  | Ok (Some project) ->
    (match project [ plain_user_message "only" ] with
     | Ok projected ->
       check int "source projection untouched" 2 (List.length projected)
     | Error detail -> fail (Agent_core.Error.to_string detail))
  | Ok None -> fail "undeclared capacity dropped the source projection"
  | Error error -> fail (Agent_core.Error.to_string error)
;;

let test_capacity_windows_history_to_tail () =
  let history =
    List.init 10 (fun index ->
      plain_user_message
        (Printf.sprintf "history-%02d:%s" index (String.make 1024 'x')))
  in
  match
    capacity_projection
      ~declared_max_prompt_bytes:(Some 8192)
      ~system_prompt:"system"
      ~goal:"goal"
      None
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok None -> fail "declared capacity produced no projection"
  | Ok (Some project) ->
    (match project history with
     | Error detail -> fail (Agent_core.Error.to_string detail)
     | Ok windowed ->
       let kept = List.length windowed in
       check bool "capacity drops oldest history" true (kept < 10);
       check bool "capacity keeps a non-empty tail" true (kept > 0);
       let tail_of_history =
         List.filteri (fun index _ -> index >= 10 - kept) history
       in
       check
         bool
         "kept messages are the newest suffix"
         true
         (List.for_all2
            (fun (kept_message : Agent_core.Types.message)
                 (expected : Agent_core.Types.message) ->
              kept_message.content = expected.content)
            windowed
            tail_of_history))
;;

let test_capacity_bounds_an_appending_source_projection () =
  let history =
    List.init 10 (fun index ->
      plain_user_message
        (Printf.sprintf "history-%02d:%s" index (String.make 1024 'x')))
  in
  let marker = plain_user_message "source-projection-marker" in
  let source = Some (fun messages -> Ok (messages @ [ marker ])) in
  match
    capacity_projection
      ~declared_max_prompt_bytes:(Some 8192)
      ~system_prompt:"system"
      ~goal:"goal"
      source
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok None -> fail "declared capacity produced no projection"
  | Ok (Some project) ->
    (match project history with
     | Error detail -> fail (Agent_core.Error.to_string detail)
     | Ok projected ->
       let prompt_bytes =
         match
           Keeper_antigravity_runtime.For_testing.start_prompt_bytes
             ~system_prompt:"system"
             ~goal:"goal"
             projected
         with
         | Ok bytes -> bytes
         | Error detail -> fail detail
       in
       check
         bool
         "actual rendered prompt is inside the declared capacity"
         true
         (prompt_bytes <= 8192);
       (match List.rev projected with
        | last :: _ ->
          check
            bool
            "the appended newest material survives the window"
            true
            (last.Agent_core.Types.content = marker.content)
        | [] -> fail "projection emptied the history"))
;;

let test_capacity_counts_rendered_role_framing () =
  let history = List.init 100 (fun _ -> plain_user_message "") in
  let unprojected_prompt_bytes =
    match
      Keeper_antigravity_runtime.For_testing.start_prompt_bytes
        ~system_prompt:"system"
        ~goal:"goal"
        history
    with
    | Ok bytes -> bytes
    | Error detail -> fail detail
  in
  (* One byte below the exact unprojected prompt is a structural boundary:
     retaining every message is impossible. A payload-only estimator used to
     admit the whole history here because it omitted every rendered role label
     and separator. *)
  let capacity_bytes = unprojected_prompt_bytes - 1 in
  match
    capacity_projection
      ~declared_max_prompt_bytes:(Some capacity_bytes)
      ~system_prompt:"system"
      ~goal:"goal"
      None
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok None -> fail "declared capacity produced no projection"
  | Ok (Some project) ->
    (match project history with
     | Error detail -> fail (Agent_core.Error.to_string detail)
     | Ok projected ->
       check bool "role framing forces a history cut" true
         (List.length projected < List.length history);
       let prompt_bytes =
         match
           Keeper_antigravity_runtime.For_testing.start_prompt_bytes
             ~system_prompt:"system"
             ~goal:"goal"
             projected
         with
         | Ok bytes -> bytes
         | Error detail -> fail detail
       in
       check bool "role-framed prompt stays inside capacity" true
         (prompt_bytes <= capacity_bytes))
;;

let test_capacity_below_preamble_constant_is_a_typed_refusal () =
  let history = List.init 100 (fun _ -> plain_user_message "") in
  (* One byte above the admission reserve is the smallest capacity that gets a
     projection at all (at or below it the fixed sections are refused before
     any window exists). The rendered empty-history prompt is two bytes less
     than the reserve — it joins its two sections with one separator while the
     reserve charges both — so that one-byte history budget cannot fit the
     window's constant undroppable omission preamble. *)
  let capacity_bytes =
    Keeper_antigravity_runtime.For_testing.reserved_prompt_bytes
      ~system_prompt:"system"
      ~goal:"goal"
    + 1
  in
  match
    capacity_projection
      ~declared_max_prompt_bytes:(Some capacity_bytes)
      ~system_prompt:"system"
      ~goal:"goal"
      None
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok None -> fail "declared capacity produced no projection"
  | Ok (Some project) ->
    (match project history with
     | Error _ -> ()
     | Ok projected ->
       fail
         (Printf.sprintf
            "a capacity below the undroppable preamble constant admitted %d messages"
            (List.length projected)))
;;

let test_capacity_refuses_oversized_fixed_sections () =
  match
    capacity_projection
      ~declared_max_prompt_bytes:(Some 128)
      ~system_prompt:(String.make 256 's')
      ~goal:"goal"
      None
  with
  | Error error ->
    let detail = Agent_core.Error.to_string error in
    let contains ~needle haystack =
      let needle_len = String.length needle in
      let limit = String.length haystack - needle_len in
      let rec probe index =
        index <= limit
        && (String.equal (String.sub haystack index needle_len) needle
            || probe (index + 1))
      in
      probe 0
    in
    check
      bool
      "refusal names the declared capacity field"
      true
      (contains ~needle:"max_prompt_bytes" detail)
  | Ok _ -> fail "oversized fixed prompt sections were admitted"
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
        ] )
    ; ( "prompt capacity"
        , [ test_case
              "undeclared capacity passes source through"
              `Quick
              test_capacity_undeclared_passes_source_through
          ; test_case
              "declared capacity windows history to the newest tail"
              `Quick
              test_capacity_windows_history_to_tail
          ; test_case
              "an appending source projection stays inside the window"
              `Quick
              test_capacity_bounds_an_appending_source_projection
          ; test_case
              "role framing is charged to the prompt capacity"
              `Quick
              test_capacity_counts_rendered_role_framing
          ; test_case
              "a capacity below the preamble constant is refused"
              `Quick
              test_capacity_below_preamble_constant_is_a_typed_refusal
          ; test_case
              "oversized fixed sections are refused"
              `Quick
              test_capacity_refuses_oversized_fixed_sections
          ; test_case
              "the window reports what it carried and what it was offered"
              `Quick
              test_capacity_reports_what_the_window_carried
        ] )
    ]
;;

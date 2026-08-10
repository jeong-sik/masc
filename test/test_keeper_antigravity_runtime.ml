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
    --conversation) expect_conversation=1 ;;
    conversation-antigravity-fixture) turns=2 ;;
  esac
done
test "$expect_mode" -eq 0
test "$mode" = plan
test "$sandbox" -eq 1
test "$slash_commands_disabled" -eq 1
printf '%%s' "$2" > %s
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
printf '{"event":"step_update","step_update":{"conversation_id":"%%s","step_index":1,"state":"DONE","step_type":"tool"}}\n' "$conversation"
printf '{"event":"result","result":{"conversation_id":"%%s","status":"SUCCESS","response":"MASC_ANTIGRAVITY_KEEPER_OK","error":null,"num_turns":%%d,"usage":{"input_tokens":12,"output_tokens":4,"thinking_tokens":1,"cache_read_tokens":0,"total_tokens":16}}}\n' "$conversation" "$turns"
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
                      ~initial_messages:[ tool_history ]
                      ~context:(Agent_core.Context.create ())
                      ~raw_trace
                      ~sw
                      ~net:(Eio.Stdenv.net env)
                      ()
                  with
                  | Error error -> fail (Agent_core.Error.to_string error)
                  | Ok turn ->
                    observed_trace_ref := turn.trace_ref;
                    check string
                      "response"
                      "MASC_ANTIGRAVITY_KEEPER_OK"
                      (keeper_response_text turn);
                    check int "turn count" 1 turn.turns))));
      check string
        "tool arguments"
        {|{"marker":"from-antigravity"}|}
        (Yojson.Safe.to_string !observed);
      let prompt_path = Filename.concat base_path "antigravity-prompt.txt" in
      let prompt = In_channel.with_open_bin prompt_path In_channel.input_all in
      check bool
        "prompt preserves prior tool role"
        true
        (String_util.contains_substring prompt {|"role":"tool"|});
      check bool
        "prompt preserves prior tool output"
        true
        (String_util.contains_substring prompt "prior tool output");
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
           ; turn_id = "conversation-antigravity-fixture:ordinal:1"
           } -> ()
       | _ -> fail "Antigravity Keeper turn did not settle");
      let mcp_path =
        Filename.concat
          mascot_root
          "official-clients/antigravity/antigravity-fixture/.gemini/config/mcp_config.json"
      in
      check bool "turn capability cleared" false (Sys.file_exists mcp_path))
;;

(* A start turn seeds a fresh vendor conversation with the rendered history in
   one argv entry, so the seed is bounded by the exec boundary. The window keeps
   the newest messages: the goal answers the most recent turn, so trimming from
   the tail would drop exactly the context the goal refers to. *)
let test_history_window_keeps_the_newest_messages_within_budget () =
  let module W = Keeper_antigravity_runtime.For_testing in
  let messages = [ "oldest"; "middle"; "newest" ] in
  (* Every message fits: nothing is dropped and the order is preserved. *)
  let full = W.window_history_to_budget ~budget:1000 messages in
  check int "admits every message" 3 full.admitted;
  check int "drops nothing" 0 full.dropped;
  check string "keeps declared order" "oldest\n\nmiddle\n\nnewest" full.history;
  (* "middle\n\nnewest" is 14 bytes; "oldest" plus a separator would need 22. *)
  let windowed = W.window_history_to_budget ~budget:14 messages in
  check int "admits what fits" 2 windowed.admitted;
  check int "reports what it left out" 1 windowed.dropped;
  check string "keeps the newest, in order" "middle\n\nnewest" windowed.history;
  (* A budget under the newest message alone admits nothing rather than
     emitting a half message: the caller then hits the typed argv rejection,
     which names the boundary, instead of sending a truncated turn. *)
  let none = W.window_history_to_budget ~budget:3 messages in
  check int "admits nothing" 0 none.admitted;
  check int "reports the whole history as dropped" 3 none.dropped;
  check string "produces no history" "" none.history
;;

let test_history_window_budget_accounts_for_the_prompt_frame () =
  let module W = Keeper_antigravity_runtime.For_testing in
  (* The caller subtracts this from the argv budget, so it has to be the real
     cost of the frame rather than a guess. *)
  check
    int
    "frame cost is the two labels plus the two section joins"
    (String.length "SYSTEM INSTRUCTIONS:\n"
     + String.length "CURRENT GOAL:\n"
     + String.length "\n\n"
     + String.length "\n\n")
    W.fixed_prompt_label_bytes
;;

let () =
  run
    "keeper_antigravity_runtime"
    [ ( "lifecycle"
      , [ test_case
            "projects MCP tool and settles"
            `Quick
            test_keeper_projects_mcp_tool_and_settles
        ] )
    ; ( "start-turn history window"
      , [ test_case
            "keeps the newest messages within the argv budget"
            `Quick
            test_history_window_keeps_the_newest_messages_within_budget
        ; test_case
            "the budget accounts for the prompt frame"
            `Quick
            test_history_window_budget_accounts_for_the_prompt_frame
        ] )
    ]
;;

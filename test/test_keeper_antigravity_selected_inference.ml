open Alcotest
open Masc

type expected = Completes | Model_idle_timeout | Reasoning_refused
type replacement = Replace | Remove

let write_file ~perm path contents =
  let channel = open_out_gen [Open_creat; Open_trunc; Open_wronly] perm path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents)
;;

let shell_quote text =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' text) ^ "'"
;;

let host_script = {|import json, os, sys, time
here = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
assert sys.stdin.read(), "missing Keeper prompt"
with open(os.path.join(here, "turns.jsonl"), "a") as handle:
    handle.write(json.dumps(args) + "\n")
conversation = "keeper-selected-inference"
if "--conversation" in args:
    assert args[args.index("--conversation") + 1] == conversation
    turns = 2
else:
    assert "--new-project" in args
    turns = 1
print(json.dumps({"event": "init", "conversation_id": conversation, "init": {
    "model": "selected-fixture", "cwd": os.getcwd(), "tools": [],
    "permission_mode": "always-proceed"}}), flush=True)
time.sleep(0.4)
print(json.dumps({"event": "result", "result": {
    "conversation_id": conversation, "status": "SUCCESS",
    "response": "KEEPER_SELECTED_INFERENCE", "num_turns": turns,
    "usage": {"input_tokens": 1, "output_tokens": 1, "thinking_tokens": 0,
              "cache_read_tokens": 0, "total_tokens": 2}}}), flush=True)
|}
;;

let runtime_toml ~cli_path ~oauth_source ~model_key ~effort ~timeout =
  let reasoning = match effort with
    | None -> ""
    | Some value -> Printf.sprintf "reasoning-effort = %S"
        (Llm_provider.Reasoning_effort.to_string value) in
  let idle = match timeout with
    | None -> ""
    | Some value -> Printf.sprintf "turn-timeout-s = %.17g" value in
  Printf.sprintf {|[runtime]
default = "native.%s"
[providers.native]
protocol = "antigravity-cli"
command = %S
is-non-interactive = true
effort = "high"
timeout-s = 3.0
credentials = { type = "file", path = %S }
[models.%s]
api-name = "selected-fixture"
max-context = 4096
tools-support = true
streaming = true
%s
%s
[native.%s]
|} model_key cli_path oauth_source model_key reasoning idle model_key
;;

let invocation_args path =
  if Sys.file_exists path then
    In_channel.with_open_bin path In_channel.input_lines
    |> List.map (fun line -> Yojson.Safe.from_string line
      |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string)
  else []
;;

let rec flag name = function
  | key :: value :: _ when String.equal key name -> Some value
  | _ :: rest -> flag name rest
  | [] -> None
;;

let test_selected ?hook_effort ?(replacement = Replace)
    ~selected_effort ~live_effort ~selected_timeout ~live_timeout ~expected () =
  let base_path = Filename.temp_file "masc-agy-selected-" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  let base_path = Unix.realpath base_path in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let eio_snapshot = Eio_context.snapshot_state () in
  Fun.protect ~finally:(fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    Eio_context.restore_state eio_snapshot;
    Fs_compat.remove_tree base_path) @@ fun () ->
  Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some base_path) @@ fun () ->
  Unix.mkdir (Filename.concat base_path ".masc") 0o700;
  let keeper_name = "antigravity-selected" in
  Masc_test_deps.declare_fixture_keeper ~base_path
    ~sandbox_profile:(Some Keeper_types_profile_sandbox.Docker) keeper_name;
  let oauth_source = Filename.concat base_path "operator-oauth.json" in
  write_file ~perm:0o600 oauth_source
    (Masc_test_deps.antigravity_oauth_fixture "selected-fixture-account");
  let program = Filename.concat base_path "host.py" in
  let cli_path = Filename.concat base_path "agy-fixture" in
  write_file ~perm:0o600 program host_script;
  write_file ~perm:0o700 cli_path
    ("#!/bin/sh\nexec python3 " ^ shell_quote program ^ " \"$@\"\n");
  let selected_path = Filename.concat base_path "selected.toml" in
  let replacement_path = Filename.concat base_path "replacement.toml" in
  write_file ~perm:0o600 selected_path
    (runtime_toml ~cli_path ~oauth_source ~model_key:"selected"
       ~effort:selected_effort ~timeout:selected_timeout);
  let replacement_key = match replacement with Replace -> "selected" | Remove -> "other" in
  write_file ~perm:0o600 replacement_path
    (runtime_toml ~cli_path ~oauth_source ~model_key:replacement_key
       ~effort:live_effort ~timeout:live_timeout);
  let hooks = Option.map (fun effort ->
    {Agent_core.Hooks.empty with before_turn_params = Some (function
       | Agent_core.Hooks.BeforeTurnParams {current_params; _} ->
         Agent_core.Hooks.AdjustParams {current_params with reasoning_effort = effort}
       | _ -> Agent_core.Hooks.Continue)}) hook_effort in
  let trace = Filename.concat base_path "turns.jsonl" in
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio_context.set_env env;
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  let attempts = ref 0 in
  let on_runtime_attempt (attempt : Keeper_turn_driver.runtime_attempt) =
    incr attempts;
    check string "the callback follows selected candidate materialization"
      "native.selected" attempt.runtime_id;
    Runtime.init_default ~config_path:replacement_path |> Result.get_ok;
    (match replacement with
     | Remove -> check bool "the selected runtime is absent from live lookup" true
         (Option.is_none (Runtime.get_runtime_by_id "native.selected"))
     | Replace ->
       check bool "the live reasoning declaration really changed" true
         (Runtime.reasoning_effort_of_runtime_id "native.selected" = live_effort);
       check (option (float 0.000001)) "the live idle declaration really changed"
         live_timeout (Runtime.turn_timeout_s_of_runtime_id "native.selected")) in
  let send () =
    Runtime.init_default ~config_path:selected_path |> Result.get_ok;
    let errors = ref [] in
    let outcome = Keeper_turn_driver.run_named
        ~input_source:(Keeper_request_source.Keeper_history {trace_id = keeper_name})
        ~walk_owner:Keeper_turn_driver.One_shot_walk
        ~runtime_id:"native.selected" ~keeper_name ~base_path
        ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
        ~goal:"Return the selected inference marker."
        ~system_prompt:"Controlled selected-declaration Keeper fixture."
        ~tools:[] ~agent_core_tools:[] ~initial_messages:[] ?hooks
        ~on_runtime_attempt
        ~on_runtime_attempt_error:(fun ~runtime_id:_ ~attempt:_ ~dispatch:_ error ->
          errors := error :: !errors)
        ~context:(Agent_core.Context.create ()) ~raw_trace:None ~sw ~net:env#net () in
    (match expected with
     | Reasoning_refused ->
       check int "reasoning refusal happens before any native input" 0
         (List.length (invocation_args trace))
     | Completes | Model_idle_timeout ->
       check bool "the native child consumed input before model-idle judgement" true
         (invocation_args trace <> []));
    match expected, outcome with
    | Completes, Ok selected ->
      let response = selected.Keeper_turn_driver.run_result.response.content
        |> List.filter_map (function Agent_core.Types.Text text -> Some text | _ -> None)
        |> String.concat "" in
      check string "actual native completion" "KEEPER_SELECTED_INFERENCE" response
    | Reasoning_refused, Error _ ->
      (match !errors with
       | [Agent_core.Error.Config (Agent_core.Error.InvalidConfig {field; _})] ->
         check string "native effort ownership refuses generic reasoning" "reasoning_effort" field
       | _ -> fail "reasoning refusal lost the original typed candidate error")
    | Model_idle_timeout, Error _ ->
      (match !errors with
       | [Agent_core.Error.Api (Agent_core.Retry.Timeout _)] -> ()
       | _ -> fail "model-idle refusal lost the original typed timeout")
    | Completes, Error error -> fail (Agent_core.Error.to_string error)
    | (Reasoning_refused | Model_idle_timeout), Ok _ ->
      fail "a later catalog lookup replaced the selected admission or idle declaration" in
  send ();
  (match expected with
   | Completes ->
     send ();
     check int "fresh and resumed selected candidates" 2 !attempts;
     (match invocation_args trace with
      | [fresh; resumed] ->
        check (option string) "fresh mode" None (flag "--conversation" fresh);
        check (option string) "actual native resume" (Some "keeper-selected-inference")
          (flag "--conversation" resumed)
      | _ -> fail "expected exactly one fresh and one resumed native invocation")
   | Model_idle_timeout | Reasoning_refused ->
     check int "one failed selected candidate" 1 !attempts);
  List.iter (fun args -> check (option string) "provider owns native effort"
    (Some "high") (flag "--effort" args)) (invocation_args trace)
;;

let () =
  let case name ?hook_effort ?replacement ?(selected_effort = None) ?(live_effort = None)
      ?(selected_timeout = None) ?(live_timeout = None) expected =
    test_case name `Quick (test_selected ?hook_effort ?replacement
      ~selected_effort ~live_effort ~selected_timeout ~live_timeout ~expected) in
  run "keeper_antigravity_selected_inference"
    ["selected inference",
      [case "selected absence ignores later generic effort" ~live_effort:(Some High) Completes
      ;case "selected generic effort remains refused after removal" ~selected_effort:(Some High) Reasoning_refused
      ;case "runtime removal cannot clear selected generic effort" ~replacement:Remove
         ~selected_effort:(Some High) Reasoning_refused
      ;case "hook generic effort remains refused" ~hook_effort:(Some High) Reasoning_refused
      ;case "hook may clear selected generic effort" ~selected_effort:(Some High)
         ~live_effort:(Some High) ~hook_effort:None Completes
      ;case "selected unbounded idle survives positive replacement"
         ~selected_timeout:(Some 0.) ~live_timeout:(Some 0.1) Completes
      ;case "selected positive idle survives unbounded replacement"
         ~selected_timeout:(Some 0.1) ~live_timeout:(Some 0.) Model_idle_timeout
      ;case "selected idle absence ignores later positive declaration"
         ~live_timeout:(Some 0.1) Completes
      ;case "selected positive idle survives runtime removal" ~replacement:Remove
         ~selected_timeout:(Some 0.1) Model_idle_timeout
      ;case "unchanged absence retains provider native effort" Completes]]
;;

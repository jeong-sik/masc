open Alcotest

(* The cli-slot executor mirrors the HTTP lane contract on a transport with no
   request body: the prompt must end with the exact Agent Core schema sentence
   (both transports instruct with the same words), and the answer is parsed
   with strict [Yojson.Safe.from_string] — a fenced answer is invalid output,
   not something to repair. The walk advances per slot and keeps every
   failure in order.

   The runtime fixture is the fusion panel one: a stub HTTP binding and a
   claude-code binding whose CLI is /usr/bin/true, enough to classify ids
   without executing a client. *)

module Exact_output = Agent_core.Exact_output
module Cli_oneshot = Masc.Keeper_lane_cli_oneshot

let fixture ?(claude_cli = "/usr/bin/true") () =
  Printf.sprintf {|
[runtime]
default = "stub-http.stub-model"

[providers.stub-http]
display-name = "Stub HTTP"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[providers.claude_code]
display-name = "Claude Code Max Subscription"
protocol = "claude-code"
command = %S
is-non-interactive = true

[models.stub-model]
api-name = "gpt-5.4"
max-context = 200000
tools-support = true
streaming = true

[stub-http.stub-model]

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true
turn-timeout-s = 0

[claude_code."claude-sonnet-5"]
|} claude_cli
;;

let official_client_runtime = "claude_code.claude-sonnet-5"
let agent_core_runtime = "stub-http.stub-model"

let write_file ~path ~perm contents =
  let channel = open_out_gen [ Open_creat; Open_trunc; Open_wronly ] perm path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents)
;;

let with_runtime f =
  let path = Filename.temp_file "lane-cli-oneshot" ".toml" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       write_file ~path ~perm:0o600 (fixture ());
       match Runtime.init_default ~config_path:path with
       | Error detail -> failf "fixture runtime must initialize: %s" detail
       | Ok () -> f ())
;;

let requirement =
  Exact_output.make_output_requirement
    ~schema:
      (`Assoc
          [ "type", `String "object"
          ; "properties", `Assoc [ "verdict", `Assoc [ "type", `String "string" ] ]
          ; "required", `List [ `String "verdict" ]
          ])
    ~minimum_guarantee:Exact_output.Json_syntax
;;

let run ?runner ~runtime_id () =
  Cli_oneshot.run
    ?runner
    ~base_dir:"/tmp"
    ~runtime_id
    ~system_prompt:"You judge."
    ~requirement
    ~prompt:"Judge this."
    ()
;;

let unreachable_runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt:_ =
  failf "the runner must not run for %s" runtime_id
;;

let test_non_official_ids_are_refused_before_the_runner () =
  with_runtime (fun () ->
    (* An id no runtime.toml binding declares at all: [Runtime.get_runtime_by_id]
       answers [None], so this is a distinct, correctly-labeled case from a
       binding that resolves but is not an official client (below). Before
       runtime.ml validated every exact-output lane's cli_slots at load
       (#38983-class defect), both cases answered the same
       "is not an official-client runtime" message, which sent an operator
       chasing a client-configuration problem that was actually a typo. *)
    (match run ~runner:unreachable_runner ~runtime_id:"nope.not-configured" () with
     | Error (Cli_oneshot.Unknown_runtime { runtime_id }) ->
       check string "unknown id is named" "nope.not-configured" runtime_id
     | Ok _ | Error _ -> fail "an unknown id must be refused as unconfigured");
    match run ~runner:unreachable_runner ~runtime_id:agent_core_runtime () with
    | Error (Cli_oneshot.Not_an_official_client { runtime_id }) ->
      check string "http binding is named" agent_core_runtime runtime_id
    | Ok _ | Error _ -> fail "an HTTP binding must be refused as non-official")
;;

let test_prompt_carries_the_exact_agent_core_schema_sentence () =
  with_runtime (fun () ->
    let seen_prompt = ref None in
    let runner ~runtime:_ ~system_prompt ~output_schema:_ ~prompt =
      check string "system prompt passes through" "You judge." system_prompt;
      seen_prompt := Some prompt;
      Ok {|{"verdict":"pass"}|}
    in
    match run ~runner ~runtime_id:official_client_runtime () with
    | Error failure -> failf "must succeed: %s" (Cli_oneshot.failure_to_string failure)
    | Ok value ->
      check string "answer is the parsed JSON" {|{"verdict":"pass"}|}
        (Yojson.Safe.to_string value);
      (match !seen_prompt with
       | None -> fail "the runner never saw a prompt"
       | Some prompt ->
         let instruction = Exact_output.schema_instruction_text requirement in
         let suffix_matches =
           String.length prompt >= String.length instruction
           && String.equal
                (String.sub
                   prompt
                   (String.length prompt - String.length instruction)
                   (String.length instruction))
                instruction
         in
         check bool "prompt ends with the Agent Core instruction" true suffix_matches))
;;

(* The transport carries the schema now, not only the sentence. The Claude and
   Antigravity CLIs both take it on the command line and validate their own
   answer against it, so handing them a local copy that could drift from the
   caller's requirement would be the whole point missed. *)
let test_the_runner_receives_the_callers_own_schema () =
  with_runtime (fun () ->
    let seen_schema = ref None in
    let runner ~runtime:_ ~system_prompt:_ ~output_schema ~prompt:_ =
      seen_schema := Some output_schema;
      Ok {|{"verdict":"pass"}|}
    in
    match run ~runner ~runtime_id:official_client_runtime () with
    | Error failure -> failf "must succeed: %s" (Cli_oneshot.failure_to_string failure)
    | Ok _ ->
      (match !seen_schema with
       | None -> fail "the runner never saw a schema"
       | Some schema ->
         check
           string
           "the schema is the requirement's own, byte for byte"
           (Yojson.Safe.to_string (Exact_output.domain_schema requirement))
           (Yojson.Safe.to_string schema)))
;;

(* Both channels, not one instead of the other: the flag refuses what does not
   match, the sentence says what to write. llama.cpp documents that a schema
   handed to a grammar is never shown to the model, and the two CLIs re-prompt
   on a mismatch -- a model that was told the shape needs fewer rounds. *)
let test_the_prompt_keeps_its_instruction_alongside_the_schema () =
  with_runtime (fun () ->
    let both = ref None in
    let runner ~runtime:_ ~system_prompt:_ ~output_schema ~prompt =
      both := Some (output_schema, prompt);
      Ok {|{"verdict":"pass"}|}
    in
    match run ~runner ~runtime_id:official_client_runtime () with
    | Error failure -> failf "must succeed: %s" (Cli_oneshot.failure_to_string failure)
    | Ok _ ->
      (match !both with
       | None -> fail "the runner never ran"
       | Some (schema, prompt) ->
         check bool "the schema channel is populated" true (schema <> `Null);
         let instruction = Exact_output.schema_instruction_text requirement in
         check
           bool
           "and the prompt still carries the instruction"
           true
           (String.length prompt >= String.length instruction)))
;;

let test_a_fenced_answer_is_invalid_output_not_repaired () =
  with_runtime (fun () ->
    let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
      Ok "```json\n{\"verdict\":\"pass\"}\n```"
    in
    match run ~runner ~runtime_id:official_client_runtime () with
    | Error (Cli_oneshot.Invalid_json_output { runtime_id; _ }) ->
      check string "the failing slot is named" official_client_runtime runtime_id
    | Ok _ -> fail "a fenced answer must not parse"
    | Error failure ->
      failf "wrong failure class: %s" (Cli_oneshot.failure_to_string failure))
;;

let test_observer_retains_rejected_raw_output () =
  with_runtime (fun () ->
    List.iter (fun text ->
      let seen = ref [] in
      let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ = Ok text in
      let result = Cli_oneshot.walk ~runner ~observe:(fun event -> seen := event :: !seen)
        ~base_dir:"/tmp" ~cli_slots:[official_client_runtime] ~system_prompt:"" ~requirement
        ~prompt:"Judge this." ~validate:(fun _ -> Error "rejected by domain") ~on_failure:(fun _ -> ()) () in
      check bool "response is still rejected" true (Result.is_error result);
      match List.rev !seen with
      | [Cli_oneshot.Dispatching dispatch; Cli_oneshot.Raw_response response] ->
        check string "only admitted runtime dispatched" official_client_runtime dispatch.runtime_id;
        check string "response names its own runtime" official_client_runtime response.runtime_id;
        check string "raw output survives both syntax and semantic rejection" text response.text
      | _ -> fail "dispatch and raw response observations missing")
      ["not JSON"; {|{"verdict":"unrelated"}|}])
;;

let test_walk_advances_and_keeps_every_failure_in_order () =
  with_runtime (fun () ->
    let runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema:_ ~prompt:_ =
      if String.equal runtime_id official_client_runtime
      then Ok {|{"verdict":"pass"}|}
      else Error (Masc.Fusion_official_client.Setup_failure "spawn failed")
    in
    (* Both ids classify as official clients only when configured; the walk
       still records the refusal of the unknown one and advances. *)
    let observed = ref [] in
    match
      Cli_oneshot.walk ~validate:Result.ok ~on_failure:(fun failure -> observed := !observed @ [failure])
        ~runner
        ~base_dir:"/tmp"
        ~cli_slots:[ "nope.not-configured"; official_client_runtime ]
        ~system_prompt:""
        ~requirement
        ~prompt:"Judge this."
        ()
    with
    | Error failures ->
      failf
        "the walk must land on the second slot: %s"
        (String.concat "; " (List.map Cli_oneshot.failure_to_string failures))
    | Ok (runtime_id, value) ->
      (match !observed with
       | [Cli_oneshot.Unknown_runtime { runtime_id = rejected_id }] ->
         check string "prior rejection is observed before success" "nope.not-configured" rejected_id
       | _ -> fail "success must retain one prior refusal observation");
      check string "second slot answered" official_client_runtime runtime_id;
      check string "value parsed" {|{"verdict":"pass"}|} (Yojson.Safe.to_string value))
;;

let test_walk_exhaustion_returns_every_failure () =
  with_runtime (fun () ->
    let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ = Error (Masc.Fusion_official_client.Setup_failure "quota") in
    match
      Cli_oneshot.walk ~validate:Result.ok ~on_failure:ignore
        ~runner
        ~base_dir:"/tmp"
        ~cli_slots:[ official_client_runtime; "nope.not-configured" ]
        ~system_prompt:""
        ~requirement
        ~prompt:"Judge this."
        ()
    with
    | Ok _ -> fail "every slot must fail"
    | Error [ first; second ] ->
      (match first, second with
       | ( Cli_oneshot.Execution_failed { runtime_id = first_id; cause }
         , Cli_oneshot.Unknown_runtime { runtime_id = second_id } ) ->
         check string "first failure is the runner's" official_client_runtime first_id;
         check bool "runner cause is kept" true
           (cause = Masc.Fusion_official_client.Setup_failure "quota");
         check string "second failure is the refusal" "nope.not-configured" second_id
       | _ -> fail "failures must keep walk order and class")
    | Error failures -> failf "expected two failures, got %d" (List.length failures))
;;

let test_an_empty_walk_is_an_empty_error () =
  with_runtime (fun () ->
    match
      Cli_oneshot.walk ~validate:Result.ok ~on_failure:ignore
        ~runner:unreachable_runner
        ~base_dir:"/tmp"
        ~cli_slots:[]
        ~system_prompt:""
        ~requirement
        ~prompt:"Judge this."
        ()
    with
    | Error [] -> ()
    | Ok _ | Error _ -> fail "no declared slots means an empty exhaustion")
;;

(* MSP names no quota kind, so even a failure the host calls retryable is not
   the account resting: the board-attention worker must not wait on it. *)
let test_a_muse_failure_is_never_a_binding_rest () =
  let failed cause =
    Cli_oneshot.Execution_failed
      { runtime_id = "muse_code.muse-code-spark-1-3"
      ; cause = Masc.Fusion_official_client.Muse_failure cause
      }
  in
  List.iter
    (fun (label, cause) ->
       check bool label false (Cli_oneshot.refused_for_binding_rest (failed cause)))
    [ ( "retryable model error"
      , Runtime_muse_serve.Turn_failed
          { Runtime_muse_msp.kind = Runtime_muse_msp.Model_error
          ; message = "overloaded"
          ; retryable = true
          } )
    ; "auth required", Runtime_muse_serve.Auth_required "login expired"
    ; ( "workspace mismatch"
      , Runtime_muse_serve.Session_workspace_mismatch
          { requested = "/selected/workspace"; reported = Some "/different/workspace" } )
    ; ( "approval mode mismatch"
      , Runtime_muse_serve.Session_approval_mode_mismatch
          { requested = Runtime_muse_msp.Prompt_unmatched
          ; reported = Some Runtime_muse_msp.Allow_all } )
    ; ( "turn timeout"
      , Runtime_muse_serve.Timeout { seconds = 30.0; turn_accepted = true } )
    ]
;;

(* These fixtures drive the actual Claude stream adapter and Antigravity
   result adapter through the default runner. A string-only runner cannot
   prove that a typed provider rejection reaches the shared quota table. *)
let shell_quote text =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' text) ^ "'"
;;

let a1 = official_client_runtime
let a2 = "claude_code.claude-opus-5-5"
let b = "agy.gemini"
let c = "codex.codex-fixture"

let quota_fixture ~claude_cli ~agy_cli ~codex_cli ~oauth_source =
  let base = fixture ~claude_cli () in
  base ^ Printf.sprintf {|
[models."claude-opus-5-5"]
api-name = "claude-opus-5-5"
max-context = 1000000
[claude_code."claude-opus-5-5"]
[providers.agy]
protocol = "antigravity-cli"
command = %S
is-non-interactive = true
timeout-s = 10.0
credentials = { type = "file", path = %S }
[models.gemini]
api-name = "gemini-fixture"
max-context = 128000
[agy.gemini]
[providers.codex]
protocol = "codex-app-server"
command = %S
is-non-interactive = true
[models.codex-fixture]
api-name = "gpt-fixture"
max-context = 400000
[codex.codex-fixture]
|} agy_cli oauth_source codex_cli
;;

let scope runtime_id =
  match Runtime.quota_scope_of_runtime_id runtime_id with
  | Some scope -> scope
  | None -> failf "missing fixture scope %s" runtime_id
;;

let claude_script ~marker ~body =
  Printf.sprintf {|#!/bin/sh
set -eu
# The client puts its flags ahead of the subcommand, so the probe arrives as
# `--setting-sources= auth status --json`. Matching the subcommand pair
# anywhere in argv keeps this answering the probe when a flag is added or
# moved; pinning a position sends the probe into the turn body below, which
# answers it with turn output and records a marker line for a call that never
# asked for one.
case " $@ " in
  *" auth status "*)
    printf '%%s\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"team","apiProvider":"firstParty"}'
    exit 0
    ;;
esac
session=''
model=''
previous=''
for arg in "$@"; do
  if [ "$previous" = --model ]; then model=$arg; fi
  previous=$arg
  case "$arg" in
    --session-id=*) session=${arg#--session-id=} ;;
    --model=*) model=${arg#--model=} ;;
  esac
done
printf '%%s\n' "A:$model" >> %s
emit() { printf '%%s\n' "$1" | sed "s/__SESSION__/$session/g; s/__MODEL__/$model/g"; }
IFS= read -r initialize
request_id=$(printf '%%s' "$initialize" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
printf '{"type":"control_response","response":{"subtype":"success","request_id":"%%s","response":{}}}\n' "$request_id"
IFS= read -r user_message
%s
while IFS= read -r ignored; do :; done
|} (shell_quote marker) body
;;

let rejection ?resets_at () =
  let rate_limit_info =
    [ "status", `String "rejected"; "rateLimitType", `String "seven_day" ]
    @ (match resets_at with None -> [] | Some at -> [ "resetsAt", `Int at ])
  in
  "emit " ^ shell_quote (Yojson.Safe.to_string
    (`Assoc [ "type", `String "rate_limit_event";
              "session_id", `String "__SESSION__";
              "rate_limit_info", `Assoc rate_limit_info ]))
  ^ "\nemit " ^ shell_quote
    {|{"type":"result","subtype":"success","is_error":true,"session_id":"__SESSION__","uuid":"quota-result","result":"quota diagnostic","api_error_status":429,"terminal_reason":"api_error"}|}
;;

let claude_answer answer =
  let emit frame = "emit " ^ shell_quote (Yojson.Safe.to_string frame) in
  (* The adapter requires a measured assistant model before a successful
     result can complete. The script fills it from the actual --model argv. *)
  emit
    (`Assoc
       [ "type", `String "assistant"
       ; "parent_tool_use_id", `Null
       ; "session_id", `String "__SESSION__"
       ; "uuid", `String "answer-assistant"
       ; "message", `Assoc
           [ "role", `String "assistant"
           ; "model", `String "__MODEL__"
           ; "content", `List [`Assoc ["type", `String "text"; "text", `String answer]]
           ]
       ])
  ^ "\n" ^ emit
    (`Assoc [ "type", `String "result"; "subtype", `String "success";
              "is_error", `Bool false; "session_id", `String "__SESSION__";
              "uuid", `String "answer-result"; "result", `String answer ])
;;

(* A stand-in for the Codex app-server: it answers the handshake, accepts
   turn/start, then ends the turn with [terminal]. The request order is the
   client's (initialize, initialized, account/read, thread/start, turn/start);
   the replies are the ones test_runtime_codex_app_server.ml drives the same
   client with. *)
let codex_script ~marker ~terminal =
  let reply line = "printf '%s\\n' " ^ shell_quote line in
  String.concat "\n"
    [ "#!/bin/sh"
    ; "set -eu"
    ; "printf 'C\\n' >> " ^ shell_quote marker
    ; "IFS= read -r request"
    ; reply
        {|{"id":1,"result":{"userAgent":"fixture/0.147.0","codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"linux"}}|}
    ; "IFS= read -r request"
    ; "IFS= read -r request"
    ; reply
        {|{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.test","planType":"pro"},"requiresOpenaiAuth":true}}|}
    ; "IFS= read -r request"
    ; reply {|{"id":3,"result":{"thread":{"id":"thread-1"},"model":"gpt-fixture"}}|}
    ; "IFS= read -r request"
    ; reply {|{"id":4,"result":{"turn":{"id":"turn-1"}}}|}
    ; reply terminal
    ; "while IFS= read -r ignored; do :; done"
    ; ""
    ]
;;

(* The weekly limit, as the app-server reports it: a terminal [error] whose
   [codexErrorInfo] is [usageLimitExceeded]. The reset time is only in the
   message text. *)
let codex_usage_limit =
  {|{"method":"error","params":{"threadId":"thread-1","turnId":"turn-1","willRetry":false,"error":{"message":"You've hit your usage limit. Try again at Sep 26th, 2026 5:33 PM.","codexErrorInfo":"usageLimitExceeded","additionalDetails":null}}}|}
;;

(* A failed turn that names no cause. *)
let codex_turn_failed =
  {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"fixture provider rejection"}}}}|}
;;

let with_quota_fixture f =
  let dir = Filename.temp_dir "cli-quota-adapter" "" |> Unix.realpath in
  let path name = Filename.concat dir name in
  let marker = path "calls" in
  let claude_cli = path "claude" in
  let agy_cli = path "agy" in
  let codex_cli = path "codex" in
  let oauth_source = path "oauth.json" in
  let config_path = path "runtime.toml" in
  let load_config text =
    write_file ~path:config_path ~perm:0o600 text;
    match Runtime.init_default ~config_path with
    | Ok () -> ()
    | Error detail -> failf "quota fixture must initialize: %s" detail
  in
  Fun.protect
    ~finally:(fun () ->
      Runtime_quota_window.reset_for_testing ();
      Fs_compat.remove_tree dir)
    (fun () ->
      Runtime_quota_window.reset_for_testing ();
      write_file ~path:marker ~perm:0o600 "";
      write_file ~path:oauth_source ~perm:0o600 (Masc_test_deps.antigravity_oauth_fixture "quota-fixture");
      write_file ~path:claude_cli ~perm:0o700 (claude_script ~marker ~body:(rejection ()));
      write_file ~path:agy_cli ~perm:0o700
        (Printf.sprintf {|#!/usr/bin/env python3
import json
import os
import sys

sys.stdin.read()
with open(%s, "a") as calls:
    calls.write("B\n")
print(json.dumps({"event": "init", "conversation_id": "quota-b", "init": {
    "model": "gemini-fixture", "cwd": os.getcwd(), "tools": [],
    "permission_mode": "always-proceed"}}), flush=True)
print(json.dumps({"event": "result", "result": {"conversation_id": "quota-b",
    "status": "SUCCESS", "response": "{\"verdict\":\"pass\"}", "num_turns": 1,
    "usage": {"input_tokens": 100, "output_tokens": 7, "thinking_tokens": 3,
              "cache_read_tokens": 50, "total_tokens": 107}}}), flush=True)
|} (Yojson.Safe.to_string (`String marker)));
      write_file ~path:codex_cli ~perm:0o700 (codex_script ~marker ~terminal:codex_usage_limit);
      let catalog = quota_fixture ~claude_cli ~agy_cli ~codex_cli ~oauth_source in
      load_config catalog;
      Eio_main.run (fun env ->
        Eio_context.set_env env;
        Eio.Switch.run (fun sw ->
          Eio_context.with_test_env
            ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
            ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
            (fun () -> f ~dir ~path ~marker ~claude_cli ~load_config ~env))))
;;

let calls marker =
  let ch = open_in marker in
  Fun.protect ~finally:(fun () -> close_in ch) (fun () ->
    let rec read acc =
      match input_line ch with
      | line -> read (line :: acc)
      | exception End_of_file -> List.rev acc
    in read [])
;;

let walk_real ~dir slots =
  Cli_oneshot.walk ~validate:Result.ok ~on_failure:ignore ~base_dir:dir ~cli_slots:slots ~system_prompt:""
    ~requirement ~prompt:"Judge this." ()
;;

(* Antigravity takes a schema-bound answer only as the arguments of its
   [finish] tool. Told to return a JSON value the model writes one, the CLI
   refuses it, and the whole prompt goes out a second time. *)
let test_an_antigravity_slot_is_told_to_answer_through_finish () =
  with_quota_fixture (fun ~dir:_ ~path:_ ~marker:_ ~claude_cli:_ ~load_config:_ ~env:_ ->
    let prompt_for runtime_id =
      let seen = ref None in
      let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt =
        seen := Some prompt;
        Ok {|{"verdict":"pass"}|}
      in
      match run ~runner ~runtime_id () with
      | Error failure -> failf "must succeed: %s" (Cli_oneshot.failure_to_string failure)
      | Ok _ ->
        (match !seen with
         | Some prompt -> prompt
         | None -> fail "the runner never saw a prompt")
    in
    let written = Exact_output.schema_instruction_text requirement in
    let schema = Exact_output.domain_schema requirement in
    let through_finish = Runtime_antigravity.structured_output_instruction ~schema in
    let antigravity = prompt_for b in
    check bool "an Antigravity slot ends with the finish-tool sentence" true
      (String.ends_with ~suffix:through_finish antigravity);
    check bool "and is not told to write the value" false
      (String.ends_with ~suffix:written antigravity);
    check bool "the sentence ends with the schema the flag carries" true
      (String.ends_with ~suffix:(Yojson.Safe.to_string schema) through_finish);
    check bool "and differs from the sentence for a written value" false
      (String.equal through_finish written);
    List.iter
      (fun runtime_id ->
         check bool (runtime_id ^ " keeps the Agent Core sentence") true
           (String.ends_with ~suffix:written (prompt_for runtime_id)))
      [ a1; c ])
;;

let test_real_quota_reorders_siblings_and_next_walk () =
  with_quota_fixture (fun ~dir ~path:_ ~marker ~claude_cli:_ ~load_config:_ ~env:_ ->
    let require_b = function
      | Ok (runtime_id, _) -> check string "other account answered" b runtime_id
      | Error failures -> failf "walk failed: %s"
          (String.concat "; " (List.map Cli_oneshot.failure_to_string failures))
    in
    walk_real ~dir [a1; a2; b] |> require_b;
    check (list string) "new rejection advances to B before sibling" ["A:claude-sonnet-5"; "B"] (calls marker);
    check bool "sibling shares observed quota" true
      (Runtime_quota_window.is_exhausted ~scope:(scope a2) ~now:(Time_compat.now ()));
    walk_real ~dir [a1; a2; b] |> require_b;
    check (list string) "next request begins with B" ["A:claude-sonnet-5"; "B"; "B"] (calls marker);
    match walk_real ~dir [a1; a2] with
    | Ok _ -> fail "both exhausted siblings must fail"
    | Error failures ->
      check int "exhausted candidates remain eligible" 2 (List.length failures);
      check (list string) "same-account tail retains declaration order"
        ["A:claude-sonnet-5"; "B"; "B"; "A:claude-sonnet-5"; "A:claude-opus-5-5"] (calls marker);
      Runtime_quota_window.note_observed_exhausted ~scope:(scope b);
      write_file ~path:marker ~perm:0o600 "";
      walk_real ~dir [a1; a2; b] |> require_b;
      check (list string) "all scopes exhausted still try every declared candidate"
        ["A:claude-sonnet-5"; "A:claude-opus-5-5"; "B"] (calls marker);
      check bool "separate adapter success clears its observation" false
        (Runtime_quota_window.is_exhausted ~scope:(scope b) ~now:(Time_compat.now ())))
;;

let test_provider_reset_and_success_before_json_validation () =
  with_quota_fixture (fun ~dir ~path:_ ~marker ~claude_cli ~load_config:_ ~env:_ ->
    let account = scope a1 in
    write_file ~path:claude_cli ~perm:0o700
      (claude_script ~marker ~body:("emit " ^ shell_quote
        {|{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"__SESSION__","uuid":"execution-error-result","result":"quota diagnostic words without a typed quota"}|}));
    ignore (walk_real ~dir [a1]);
    check bool "ordinary execution errors do not invent quota evidence" false
      (Runtime_quota_window.is_exhausted ~scope:account ~now:(Time_compat.now ()));
    (* Absolute reset, deliberately beyond the fixture's execution time. *)
    let resets_at = int_of_float (Time_compat.now ()) + 3600 in
    write_file ~path:claude_cli ~perm:0o700
      (claude_script ~marker ~body:(rejection ~resets_at ()));
    ignore (walk_real ~dir [a1]);
    check (option (float 0.0)) "provider absolute reset retained"
      (Some (float_of_int resets_at))
      (Runtime_quota_window.active_until ~scope:account ~now:(Time_compat.now ()));
    write_file ~path:claude_cli ~perm:0o700
      (claude_script ~marker ~body:(claude_answer "not JSON"));
    (match walk_real ~dir [a1] with
     | Error [Cli_oneshot.Invalid_json_output _] -> ()
     | _ -> fail "transport success must still fail strict domain JSON parsing");
    check bool "success does not erase provider-stated window" true
      (Runtime_quota_window.is_exhausted ~scope:account ~now:(Time_compat.now ()));
    Runtime_quota_window.reset_for_testing ();
    Runtime_quota_window.note_observed_exhausted ~scope:account;
    ignore (walk_real ~dir [a1]);
    check bool "transport success clears observation despite invalid JSON" false
      (Runtime_quota_window.is_exhausted ~scope:account ~now:(Time_compat.now ())))
;;

(* A Codex account out of usage must leave the same record a Claude quota
   refusal leaves, or every exact-lane walk sends its next judgment to the
   spent account first (2026-09-25: 3,135 and 739 usageLimitExceeded
   refusals on two Codex slots). On main the one-shot path recorded nothing:
   the account was not exhausted after the refusal, and the second walk
   began with C again. *)
let test_codex_usage_limit_is_read_by_the_next_walk () =
  with_quota_fixture (fun ~dir ~path ~marker ~claude_cli:_ ~load_config:_ ~env:_ ->
    let codex_cli = path "codex" in
    let account = scope c in
    let require_b = function
      | Ok (runtime_id, _) -> check string "the other account answered" b runtime_id
      | Error failures -> failf "walk failed: %s"
          (String.concat "; " (List.map Cli_oneshot.failure_to_string failures))
    in
    write_file ~path:codex_cli ~perm:0o700
      (codex_script ~marker ~terminal:codex_turn_failed);
    (match walk_real ~dir [c] with
     | Error [Cli_oneshot.Execution_failed { runtime_id; _ }] ->
       check string "the Codex slot failed" c runtime_id
     | Ok _ | Error _ -> fail "a failed Codex turn must fail its only slot");
    check bool "a Codex failure that names no spent usage records no quota" false
      (Runtime_quota_window.is_exhausted ~scope:account ~now:(Time_compat.now ()));
    write_file ~path:codex_cli ~perm:0o700
      (codex_script ~marker ~terminal:codex_usage_limit);
    write_file ~path:marker ~perm:0o600 "";
    walk_real ~dir [c; b] |> require_b;
    check (list string) "the spent account was asked, then the next slot" ["C"; "B"]
      (calls marker);
    check bool "the usage-limit refusal is recorded for the Codex account" true
      (Runtime_quota_window.is_exhausted ~scope:account ~now:(Time_compat.now ()));
    check (option (float 0.0)) "the refusal states no typed reset, so none is invented" None
      (Runtime_quota_window.active_until ~scope:account ~now:(Time_compat.now ()));
    walk_real ~dir [c; b] |> require_b;
    check (list string) "the next walk begins with the account that can answer"
      ["C"; "B"; "B"] (calls marker))
;;

let runtime_exn id =
  match Runtime.get_runtime_by_id id with
  | Some runtime -> runtime
  | None -> failf "missing fixture runtime %s" id
;;

let candidate_state runtime =
  Runtime_candidate_backpressure.candidate_backpressure ~now:(Time_compat.now ())
    ~candidate:runtime.Runtime_instance.candidate_backpressure
;;

let seed_candidate runtime =
  let candidate = runtime.Runtime_instance.candidate_backpressure in
  Runtime_candidate_backpressure.note_rate_limit ~candidate ~retry_after:(Some 3600.);
  Runtime_candidate_backpressure.note_failed_attempt ~candidate
    ~failure:Runtime_candidate_backpressure.Network_transient
    ~recorded_by:(Runtime_candidate_backpressure.keeper_recorder ~keeper_name:"fixture-owner")
;;

let codex_error_terminal info =
  Yojson.Safe.to_string
    (`Assoc ["method", `String "error"; "params", `Assoc
      ["threadId", `String "thread-1"; "turnId", `String "turn-1";
       "willRetry", `Bool false; "error", `Assoc
         ["message", `String "fixture refusal"; "codexErrorInfo", `String info;
          "additionalDetails", `Null]]])
;;

let test_preseeded_rate_dispatches_other_cli_candidate () =
  with_quota_fixture (fun ~dir ~path:_ ~marker ~claude_cli:_ ~load_config:_ ~env:_ ->
    let original = runtime_exn a1 in
    Runtime_candidate_backpressure.note_rate_limit
      ~candidate:original.candidate_backpressure ~retry_after:(Some 3600.);
    (match walk_real ~dir [a1; b] with
     | Ok (id, _) -> check string "unrested actual adapter dispatched first" b id
     | Error _ -> fail "unrested adapter must answer");
    check (list string) "A never dispatched" ["B"] (calls marker);
    check bool "B answer does not clear A" true (Option.is_some (candidate_state original));
    check (list string) "unknown declared identity survives ordering"
      ["missing.runtime"; b; a1] (Cli_oneshot.order_slots [a1; "missing.runtime"; b]))
;;

let test_real_rate_is_candidate_only_across_walks () =
  with_quota_fixture (fun ~dir ~path ~marker ~claude_cli:_ ~load_config:_ ~env:_ ->
    let runtime = runtime_exn c in
    let codex_cli = path "codex" in
    write_file ~path:codex_cli ~perm:0o700
      (codex_script ~marker ~terminal:(codex_error_terminal "rateLimitExceeded"));
    let require_b = function
      | Ok (id, _) -> check string "other candidate answered" b id
      | Error _ -> fail "other candidate must answer" in
    walk_real ~dir [c; b] |> require_b;
    (match candidate_state runtime with
     | Some {Runtime_candidate_backpressure.rate_limit=Some _; failed_attempt=None} -> ()
     | Some _ | None -> fail "typed rate must record candidate rate only");
    check bool "coarse rate does not exhaust shared account" false
      (Runtime_quota_window.is_exhausted ~scope:(scope c) ~now:(Time_compat.now ()));
    walk_real ~dir [c; b] |> require_b;
    check (list string) "a separate walk sees actual adapter refusal" ["C"; "B"; "B"] (calls marker);
    Runtime_candidate_backpressure.note_candidate_success ~candidate:runtime.candidate_backpressure;
    write_file ~path:codex_cli ~perm:0o700
      (codex_script ~marker ~terminal:(codex_error_terminal "serverOverloaded"));
    ignore (walk_real ~dir [c]);
    check bool "overload creates no ownerless failure or rate" true
      (Option.is_none (candidate_state runtime));
    let recorder = Runtime_candidate_backpressure.keeper_recorder ~keeper_name:"existing-walk" in
    Runtime_candidate_backpressure.note_failed_attempt ~candidate:runtime.candidate_backpressure
      ~failure:Runtime_candidate_backpressure.Network_transient ~recorded_by:recorder;
    ignore (walk_real ~dir [c]);
    match candidate_state runtime with
    | Some {Runtime_candidate_backpressure.rate_limit=None;
            failed_attempt=Some (Runtime_candidate_backpressure.Failed_attempt {recorded_by; _})} ->
      check bool "ownerless overload preserves existing failure owner" true
        (Runtime_candidate_backpressure.same_recorder recorder recorded_by)
    | Some _ | None -> fail "existing owner observation must survive ownerless overload")
;;

let test_dispatch_observer_keeps_actual_runtime () =
  with_quota_fixture (fun ~dir ~path ~marker ~claude_cli:_ ~load_config ~env:_ ->
    let original = runtime_exn a1 in
    let replacement_cli = path "replacement-claude" in
    write_file ~path:replacement_cli ~perm:0o700
      (claude_script ~marker ~body:(claude_answer {|{"replacement":true}|}));
    let observe = function
      | Cli_oneshot.Dispatching _ -> load_config (fixture ~claude_cli:replacement_cli ())
      | Cli_oneshot.Raw_response _ -> () in
    (match Cli_oneshot.run ~observe ~base_dir:dir ~runtime_id:a1 ~system_prompt:""
       ~requirement ~prompt:"Judge this." () with
     | Error (Cli_oneshot.Execution_failed {cause=Masc.Fusion_official_client.Claude_failure
         (Runtime_claude_code.Quota_blocked _); _}) -> ()
     | Error _ | Ok _ -> fail "default transport must execute the admitted original runtime");
    let replacement = runtime_exn a1 in
    check bool "rebind made a new candidate" false
      (original.candidate_backpressure == replacement.candidate_backpressure);
    check (list string) "only the original rejecting adapter ran" ["A:claude-sonnet-5"] (calls marker))
;;

let test_rate_observation_stays_on_dispatch_snapshot () =
  with_quota_fixture (fun ~dir ~path ~marker ~claude_cli ~load_config ~env:_ ->
    let original = runtime_exn c in
    write_file ~path:(path "codex") ~perm:0o700
      (codex_script ~marker ~terminal:(codex_error_terminal "rateLimitExceeded"));
    let replacement_cli = path "replacement-codex" in
    let observe = function
      | Cli_oneshot.Dispatching _ ->
        load_config (quota_fixture ~claude_cli ~agy_cli:(path "agy")
          ~codex_cli:replacement_cli ~oauth_source:(path "oauth.json"))
      | Cli_oneshot.Raw_response _ -> () in
    (match Cli_oneshot.run ~observe ~base_dir:dir ~runtime_id:c ~system_prompt:""
       ~requirement ~prompt:"Judge this." () with
     | Error (Cli_oneshot.Execution_failed _) -> ()
     | Error _ | Ok _ -> fail "original rate-refused adapter must fail its turn");
    let replacement = runtime_exn c in
    check bool "rebind has another candidate cell" false
      (original.candidate_backpressure == replacement.candidate_backpressure);
    (match candidate_state original with
     | Some {Runtime_candidate_backpressure.rate_limit=Some _; failed_attempt=None} -> ()
     | Some _ | None -> fail "rate observation must stay on original candidate");
    check bool "replacement never receives original refusal" true
      (Option.is_none (candidate_state replacement));
    check (list string) "original Codex adapter actually ran" ["C"] (calls marker))
;;

let test_success_observation_precedes_usage_rebind_and_json () =
  with_quota_fixture (fun ~dir ~path ~marker ~claude_cli ~load_config ~env:_ ->
    let original = runtime_exn a1 in
    let original_scope = Runtime_instance.quota_scope_of_runtime original in
    seed_candidate original;
    Runtime_quota_window.note_observed_exhausted ~scope:original_scope;
    write_file ~path:claude_cli ~perm:0o700 (claude_script ~marker ~body:(claude_answer "not JSON"));
    (match walk_real ~dir [a1] with
     | Error [Cli_oneshot.Invalid_json_output _] -> ()
     | Ok _ | Error _ -> fail "actual answer must reach strict JSON rejection");
    check bool "transport answer clears candidate despite JSON rejection" true
      (Option.is_none (candidate_state original));
    seed_candidate original;
    Runtime_quota_window.note_observed_exhausted ~scope:original_scope;
    let replacement_cli = path "replacement-claude" in
    let callbacks = ref 0 in
    let on_usage _ =
      incr callbacks;
      check bool "answer clears original before final usage callback" true
        (Option.is_none (candidate_state original));
      check bool "undated quota clears before final usage callback" false
        (Runtime_quota_window.is_exhausted ~scope:original_scope ~now:(Time_compat.now ()));
      load_config (fixture ~claude_cli:replacement_cli ());
      seed_candidate (runtime_exn a1) in
    (match Masc.Fusion_official_client.run_with_images ~on_usage ~images:[]
       ~base_dir:dir ~runtime:original ~system_prompt:"" ~prompt:"Judge this." () with
     | Ok _ -> ()
     | Error error -> failf "original adapter failed: %s"
         (Masc.Fusion_official_client.failure_detail ~runtime_id:a1 error));
    check int "final usage observed once" 1 !callbacks;
    check bool "callback replacement keeps its own standing" true
      (Option.is_some (candidate_state (runtime_exn a1)));
    check bool "old candidate stays cleared" true (Option.is_none (candidate_state original)))
;;

let test_catalog_reload_does_not_move_inflight_quota () =
  with_quota_fixture (fun ~dir ~path ~marker ~claude_cli ~load_config ~env ->
    let account = scope a1 in
    let ready = path "ready" and proceed = path "proceed" in
    (* The process has consumed the request before the catalog is replaced.
       The handshake releases its result only after the reload completed. *)
    let body = Printf.sprintf "touch %s\nwhile [ ! -f %s ]; do sleep 0.01; done\n%s"
      (shell_quote ready) (shell_quote proceed) (rejection ()) in
    write_file ~path:claude_cli ~perm:0o700 (claude_script ~marker ~body);
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Fiber.both
        (fun () ->
          match walk_real ~dir [a1] with
          | Error [Cli_oneshot.Execution_failed _] -> ()
          | _ -> fail "in-flight adapter must report its quota rejection")
        (fun () ->
          let rec await_ready () =
            if not (Sys.file_exists ready) then (
              Eio.Time.sleep (Eio.Stdenv.clock env) 0.01;
              await_ready ())
          in
          await_ready ();
          load_config {|
[runtime]
default = "stub-http.stub-model"
[providers.stub-http]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"
[models.stub-model]
api-name = "gpt-5.4"
max-context = 200000
[stub-http.stub-model]
|};
          write_file ~path:proceed ~perm:0o600 ""));
    check bool "removed runtime cannot be resolved after reload" true
      (Option.is_none (Runtime.get_runtime_by_id a1));
    check bool "in-flight quota still belongs to captured account" true
      (Runtime_quota_window.is_exhausted ~scope:account ~now:(Time_compat.now ())))
;;

let refusal_testable =
  Alcotest.testable Runtime.pp_refusal Runtime.equal_refusal
;;

let sample_schema : Yojson.Safe.t =
  `Assoc [ "type", `String "object" ]
;;

let base_lane : Runtime.lane_requirement =
  { window = Runtime.Known_at_least { min_tokens = 32_768 }
  ; overflow = Runtime.Reject_before_truncation
  ; verdict = Runtime.Json_syntax { schema = sample_schema }
  ; tool_free = true
  ; fresh_invocation = true
  }
;;

let base_runtime : Runtime.runtime_capability =
  { context_window = Runtime.Window_known { max_input_tokens = 200_000 }
  ; overflow = Runtime.Rejects_oversize_input
  ; structured_output = Runtime.Flag_json_schema
  ; supports_tool_free = true
  ; supports_fresh_invocation = true
  }
;;

let test_admits_exhaustive_branches () =
  check
    (result unit refusal_testable)
    "capable runtime admitted"
    (Ok ())
    (Runtime.admits ~lane:base_lane ~runtime:base_runtime);
  check
    (result unit refusal_testable)
    "unbounded window lane accepts unknown runtime window"
    (Ok ())
    (Runtime.admits
       ~lane:{ base_lane with window = Runtime.Unbounded_or_unknown }
       ~runtime:{ base_runtime with context_window = Runtime.Window_unknown });
  check
    (result unit refusal_testable)
    "unknown window refused for bounded lane"
    (Error Runtime.Window_unknown_for_bounded_lane)
    (Runtime.admits
       ~lane:base_lane
       ~runtime:{ base_runtime with context_window = Runtime.Window_unknown });
  check
    (result unit refusal_testable)
    "window too small refused with required and actual"
    (Error (Runtime.Window_too_small { required = 32_768; actual = 16_384 }))
    (Runtime.admits
       ~lane:base_lane
       ~runtime:
         { base_runtime with
           context_window = Runtime.Window_known { max_input_tokens = 16_384 }
         });
  check
    (result unit refusal_testable)
    "silent truncation refused when lane requires reject before truncation"
    (Error Runtime.Silent_truncation_on_overflow)
    (Runtime.admits
       ~lane:base_lane
       ~runtime:{ base_runtime with overflow = Runtime.Truncates_silently });
  check
    (result unit refusal_testable)
    "caller-bounded overflow satisfies reject before truncation when window fits"
    (Ok ())
    (Runtime.admits
       ~lane:base_lane
       ~runtime:
         { base_runtime with
           overflow = Runtime.Caller_bounded { max_input_tokens = 64_000 }
         });
  check
    (result unit refusal_testable)
    "caller-bounded overflow too small refused"
    (Error (Runtime.Caller_bound_too_small { required = 32_768; actual = 8_192 }))
    (Runtime.admits
       ~lane:base_lane
       ~runtime:
         { base_runtime with
           overflow = Runtime.Caller_bounded { max_input_tokens = 8_192 }
         });
  check
    (result unit refusal_testable)
    "text-only refused for Json_syntax lane"
    (Error
       (Runtime.Structured_output_unsupported
          { required = `Json_syntax; actual = Runtime.Text_only }))
    (Runtime.admits
       ~lane:base_lane
       ~runtime:{ base_runtime with structured_output = Runtime.Text_only });
  check
    (result unit refusal_testable)
    "prompted JSON admitted for Json_syntax lane (Muse serve)"
    (Ok ())
    (Runtime.admits
       ~lane:base_lane
       ~runtime:{ base_runtime with structured_output = Runtime.Prompted_json });
  let strict_lane =
    { base_lane with
      verdict =
        Runtime.Provider_enforced_json_schema
          { name = "strict_verdict"; schema = sample_schema }
    }
  in
  check
    (result unit refusal_testable)
    "prompted JSON refused for Provider_enforced_json_schema lane"
    (Error
       (Runtime.Structured_output_unsupported
          { required = `Provider_enforced_json_schema
          ; actual = Runtime.Prompted_json
          }))
    (Runtime.admits
       ~lane:strict_lane
       ~runtime:{ base_runtime with structured_output = Runtime.Prompted_json });
  check
    (result unit refusal_testable)
    "flag json schema admitted for Provider_enforced_json_schema lane"
    (Ok ())
    (Runtime.admits
       ~lane:strict_lane
       ~runtime:{ base_runtime with structured_output = Runtime.Flag_json_schema });
  check
    (result unit refusal_testable)
    "http response_format json_schema admitted for Provider_enforced_json_schema lane"
    (Ok ())
    (Runtime.admits
       ~lane:strict_lane
       ~runtime:
         { base_runtime with
           structured_output = Runtime.Http_response_format_json_schema
         });
  check
    (result unit refusal_testable)
    "tool_free unsupported refused"
    (Error Runtime.Tool_free_unsupported)
    (Runtime.admits
       ~lane:base_lane
       ~runtime:{ base_runtime with supports_tool_free = false });
  check
    (result unit refusal_testable)
    "fresh_invocation unsupported refused"
    (Error Runtime.Fresh_invocation_unsupported)
    (Runtime.admits
       ~lane:base_lane
       ~runtime:{ base_runtime with supports_fresh_invocation = false })
;;

let test_partition_cli_slots_preserves_refused_slots_and_muse_output_schema () =
  let capabilities =
    [ "claude_code.sonnet", base_runtime
    ; ( "muse.local"
      , { base_runtime with structured_output = Runtime.Prompted_json } )
    ; ( "ollama.tiny"
      , { base_runtime with
          context_window = Runtime.Window_known { max_input_tokens = 4_096 }
        ; overflow = Runtime.Caller_bounded { max_input_tokens = 4_096 }
        ; structured_output = Runtime.Http_response_format_json_schema
        } )
    ]
  in
  let capability_of id = List.assoc_opt id capabilities in
  let json_syntax_partition =
    Cli_oneshot.partition_cli_slots
      ~lane:base_lane
      ~capability_of
      [ "claude_code.sonnet"; "muse.local"; "ollama.tiny"; "unknown.slot" ]
  in
  check
    (list string)
    "Json_syntax lane admits claude_code and muse.local"
    [ "claude_code.sonnet"; "muse.local" ]
    json_syntax_partition.cli_slots;
  (match json_syntax_partition.refused_cli_slots with
   | [ { slot = "ollama.tiny"; refusal = tiny_refusal }
     ; { slot = "unknown.slot"; refusal = unknown_refusal }
     ] ->
     check
       refusal_testable
       "tiny slot refused for window size"
       (Runtime.Window_too_small { required = 32_768; actual = 4_096 })
       tiny_refusal;
     check
       refusal_testable
       "unknown slot refused with Runtime_unknown"
       Runtime.Runtime_unknown
       unknown_refusal
   | _ -> fail "expected ollama.tiny and unknown.slot in refused_cli_slots");
  let strict_lane =
    { base_lane with
      verdict =
        Runtime.Provider_enforced_json_schema
          { name = "strict"; schema = sample_schema }
    }
  in
  let strict_partition =
    Cli_oneshot.partition_cli_slots
      ~lane:strict_lane
      ~capability_of
      [ "claude_code.sonnet"; "muse.local" ]
  in
  check
    (list string)
    "Provider_enforced_json_schema lane admits only claude_code"
    [ "claude_code.sonnet" ]
    strict_partition.cli_slots;
  (match strict_partition.refused_cli_slots with
   | [ { slot = "muse.local"; refusal } ] ->
     check
       refusal_testable
       "muse.local refused with Structured_output_unsupported"
       (Runtime.Structured_output_unsupported
          { required = `Provider_enforced_json_schema
          ; actual = Runtime.Prompted_json
          })
       refusal
   | _ -> fail "expected muse.local in refused_cli_slots");
  check
    (option string)
    "Muse_serve_runtime omits ?output_schema channel"
    None
    (Cli_oneshot.output_schema_for_api_format
       Runtime_schema.Muse_serve_runtime
       sample_schema
     |> Option.map Yojson.Safe.to_string);
  check
    (option string)
    "Claude_code_runtime passes ?output_schema channel"
    (Some (Yojson.Safe.to_string sample_schema))
    (Cli_oneshot.output_schema_for_api_format
       Runtime_schema.Claude_code_runtime
       sample_schema
     |> Option.map Yojson.Safe.to_string)
;;

let test_input_size_guard_and_refusal_classification () =
  (match
     Cli_oneshot.check_input_size
       ~estimated_tokens:50_000
       ~overflow:(Runtime.Caller_bounded { max_input_tokens = 32_768 })
   with
   | Error
       (Cli_oneshot.Input_over_limit
          { estimated_tokens; limit_tokens }) ->
     check int "estimated_tokens" 50_000 estimated_tokens;
     check int "limit_tokens" 32_768 limit_tokens
   | Ok () -> fail "oversize caller-bounded input must be refused");
  (match
     Cli_oneshot.check_input_size
       ~estimated_tokens:16_000
       ~overflow:(Runtime.Caller_bounded { max_input_tokens = 32_768 })
   with
   | Ok () -> ()
   | Error _ -> fail "in-bounds caller-bounded input must be accepted");
  let claude_ctx_failure =
    Cli_oneshot.Execution_failed
      { runtime_id = "claude_code.sonnet"
      ; cause =
          Masc.Fusion_official_client.Claude_failure
            (Runtime_claude_code.Context_window_exceeded
               { message = "prompt too long"
               ; tool_effect_attempted = false
               ; response_emitted = false
               })
      }
  in
  let codex_ctx_failure =
    Cli_oneshot.Execution_failed
      { runtime_id = "codex.gpt-5.4"
      ; cause =
          Masc.Fusion_official_client.Codex_failure
            (Runtime_codex_app_server.Context_window_exceeded
               { message = "context window exceeded"
               ; tool_effect_attempted = false
               })
      }
  in
  let non_size_failure =
    Cli_oneshot.Invalid_json_output
      { runtime_id = "claude_code.sonnet"; detail = "bad json" }
  in
  check
    bool
    "Claude Context_window_exceeded is refused_for_input_size"
    true
    (Cli_oneshot.refused_for_input_size claude_ctx_failure);
  check
    bool
    "Codex Context_window_exceeded is refused_for_input_size"
    true
    (Cli_oneshot.refused_for_input_size codex_ctx_failure);
  check
    bool
    "Invalid_json_output is not refused_for_input_size"
    false
    (Cli_oneshot.refused_for_input_size non_size_failure)
;;

let () =
  Alcotest.run
    "keeper_lane_cli_oneshot"
    [ ( "typed capability admission (Track 2A)"
      , [ test_case
            "Runtime.admits exhaustive branches"
            `Quick
            test_admits_exhaustive_branches
        ; test_case
            "partition_cli_slots preserves refused_cli_slots and Muse schema channel"
            `Quick
            test_partition_cli_slots_preserves_refused_slots_and_muse_output_schema
        ; test_case
            "input-size guard and refusal classification"
            `Quick
            test_input_size_guard_and_refusal_classification
        ] )
    ; ( "quota across real adapters",
        [ test_case "new and prior rejection order account siblings" `Quick test_real_quota_reorders_siblings_and_next_walk
        ; test_case "absolute reset and transport success before JSON parsing" `Quick test_provider_reset_and_success_before_json_validation
        ; test_case "Codex usage limit is read by the next walk" `Quick test_codex_usage_limit_is_read_by_the_next_walk
        ; test_case "preseeded rate orders actual CLI dispatch" `Quick test_preseeded_rate_dispatches_other_cli_candidate
        ; test_case "typed rate crosses walks without account quota" `Quick test_real_rate_is_candidate_only_across_walks
        ; test_case "dispatch observer retains original runtime" `Quick test_dispatch_observer_keeps_actual_runtime
        ; test_case "rate observation keeps dispatch snapshot" `Quick test_rate_observation_stays_on_dispatch_snapshot
        ; test_case "success clears before usage rebind and JSON rejection" `Quick test_success_observation_precedes_usage_rebind_and_json
        ; test_case "catalog reload keeps in-flight scope" `Quick test_catalog_reload_does_not_move_inflight_quota ])
    ; ( "cli one-shot"
      , [ test_case
            "non-official ids are refused before the runner"
            `Quick
            test_non_official_ids_are_refused_before_the_runner
        ; test_case
            "prompt carries the exact Agent Core schema sentence"
            `Quick
            test_prompt_carries_the_exact_agent_core_schema_sentence
        ; test_case
            "the runner receives the caller's own schema"
            `Quick
            test_the_runner_receives_the_callers_own_schema
        ; test_case
            "the prompt keeps its instruction alongside the schema"
            `Quick
            test_the_prompt_keeps_its_instruction_alongside_the_schema
        ; test_case
            "an Antigravity slot is told to answer through finish"
            `Quick
            test_an_antigravity_slot_is_told_to_answer_through_finish
        ; test_case
            "a fenced answer is invalid output, not repaired"
            `Quick
            test_a_fenced_answer_is_invalid_output_not_repaired
        ; test_case "observer preserves rejected raw outputs with actual slots" `Quick test_observer_retains_rejected_raw_output
        ; test_case
            "walk advances and keeps every failure in order"
            `Quick
            test_walk_advances_and_keeps_every_failure_in_order
        ; test_case
            "walk exhaustion returns every failure"
            `Quick
            test_walk_exhaustion_returns_every_failure
        ; test_case
            "an empty walk is an empty error"
            `Quick
            test_an_empty_walk_is_an_empty_error
        ; test_case
            "a Muse Code failure is never a binding rest"
            `Quick
            test_a_muse_failure_is_never_a_binding_rest
        ] )
    ]
;;

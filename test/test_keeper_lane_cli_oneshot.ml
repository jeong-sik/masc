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

let unreachable_runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ =
  failf "the runner must not run for %s" runtime_id
;;

let test_non_official_ids_are_refused_before_the_runner () =
  with_runtime (fun () ->
    (match run ~runner:unreachable_runner ~runtime_id:"nope.not-configured" () with
     | Error (Cli_oneshot.Not_an_official_client { runtime_id }) ->
       check string "unknown id is named" "nope.not-configured" runtime_id
     | Ok _ | Error _ -> fail "an unknown id must be refused as non-official");
    match run ~runner:unreachable_runner ~runtime_id:agent_core_runtime () with
    | Error (Cli_oneshot.Not_an_official_client { runtime_id }) ->
      check string "http binding is named" agent_core_runtime runtime_id
    | Ok _ | Error _ -> fail "an HTTP binding must be refused as non-official")
;;

let test_prompt_carries_the_exact_agent_core_schema_sentence () =
  with_runtime (fun () ->
    let seen_prompt = ref None in
    let runner ~runtime_id:_ ~system_prompt ~output_schema:_ ~prompt =
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
    let runner ~runtime_id:_ ~system_prompt:_ ~output_schema ~prompt:_ =
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
    let runner ~runtime_id:_ ~system_prompt:_ ~output_schema ~prompt =
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
    let runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
      Ok "```json\n{\"verdict\":\"pass\"}\n```"
    in
    match run ~runner ~runtime_id:official_client_runtime () with
    | Error (Cli_oneshot.Invalid_json_output { runtime_id; _ }) ->
      check string "the failing slot is named" official_client_runtime runtime_id
    | Ok _ -> fail "a fenced answer must not parse"
    | Error failure ->
      failf "wrong failure class: %s" (Cli_oneshot.failure_to_string failure))
;;

let test_walk_advances_and_keeps_every_failure_in_order () =
  with_runtime (fun () ->
    let runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ =
      if String.equal runtime_id official_client_runtime
      then Ok {|{"verdict":"pass"}|}
      else Error "spawn failed"
    in
    (* Both ids classify as official clients only when configured; the walk
       still records the refusal of the unknown one and advances. *)
    match
      Cli_oneshot.walk
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
      check string "second slot answered" official_client_runtime runtime_id;
      check string "value parsed" {|{"verdict":"pass"}|} (Yojson.Safe.to_string value))
;;

let test_walk_exhaustion_returns_every_failure () =
  with_runtime (fun () ->
    let runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ = Error "quota" in
    match
      Cli_oneshot.walk
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
       | ( Cli_oneshot.Execution_failed { runtime_id = first_id; detail }
         , Cli_oneshot.Not_an_official_client { runtime_id = second_id } ) ->
         check string "first failure is the runner's" official_client_runtime first_id;
         check string "runner detail is kept" "quota" detail;
         check string "second failure is the refusal" "nope.not-configured" second_id
       | _ -> fail "failures must keep walk order and class")
    | Error failures -> failf "expected two failures, got %d" (List.length failures))
;;

let test_an_empty_walk_is_an_empty_error () =
  with_runtime (fun () ->
    match
      Cli_oneshot.walk
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

(* These fixtures drive the actual Claude stream adapter and Antigravity
   result adapter through the default runner. A string-only runner cannot
   prove that a typed provider rejection reaches the shared quota table. *)
let shell_quote text =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' text) ^ "'"
;;

let a1 = official_client_runtime
let a2 = "claude_code.claude-haiku-4-5"
let b = "agy.gemini"

let quota_fixture ~claude_cli ~agy_cli =
  let base = fixture ~claude_cli () in
  base ^ Printf.sprintf {|
[models."claude-haiku-4-5"]
api-name = "claude-haiku-4-5"
max-context = 200000
[claude_code."claude-haiku-4-5"]
[providers.agy]
protocol = "antigravity-cli"
command = %S
is-non-interactive = true
[models.gemini]
api-name = "gemini-fixture"
max-context = 128000
[agy.gemini]
|} agy_cli
;;

let scope runtime_id =
  match Runtime.quota_scope_of_runtime_id runtime_id with
  | Some scope -> scope
  | None -> failf "missing fixture scope %s" runtime_id
;;

let claude_script ~marker ~body =
  Printf.sprintf {|#!/bin/sh
set -eu
if [ "${1-}" = auth ]; then
  printf '%%s\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"team","apiProvider":"firstParty"}'
  exit 0
fi
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
emit() { printf '%%s\n' "$1" | sed "s/__SESSION__/$session/g"; }
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
  "emit " ^ shell_quote (Yojson.Safe.to_string
    (`Assoc [ "type", `String "result"; "subtype", `String "success";
              "is_error", `Bool false; "session_id", `String "__SESSION__";
              "uuid", `String "answer-result"; "result", `String answer ]))
;;

let with_quota_fixture f =
  let dir = Filename.temp_dir "cli-quota-adapter" "" in
  let path name = Filename.concat dir name in
  let marker = path "calls" in
  let claude_cli = path "claude" in
  let agy_cli = path "agy" in
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
      Array.iter (fun name -> Sys.remove (path name)) (Sys.readdir dir);
      Unix.rmdir dir)
    (fun () ->
      Runtime_quota_window.reset_for_testing ();
      write_file ~path:marker ~perm:0o600 "";
      write_file ~path:claude_cli ~perm:0o700 (claude_script ~marker ~body:(rejection ()));
      write_file ~path:agy_cli ~perm:0o700
        (Printf.sprintf {|#!/bin/sh
set -eu
cat >/dev/null
printf 'B\n' >> %s
printf '%%s\n' '{"event":"init","conversation_id":"quota-b","init":{"model":"gemini-fixture","cwd":"/tmp","tools":[],"permission_mode":"always-proceed"}}'
printf '%%s\n' '{"event":"result","result":{"conversation_id":"quota-b","status":"SUCCESS","response":"{\"verdict\":\"pass\"}","num_turns":1,"usage":{"input_tokens":100,"output_tokens":7,"thinking_tokens":3,"cache_read_tokens":50,"total_tokens":107}}}'
|} (shell_quote marker));
      let catalog = quota_fixture ~claude_cli ~agy_cli in
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
  Cli_oneshot.walk ~base_dir:dir ~cli_slots:slots ~system_prompt:""
    ~requirement ~prompt:"Judge this." ()
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
        ["A:claude-sonnet-5"; "B"; "B"; "A:claude-sonnet-5"; "A:claude-haiku-4-5"] (calls marker);
      Runtime_quota_window.note_observed_exhausted ~scope:(scope b);
      write_file ~path:marker ~perm:0o600 "";
      walk_real ~dir [a1; a2; b] |> require_b;
      check (list string) "all scopes exhausted still try every declared candidate"
        ["A:claude-sonnet-5"; "A:claude-haiku-4-5"; "B"] (calls marker);
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

let () =
  Alcotest.run
    "keeper_lane_cli_oneshot"
    [ ( "quota across real adapters",
        [ test_case "new and prior rejection order account siblings" `Quick test_real_quota_reorders_siblings_and_next_walk
        ; test_case "absolute reset and transport success before JSON parsing" `Quick test_provider_reset_and_success_before_json_validation
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
            "a fenced answer is invalid output, not repaired"
            `Quick
            test_a_fenced_answer_is_invalid_output_not_repaired
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
        ] )
    ]
;;

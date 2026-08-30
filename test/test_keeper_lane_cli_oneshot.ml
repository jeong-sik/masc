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

let fixture =
  {|
[runtime]
default = "stub-http.stub-model"

[providers.stub-http]
display-name = "Stub HTTP"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[providers.claude_code]
display-name = "Claude Code Max Subscription"
protocol = "claude-code"
command = "/usr/bin/true"
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
|}
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
       write_file ~path ~perm:0o600 fixture;
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

let () =
  Alcotest.run
    "keeper_lane_cli_oneshot"
    [ ( "cli one-shot"
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

(* runtime.toml declares which prior-turn reasoning a model replays.

   The catalog already carries this per row, and it has to be per row: one
   physical model served by two endpoints owes two different answers. DeepSeek's
   own API requires every prior [reasoning_content] back on a request that
   carries tools and refuses with 400 otherwise
   (api-docs.deepseek.com/guides/thinking_mode/, read 2026-09-18); the same
   weights served by Ollama carry no such rule, and its cloud model cards say
   the opposite -- thoughts from previous turns must not be in the history
   (ollama.com/library/gemma4:31b-cloud).

   A deployment that binds its own endpoint had no way to say which of the two
   it is: [reasoning-streaming-format], [thinking-control-format],
   [reasoning-effort] and [reasoning-uncontrolled] were all declarable here and
   this one was not. On 2026-09-18 that gap cost one live keeper lane about 60%
   of every request -- 4.7 MB of a 7.83 MB body was reasoning the target had
   disabled and never produced. *)

open Alcotest

let toml_with_replay value =
  Printf.sprintf
    {|[models.m]
max-context = 1000

[models.m.capabilities]
reasoning-replay = "%s"
|}
    value
;;

let model_without_the_key = {|[models.m]
max-context = 1000

[models.m.capabilities]
max-output-tokens = 2048
|}

(* A local substring check keeps this suite linking the runtime library alone,
   as its sibling [test_thinking_control_format_unknown_error] does. *)
let contains haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec scan index =
    if index + needle_length > haystack_length
    then false
    else if String.equal (String.sub haystack index needle_length) needle
    then true
    else scan (index + 1)
  in
  needle_length = 0 || scan 0
;;

let render_errors errors =
  errors
  |> List.map (fun (error : Runtime_toml.parse_error) ->
    Printf.sprintf "%s: %s" error.path error.message)
  |> String.concat "\n"
;;

let capabilities_of_toml toml =
  match Runtime_toml.parse_string toml with
  | Error errors -> failf "expected the config to load:\n%s" (render_errors errors)
  | Ok config ->
    (match config.Runtime_schema.models with
     | [ model ] -> model.Runtime_schema.capabilities
     | models -> failf "expected one model, got %d" (List.length models))
;;

let replay_of_toml toml =
  match capabilities_of_toml toml with
  | None -> None
  | Some capabilities ->
    capabilities.Runtime_schema.reasoning_replay_override
;;

let replay_testable =
  testable
    (fun formatter value ->
       Format.pp_print_string formatter (Runtime_schema.show_reasoning_replay_override value))
    Runtime_schema.equal_reasoning_replay_override
;;

(* Every spelling the catalog takes, so a row moved from models.toml into a
   deployment's runtime.toml keeps its meaning. *)
let test_every_catalog_spelling_loads () =
  List.iter
    (fun (written, expected) ->
       check
         (option replay_testable)
         written
         (Some expected)
         (replay_of_toml (toml_with_replay written)))
    [ "default", Runtime_schema.Default_reasoning_replay
    ; "no_replay", Runtime_schema.Force_no_replay
    ; "drop_without_tool", Runtime_schema.Force_drop_without_tool_preserve_with_tool
    ; ( "drop_without_tool_preserve_with_tool"
      , Runtime_schema.Force_drop_without_tool_preserve_with_tool )
    ; "latest_user_turn_tool_calls", Runtime_schema.Force_latest_user_turn_tool_calls
    ; "preserve_always", Runtime_schema.Force_preserve_always
    ]
;;

(* The key is spelled with dashes here and the value with underscores in the
   catalog. An operator writing the key's punctuation in the value is asking
   for the same thing. *)
let test_dashes_and_case_read_as_the_same_value () =
  List.iter
    (fun written ->
       check
         (option replay_testable)
         written
         (Some Runtime_schema.Force_latest_user_turn_tool_calls)
         (replay_of_toml (toml_with_replay written)))
    [ "latest-user-turn-tool-calls"; "Latest_User_Turn_Tool_Calls" ];
  check
    (option replay_testable)
    "surrounding spaces are trimmed"
    (Some Runtime_schema.Force_preserve_always)
    (replay_of_toml (toml_with_replay " preserve_always "))
;;

let test_unknown_value_fails_the_load () =
  match Runtime_toml.parse_string (toml_with_replay "keep_everything") with
  | Ok _ -> fail "an unknown reasoning-replay value loaded"
  | Error errors ->
    let rendered = render_errors errors in
    check
      bool
      "the refusal names the key"
      true
      (contains rendered "models.m.capabilities.reasoning-replay");
    check
      bool
      "the refusal quotes what was written"
      true
      (contains rendered "\"keep_everything\"");
    check
      bool
      "the refusal lists what it would have taken"
      true
      (contains rendered "latest_user_turn_tool_calls")
;;

let test_a_non_string_fails_as_a_parse_error () =
  let toml =
    {|[models.m]
max-context = 1000

[models.m.capabilities]
reasoning-replay = 3
|}
  in
  match Runtime_toml.parse_string toml with
  | Ok _ -> fail "a non-string reasoning-replay loaded"
  | Error errors ->
    check
      bool
      "the refusal says a string was expected"
      true
      (contains (render_errors errors) "a string")
;;

(* Absence is not a value: the catalog keeps answering for this model. *)
let test_absence_declares_nothing () =
  check (option replay_testable) "no key" None (replay_of_toml model_without_the_key);
  check
    bool
    "the rest of the capabilities still parse"
    true
    (match capabilities_of_toml model_without_the_key with
     | None -> false
     | Some capabilities -> capabilities.Runtime_schema.max_output_tokens = Some 2048)
;;

let () =
  run
    "runtime_toml reasoning-replay"
    [ ( "parse_string"
      , [ test_case "every catalog spelling loads" `Quick test_every_catalog_spelling_loads
        ; test_case
            "dashes and case read as the same value"
            `Quick
            test_dashes_and_case_read_as_the_same_value
        ; test_case "unknown value fails the load" `Quick test_unknown_value_fails_the_load
        ; test_case
            "a non-string fails as a parse error"
            `Quick
            test_a_non_string_fails_as_a_parse_error
        ; test_case "absence declares nothing" `Quick test_absence_declares_nothing
        ] )
    ]
;;

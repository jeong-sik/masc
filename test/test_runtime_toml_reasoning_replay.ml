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

let render_errors errors =
  errors
  |> List.map (fun (error : Runtime_toml.parse_error) ->
    Printf.sprintf "%s: %s" error.path error.message)
  |> String.concat "\n"
;;

(* A refusal is read by the key it names. The prose is for the operator and is
   not what this suite holds still. *)
let refusal_paths toml =
  match Runtime_toml.parse_string toml with
  | Ok _ -> None
  | Error errors ->
    Some (List.map (fun (error : Runtime_toml.parse_error) -> error.path) errors)
;;

let replay_key_path = "models.m.capabilities.reasoning-replay"

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

(* The vocabulary decides what a written value means, and it reads case and
   surrounding space. Punctuation it does not spell is not a near miss to be
   repaired here: the key is written with dashes and the value is not, and a
   value this parser rewrote would be a spelling no catalog file uses. *)
let test_the_vocabulary_decides_what_a_value_means () =
  check
    (option replay_testable)
    "case is the vocabulary's to read"
    (Some Runtime_schema.Force_latest_user_turn_tool_calls)
    (replay_of_toml (toml_with_replay "Latest_User_Turn_Tool_Calls"));
  check
    (option replay_testable)
    "surrounding spaces are trimmed"
    (Some Runtime_schema.Force_preserve_always)
    (replay_of_toml (toml_with_replay " preserve_always "));
  check
    (option (list string))
    "a spelling the vocabulary does not take is refused at this key"
    (Some [ replay_key_path ])
    (refusal_paths (toml_with_replay "latest-user-turn-tool-calls"))
;;

let test_unknown_value_fails_the_load () =
  check
    (option (list string))
    "an unknown value is refused at this key"
    (Some [ replay_key_path ])
    (refusal_paths (toml_with_replay "keep_everything"))
;;

let test_a_non_string_fails_as_a_parse_error () =
  let toml =
    {|[models.m]
max-context = 1000

[models.m.capabilities]
reasoning-replay = 3
|}
  in
  check
    (option (list string))
    "a non-string is refused at this key"
    (Some [ replay_key_path ])
    (refusal_paths toml)
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
            "the vocabulary decides what a value means"
            `Quick
            test_the_vocabulary_decides_what_a_value_means
        ; test_case "unknown value fails the load" `Quick test_unknown_value_fails_the_load
        ; test_case
            "a non-string fails as a parse error"
            `Quick
            test_a_non_string_fails_as_a_parse_error
        ; test_case "absence declares nothing" `Quick test_absence_declares_nothing
        ] )
    ]
;;

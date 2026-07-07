(* RFC-0089 — runtime.toml thinking-control-format is a closed enum. An unknown
   value now fails the whole config load (Error), mirroring how this parser
   already rejects unknown protocols / credential types, instead of silently
   downgrading to No_thinking_control (which hid config typos that disable
   thinking control for a model that needs it).

   Driven through the public [parse_string] entry. The valid and invalid TOMLs
   differ only in the thinking-control-format value, isolating it as the cause
   of the load failure. *)

open Alcotest

let toml_with_tcf tcf =
  Printf.sprintf
    {|[models.m]
max-context = 1000

[models.m.capabilities]
thinking-control-format = "%s"
|}
    tcf

let model_without_capabilities = {|[models.m]
max-context = 1000
|}

let is_error = function Ok _ -> false | Error _ -> true
let is_ok = function Ok _ -> true | Error _ -> false

let render_errors errs =
  errs
  |> List.map (fun (err : Runtime_toml.parse_error) ->
    Printf.sprintf "%s: %s" err.path err.message)
  |> String.concat "\n"

let parsed_thinking_control_format raw =
  match Runtime_toml.parse_string (toml_with_tcf raw) with
  | Error errs -> failf "expected %S to parse:\n%s" raw (render_errors errs)
  | Ok cfg ->
    (match cfg.Runtime_schema.models with
     | [ model ] ->
       (match model.Runtime_schema.capabilities with
        | Some caps -> caps.Runtime_schema.thinking_control_format
        | None -> failf "expected capabilities for %S" raw)
     | models -> failf "expected one model for %S, got %d" raw (List.length models))

let test_valid_values_load_and_map_to_oas_variants () =
  let cases =
    Runtime_schema.
      [ "none", No_thinking_control
      ; "no-thinking-control", No_thinking_control
      ; "thinking_object", Thinking_object
      ; "thinking-object", Thinking_object
      ; "thinking_object_only", Thinking_object_only
      ; "thinking-object-only", Thinking_object_only
      ; "chat_template_kwargs", Chat_template_kwargs
      ; "chat-template-kwargs", Chat_template_kwargs
      ; "ollama_think", Ollama_think
      ; "ollama-think", Ollama_think
      ; "reasoning_effort", Reasoning_effort
      ; "reasoning-effort", Reasoning_effort
      ; "enable_thinking", Enable_thinking
      ; "enable-thinking", Enable_thinking
      ]
  in
  List.iter
    (fun (raw, expected) ->
       check bool ("thinking-control-format " ^ raw) true
         (Runtime_schema.equal_thinking_control_format
            (parsed_thinking_control_format raw)
            expected))
    cases

let test_unknown_value_fails_load () =
  check bool "unknown thinking-control-format fails the load (Error)" true
    (is_error (Runtime_toml.parse_string (toml_with_tcf "bogus-format")))

(* chat-template-token carries its token (mirrors oas#2484): the format
   requires a thinking-control-token key, blank/padded tokens fail, and an
   orphan token on another format fails. *)
let toml_with_tcf_and_token tcf token =
  Printf.sprintf
    {|[models.m]
max-context = 1000

[models.m.capabilities]
thinking-control-format = "%s"
thinking-control-token = "%s"
|}
    tcf token

let test_chat_template_token_roundtrip () =
  List.iter
    (fun raw ->
      match Runtime_toml.parse_string (toml_with_tcf_and_token raw "<|think|>") with
      | Error errs -> failf "expected %S to parse:\n%s" raw (render_errors errs)
      | Ok cfg ->
        (match cfg.Runtime_schema.models with
         | [ model ] ->
           (match model.Runtime_schema.capabilities with
            | Some caps ->
              check bool
                ("thinking-control-token carried for " ^ raw)
                true
                (Runtime_schema.equal_thinking_control_format
                   caps.Runtime_schema.thinking_control_format
                   (Runtime_schema.Chat_template_token "<|think|>"))
            | None -> failf "expected capabilities for %S" raw)
         | models -> failf "expected one model, got %d" (List.length models)))
    [ "chat_template_token"; "chat-template-token" ]

let test_chat_template_token_without_token_fails () =
  check bool "chat-template-token without token fails the load" true
    (is_error (Runtime_toml.parse_string (toml_with_tcf "chat-template-token")))

let test_chat_template_token_padded_token_fails () =
  check bool "padded thinking-control-token fails the load" true
    (is_error
       (Runtime_toml.parse_string
          (toml_with_tcf_and_token "chat-template-token" " <|think|> ")));
  check bool "empty thinking-control-token fails the load" true
    (is_error
       (Runtime_toml.parse_string (toml_with_tcf_and_token "chat-template-token" "")))

let test_orphan_token_fails () =
  check bool "thinking-control-token on a non-token format fails the load" true
    (is_error
       (Runtime_toml.parse_string
          (toml_with_tcf_and_token "reasoning-effort" "<|think|>")))

let test_absent_capabilities_loads () =
  (* No capabilities table at all is fine — absence defaults to no control. *)
  check bool "model without a capabilities table loads" true
    (is_ok (Runtime_toml.parse_string model_without_capabilities))

let () =
  run "thinking_control_format_unknown_error"
    [
      ( "parse_string",
        [
          test_case "valid values map to OAS variants" `Quick
            test_valid_values_load_and_map_to_oas_variants;
          test_case "unknown value fails load" `Quick test_unknown_value_fails_load;
          test_case "absent capabilities loads" `Quick
            test_absent_capabilities_loads;
          test_case "chat-template-token carries the token" `Quick
            test_chat_template_token_roundtrip;
          test_case "chat-template-token without token fails" `Quick
            test_chat_template_token_without_token_fails;
          test_case "blank/padded token fails" `Quick
            test_chat_template_token_padded_token_fails;
          test_case "orphan token fails" `Quick test_orphan_token_fails;
        ] );
    ]

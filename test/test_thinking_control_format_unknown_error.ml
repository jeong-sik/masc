(* RFC-0089 — runtime.toml thinking-control-format is a closed enum. An unknown
   value now fails the whole config load (Error), mirroring how this parser
   already rejects unknown protocols / credential types, instead of silently
   downgrading to No_thinking_control (which hid config typos that disable
   thinking control for a model that needs it).

   Driven through the public [parse_string] entry. The valid and invalid TOMLs
   differ only in the thinking-control-format value, isolating it as the cause
   of the load failure. *)

open Alcotest

let toml_with_tcf ?token tcf =
  let token_line =
    match token with
    | Some t -> Printf.sprintf "thinking-control-token = \"%s\"\n" t
    | None -> ""
  in
  Printf.sprintf
    {|[models.m]
max-context = 1000

[models.m.capabilities]
thinking-control-format = "%s"
%s|}
    tcf
    token_line

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

let parsed_thinking_control_format ?token raw =
  match Runtime_toml.parse_string (toml_with_tcf ?token raw) with
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
      [ "none", None, No_thinking_control
      ; "no-thinking-control", None, No_thinking_control
      ; "thinking_object", None, Thinking_object
      ; "thinking-object", None, Thinking_object
      ; "thinking_object_only", None, Thinking_object_only
      ; "thinking-object-only", None, Thinking_object_only
      ; "chat_template_kwargs", None, Chat_template_kwargs
      ; "chat-template-kwargs", None, Chat_template_kwargs
      ; "chat_template_token", Some "<|think|>", Chat_template_token "<|think|>"
      ; "chat-template-token", Some "<|think|>", Chat_template_token "<|think|>"
      ; "ollama_think", None, Ollama_think
      ; "ollama-think", None, Ollama_think
      ; "reasoning_effort", None, Reasoning_effort
      ; "reasoning-effort", None, Reasoning_effort
      ; "enable_thinking", None, Enable_thinking
      ; "enable-thinking", None, Enable_thinking
      ]
  in
  List.iter
    (fun (raw, token, expected) ->
       check bool ("thinking-control-format " ^ raw) true
         (Runtime_schema.equal_thinking_control_format
            (parsed_thinking_control_format ?token raw)
            expected))
    cases

let test_chat_template_token_without_token_fails_load () =
  (* OAS abfffbd8 (oas#2484): the token is model data carried in the
     constructor, so a tokenless chat-template-token row fails the load. *)
  check bool "chat-template-token without thinking-control-token fails" true
    (is_error (Runtime_toml.parse_string (toml_with_tcf "chat-template-token")));
  check bool "blank thinking-control-token fails" true
    (is_error
       (Runtime_toml.parse_string (toml_with_tcf ~token:"  " "chat-template-token")))

let test_unknown_value_fails_load () =
  check bool "unknown thinking-control-format fails the load (Error)" true
    (is_error (Runtime_toml.parse_string (toml_with_tcf "bogus-format")))

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
          test_case "tokenless chat-template-token fails load" `Quick
            test_chat_template_token_without_token_fails_load;
          test_case "absent capabilities loads" `Quick
            test_absent_capabilities_loads;
        ] );
    ]

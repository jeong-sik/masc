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

let test_valid_value_loads () =
  check bool "valid thinking-control-format loads" true
    (is_ok (Runtime_toml.parse_string (toml_with_tcf "reasoning-effort")))

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
          test_case "valid value loads" `Quick test_valid_value_loads;
          test_case "unknown value fails load" `Quick test_unknown_value_fails_load;
          test_case "absent capabilities loads" `Quick
            test_absent_capabilities_loads;
        ] );
    ]

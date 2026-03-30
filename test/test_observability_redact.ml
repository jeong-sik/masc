(** test_observability_redact — Contract tests for observability redaction. *)

open Masc_mcp

let test_api_key_redacted () =
  let input = {|{"api_key": "sk-proj-abc123xyz456def789ghi012jkl345"}|} in
  let preview = Observability_redact.redact_preview input in
  Alcotest.(check bool) "no raw key in preview" true
    (not (Observability_redact.contains_substring ~sub:"abc123xyz456" preview))

let test_url_credential_redacted () =
  let input = "postgres://admin:secretpass@db.host:5432/mydb" in
  let preview = Observability_redact.redact_preview input in
  Alcotest.(check bool) "password masked" true
    (Observability_redact.contains_substring ~sub:"[REDACTED]" preview);
  Alcotest.(check bool) "no raw password" true
    (not (Observability_redact.contains_substring ~sub:"secretpass" preview))

let test_max_length_enforced () =
  let long_input = String.make 500 'x' in
  let preview = Observability_redact.redact_preview long_input in
  Alcotest.(check bool) "within limit" true
    (String.length preview <= 220)

let test_short_input_unchanged () =
  let input = "hello world" in
  let preview = Observability_redact.redact_preview input in
  Alcotest.(check string) "short input preserved" "hello world" preview

let test_denied_tool_input_returns_none () =
  let result = Observability_redact.redact_tool_input
    ~tool_name:"tool_auth_create" (`String "secret data") in
  Alcotest.(check (option string)) "denied tool" None result

let test_denied_tool_output_returns_none () =
  let result = Observability_redact.redact_tool_output
    ~tool_name:"keeper_encryption_key" "secret" in
  Alcotest.(check (option string)) "denied tool" None result

let test_normal_tool_input_returns_some () =
  let result = Observability_redact.redact_tool_input
    ~tool_name:"masc_board_post" (`Assoc [("content", `String "hello")]) in
  Alcotest.(check bool) "normal tool returns Some" true
    (Option.is_some result)

let test_normal_tool_output_returns_some () =
  let result = Observability_redact.redact_tool_output
    ~tool_name:"masc_status" "room is active" in
  Alcotest.(check bool) "normal tool returns Some" true
    (Option.is_some result)

let () =
  Alcotest.run "observability_redact"
    [
      ( "redaction",
        [
          Alcotest.test_case "API key redacted" `Quick test_api_key_redacted;
          Alcotest.test_case "URL credential redacted" `Quick test_url_credential_redacted;
          Alcotest.test_case "max length enforced" `Quick test_max_length_enforced;
          Alcotest.test_case "short input unchanged" `Quick test_short_input_unchanged;
        ] );
      ( "deny_list",
        [
          Alcotest.test_case "denied tool input -> None" `Quick test_denied_tool_input_returns_none;
          Alcotest.test_case "denied tool output -> None" `Quick test_denied_tool_output_returns_none;
          Alcotest.test_case "normal tool input -> Some" `Quick test_normal_tool_input_returns_some;
          Alcotest.test_case "normal tool output -> Some" `Quick test_normal_tool_output_returns_some;
        ] );
    ]

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

(* Regression: the 24+ alnum pattern used to eat the 64-hex sha256 in a blob
   sentinel and produce "[masc:blob [REDACTED] bytes=... preview=..."
   which [Tool_output.decode_from_oas] cannot parse back. *)
let test_blob_sentinel_preserves_structure () =
  let sha = String.make 64 'a' in
  let marker =
    Tool_output.encode_for_oas
      (Tool_output.Stored
         { sha256 = sha; bytes = 10523; preview = "hello"; mime = "text/plain" })
  in
  let redacted = Observability_redact.redact_preview marker in
  match Tool_output.decode_from_oas redacted with
  | Tool_output.Stored { sha256; bytes; mime; _ } ->
      Alcotest.(check string) "sha256 preserved" sha sha256;
      Alcotest.(check int) "bytes preserved" 10523 bytes;
      Alcotest.(check string) "mime preserved" "text/plain" mime
  | Tool_output.Inline _ ->
      Alcotest.fail "marker structure destroyed by redaction"

let test_blob_sentinel_redacts_preview_body () =
  let sha = String.make 64 'b' in
  let preview = {|{"api_key": "sk-proj-abc123xyz456def789ghi012jkl345"}|} in
  let marker =
    Tool_output.encode_for_oas
      (Tool_output.Stored
         { sha256 = sha; bytes = 999; preview; mime = "application/json" })
  in
  let redacted = Observability_redact.redact_preview marker in
  Alcotest.(check bool) "raw key scrubbed from preview" true
    (not (Observability_redact.contains_substring ~sub:"abc123xyz456" redacted));
  Alcotest.(check bool) "sha256 still present as structural field" true
    (Observability_redact.contains_substring ~sub:("sha256=" ^ sha) redacted)

let () =
  Alcotest.run "observability_redact"
    [
      ( "redaction",
        [
          Alcotest.test_case "API key redacted" `Quick test_api_key_redacted;
          Alcotest.test_case "URL credential redacted" `Quick test_url_credential_redacted;
          Alcotest.test_case "max length enforced" `Quick test_max_length_enforced;
          Alcotest.test_case "short input unchanged" `Quick test_short_input_unchanged;
          Alcotest.test_case "blob sentinel preserves structure" `Quick
            test_blob_sentinel_preserves_structure;
          Alcotest.test_case "blob sentinel redacts preview body" `Quick
            test_blob_sentinel_redacts_preview_body;
        ] );
      ( "deny_list",
        [
          Alcotest.test_case "denied tool input -> None" `Quick test_denied_tool_input_returns_none;
          Alcotest.test_case "denied tool output -> None" `Quick test_denied_tool_output_returns_none;
          Alcotest.test_case "normal tool input -> Some" `Quick test_normal_tool_input_returns_some;
          Alcotest.test_case "normal tool output -> Some" `Quick test_normal_tool_output_returns_some;
        ] );
    ]

(** test_observability_redact — Contract tests for observability redaction. *)

open Masc

let test_api_key_redacted () =
  let input = {|{"api_key": "sk-proj-abc123xyz456def789ghi012jkl345"}|} in
  let preview = Observability_redact.redact_preview input in
  Alcotest.(check bool) "no raw key in preview" true
    (not (String_util.contains_substring preview "abc123xyz456"))

let test_url_credential_redacted () =
  let input = "postgres://admin:secretpass@db.host:5432/mydb" in
  let preview = Observability_redact.redact_preview input in
  Alcotest.(check bool) "password masked" true
    (String_util.contains_substring preview "[REDACTED]");
  Alcotest.(check bool) "no raw password" true
    (not (String_util.contains_substring preview "secretpass"))

let test_max_length_enforced () =
  let long_input = String.make 500 'x' in
  let preview = Observability_redact.redact_preview long_input in
  Alcotest.(check bool) "within limit" true
    (String.length preview <= 220)

let test_short_input_unchanged () =
  let input = "hello world" in
  let preview = Observability_redact.redact_preview input in
  Alcotest.(check string) "short input preserved" "hello world" preview

let test_redact_text_does_not_truncate () =
  let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz" in
  let input = String.make 300 'x' ^ " " ^ secret in
  let redacted = Observability_redact.redact_text input in
  Alcotest.(check bool) "not preview-truncated" false
    (String_util.contains_substring redacted "...(truncated)");
  Alcotest.(check bool) "secret removed" false
    (String_util.contains_substring redacted secret)

let test_redact_json_strings_redacts_sensitive_keys () =
  let json =
    `Assoc
      [ ("content", `String "hello");
        ("api_key", `String "short-but-sensitive");
        ("nested", `Assoc [ ("token", `String "nested-token") ]) ]
  in
  let redacted = Observability_redact.redact_json_strings json in
  let raw = Yojson.Safe.to_string redacted in
  Alcotest.(check bool) "api_key hidden" false
    (String_util.contains_substring raw "short-but-sensitive");
  Alcotest.(check bool) "nested token hidden" false
    (String_util.contains_substring raw "nested-token")

let test_redact_json_strings_redacts_secrets_in_values () =
  let json =
    `Assoc
      [ ("message", `String "Retry with Authorization: Bearer opaque_xxxxxxxx");
        ("url", `String "https://user:secret@api.example.com/v1")
      ]
  in
  let redacted = Observability_redact.redact_json_strings json in
  let raw = Yojson.Safe.to_string redacted in
  Alcotest.(check bool) "bearer token hidden" false
    (String_util.contains_substring raw "opaque_xxxxxxxx");
  Alcotest.(check bool) "URL credential hidden" false
    (String_util.contains_substring raw "user:secret")

let test_tool_name_does_not_hide_input () =
  let result = Observability_redact.redact_tool_input
    ~tool_name:"tool_auth_create" (`Assoc [ "token", `String "secret data" ]) in
  Alcotest.(check bool) "tool input remains observable" true (Option.is_some result);
  Alcotest.(check bool)
    "secret value is redacted"
    false
    (Option.fold
       ~none:false
       ~some:(fun value -> String_util.contains_substring value "secret data")
       result)

let test_tool_name_does_not_hide_output () =
  let result = Observability_redact.redact_tool_output
    ~tool_name:"keeper_encryption_key" "Bearer opaque-secret" in
  Alcotest.(check bool) "tool output remains observable" true (Option.is_some result);
  Alcotest.(check bool)
    "bearer value is redacted"
    false
    (Option.fold
       ~none:false
       ~some:(fun value -> String_util.contains_substring value "opaque-secret")
       result)

let test_normal_tool_input_returns_some () =
  let result = Observability_redact.redact_tool_input
    ~tool_name:"masc_board_post" (`Assoc [("content", `String "hello")]) in
  Alcotest.(check bool) "normal tool returns Some" true
    (Option.is_some result)

let test_normal_tool_output_returns_some () =
  let result = Observability_redact.redact_tool_output
    ~tool_name:"masc_status" "workspace is active" in
  Alcotest.(check bool) "normal tool returns Some" true
    (Option.is_some result)

(* Regression: the former generic 20+ alnum pattern used to eat the 64-hex
   sha256 in a blob marker and produce "[masc:blob [REDACTED] bytes=... preview=..."
   which [Tool_output.decode_from_oas] cannot parse back. That pattern is now
   removed; decoding still scopes redaction to the preview body so the marker
   structure is preserved either way. *)
let test_blob_marker_preserves_structure () =
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

let test_blob_marker_redacts_preview_body () =
  let sha = String.make 64 'b' in
  let preview = {|{"api_key": "sk-proj-abc123xyz456def789ghi012jkl345"}|} in
  let marker =
    Tool_output.encode_for_oas
      (Tool_output.Stored
         { sha256 = sha; bytes = 999; preview; mime = "application/json" })
  in
  let redacted = Observability_redact.redact_preview marker in
  Alcotest.(check bool) "raw key scrubbed from preview" true
    (not (String_util.contains_substring redacted "abc123xyz456"));
  Alcotest.(check bool) "sha256 still present as structural field" true
    (String_util.contains_substring redacted ("sha256=" ^ sha))

(* Regression: a marker embedded inside a JSON string field used to be
   corrupted by callers that did [Yojson.Safe.to_string |> String.sub]
   because the top-level value looks like [{...}] not [\[masc:blob ...\]],
   so [redact_preview] took the else-branch where the former 24+ alnum scrubber
   ate sha256. [preview_json_strings] walks leaves instead. (That scrubber is
   gone now, but leaf-walking remains the correct structural traversal.) *)
let test_preview_json_strings_preserves_embedded_marker () =
  let sha = String.make 64 'c' in
  let marker =
    Tool_output.encode_for_oas
      (Tool_output.Stored
         { sha256 = sha; bytes = 500; preview = "hi"; mime = "text/plain" })
  in
  let json = `Assoc [("content", `String marker); ("meta", `Int 1)] in
  let out = Observability_redact.preview_json_strings json in
  match out with
  | `Assoc fields ->
      (match List.assoc_opt "content" fields with
       | Some (`String s) ->
           (match Tool_output.decode_from_oas s with
            | Tool_output.Stored { sha256; bytes; mime; _ } ->
                Alcotest.(check string) "sha256 preserved in leaf" sha sha256;
                Alcotest.(check int) "bytes preserved in leaf" 500 bytes;
                Alcotest.(check string) "mime preserved in leaf" "text/plain" mime
            | Tool_output.Inline _ ->
                Alcotest.fail "marker in JSON leaf was corrupted")
       | _ -> Alcotest.fail "content field missing or not a string")
  | _ -> Alcotest.fail "expected Assoc root"

(* Regression: prefix-based secret regexes used to match substrings of ordinary
   identifiers. Without a word-boundary anchor, the sk- pattern matched the
   substring "sk-1234" inside the task id "task-1234" and redacted it to
   "ta[REDACTED]", corrupting error-preview diagnostics (and any observability
   field carrying a task-XXXX reference). *)
let test_no_false_positive_on_task_ids () =
  let inputs =
    [ "task-1234"; "desk-1234"; "mask-abc"; "disk-99"
    ; "flask-test"; "risk-5"; "bask-5"; "xsk-5" ]
  in
  List.iter
    (fun input ->
      let r = Observability_redact.redact_text input in
      Alcotest.(check string)
        (input ^ " not corrupted by sk- false positive") input r)
    inputs

let test_no_false_positive_on_keeper_identities () =
  let inputs =
    [ "task-claim-bot"; "heartbeat-keeper"; "diagnostic-judge"
      (* 20+ char identities: these were redacted to [REDACTED] by the former
         generic "20+ alphanumeric run" matcher (keeper-issue_king-agent=23,
         keeper-ramarama-agent=21 chars) and are preserved now that the length
         heuristic is removed. This is the regression the generic-matcher
         removal targets. *)
    ; "keeper-issue_king-agent"; "keeper-ramarama-agent"
    ; "task-claim-bot-9a8b7c6d"; "heartbeat-keeper-2f4a1b" ]
  in
  List.iter
    (fun input ->
      let r = Observability_redact.redact_text input in
      Alcotest.(check string)
        (input ^ " keeper identity preserved") input r)
    inputs

(* Regression: the sk- body used to stop at the first '-', so modern keys with a
   "-proj-" segment leaked the tail. The body now allows '-' so the whole key
   matches in one shot via the prefix matcher alone — the generic 20+ fallback
   this case once leaned on has been removed, so the prefix match must be
   complete on its own. Token literal is split so it is not mistaken for a real
   credential by tooling; it is a synthetic test value, not a live secret. *)
let test_sk_modern_key_fully_redacted () =
  let input = "sk-" ^ "proj-" ^ "0123456789abcdefghijklmnopqrstuv" in
  let r = Observability_redact.redact_text input in
  Alcotest.(check bool) "no partial sk- tail leak" true
    (not (String_util.contains_substring r "0123456789abcdef"))

let () =
  Alcotest.run "observability_redact"
    [
      ( "redaction",
        [
          Alcotest.test_case "API key redacted" `Quick test_api_key_redacted;
          Alcotest.test_case "URL credential redacted" `Quick test_url_credential_redacted;
          Alcotest.test_case "max length enforced" `Quick test_max_length_enforced;
          Alcotest.test_case "short input unchanged" `Quick test_short_input_unchanged;
          Alcotest.test_case "redact_text does not truncate" `Quick
            test_redact_text_does_not_truncate;
          Alcotest.test_case "redact_json_strings redacts sensitive keys"
            `Quick test_redact_json_strings_redacts_sensitive_keys;
          Alcotest.test_case "redact_json_strings redacts secrets embedded in values"
            `Quick test_redact_json_strings_redacts_secrets_in_values;
          Alcotest.test_case "blob marker preserves structure" `Quick
            test_blob_marker_preserves_structure;
          Alcotest.test_case "blob marker redacts preview body" `Quick
            test_blob_marker_redacts_preview_body;
          Alcotest.test_case "preview_json_strings preserves embedded marker"
            `Quick test_preview_json_strings_preserves_embedded_marker;
          Alcotest.test_case "no false positive on task ids" `Quick
            test_no_false_positive_on_task_ids;
          Alcotest.test_case "no false positive on keeper identities" `Quick
            test_no_false_positive_on_keeper_identities;
          Alcotest.test_case "modern sk- key fully redacted" `Quick
            test_sk_modern_key_fully_redacted;
        ] );
      ( "tool_observability",
        [
          Alcotest.test_case "tool name does not hide input" `Quick test_tool_name_does_not_hide_input;
          Alcotest.test_case "tool name does not hide output" `Quick test_tool_name_does_not_hide_output;
          Alcotest.test_case "normal tool input -> Some" `Quick test_normal_tool_input_returns_some;
          Alcotest.test_case "normal tool output -> Some" `Quick test_normal_tool_output_returns_some;
        ] );
    ]

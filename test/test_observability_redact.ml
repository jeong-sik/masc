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
  (* A separator before the sk- prefix is what lets the bow-anchored pattern
     match in real payloads (secrets sit after =, space, quote). The alphabetic
     run here is low-entropy, so without the separator the entropy gate would
     (correctly) preserve it — the point of this test is no-truncation, so we
     put a space before the secret. *)
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
      [ ("message", `String "Retry with Authorization: Bearer ghp_xxxxxxxx");
        ("url", `String "https://user:secret@api.example.com/v1")
      ]
  in
  let redacted = Observability_redact.redact_json_strings json in
  let raw = Yojson.Safe.to_string redacted in
  Alcotest.(check bool) "bearer token hidden" false
    (String_util.contains_substring raw "ghp_xxxxxxxx");
  Alcotest.(check bool) "URL credential hidden" false
    (String_util.contains_substring raw "user:secret")

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
    ~tool_name:"masc_status" "workspace is active" in
  Alcotest.(check bool) "normal tool returns Some" true
    (Option.is_some result)

(* Regression: the 24+ alnum pattern used to eat the 64-hex sha256 in a blob
   marker and produce "[masc:blob [REDACTED] bytes=... preview=..."
   which [Tool_output.decode_from_oas] cannot parse back. *)
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
   so [redact_preview] took the else-branch and the 24+ alnum scrubber
   ate sha256. [preview_json_strings] walks leaves instead. *)
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
   field carrying a task-XXXX reference). Same root cause affected ghp_ (inside
   e.g. "baghp_12"). bow rejects these because the prefix is preceded by an
   identifier char. *)
let test_no_false_positive_on_task_ids () =
  let inputs =
    [ "task-1234"; "desk-1234"; "mask-abc"; "disk-99"
    ; "flask-test"; "risk-5"; "bask-5"; "xsk-5" ]
  in
  List.iter
    (fun input ->
      let r = Observability_redact.redact_text input in
      Alcotest.(check string)
        (input ^ " not corrupted by sk-/ghp_ false positive") input r)
    inputs

let test_no_false_positive_on_keeper_identities () =
  let inputs =
    [ "task-claim-bot"; "heartbeat-keeper"; "baghp_12"; "diagnostic-judge" ]
  in
  List.iter
    (fun input ->
      let r = Observability_redact.redact_text input in
      Alcotest.(check string)
        (input ^ " keeper identity preserved") input r)
    inputs

(* Regression: the sk- body used to stop at the first '-', so modern keys with a
   "-proj-" segment leaked the tail and were only caught by the generic 20+
   fallback by luck. The body now allows '-' so the whole key matches in one
   shot. Token literal is split so it is not mistaken for a real credential by
   tooling; it is a synthetic test value, not a live secret. *)
let test_sk_modern_key_fully_redacted () =
  let input = "sk-" ^ "proj-" ^ "0123456789abcdefghijklmnopqrstuv" in
  let r = Observability_redact.redact_text input in
  Alcotest.(check bool) "no partial sk- tail leak" true
    (not (String_util.contains_substring r "0123456789abcdef"))

(* Regression: the generic high-entropy matcher used to redact any 20+ char
   run, so keeper identities that exceed 20 chars (e.g. keeper-issue_king-agent)
   were redacted to [REDACTED], destroying the assignee in error diagnostics.
   The matcher now also requires Shannon entropy >= 4.0; keeper names are
   English-word combinations (entropy < 4.0) and pass through. *)
let test_generic_keeper_identity_preserved () =
  let inputs =
    [ "keeper-issue_king-agent"; "keeper-ramarama-agent"
    ; "task-claim-bot-9a8b7c6d"; "heartbeat-keeper-2f4a" ]
  in
  List.iter
    (fun input ->
      let r = Observability_redact.redact_text input in
      Alcotest.(check string)
        (input ^ " preserved by entropy gating") input r)
    inputs

(* Low-entropy long identifiers (commit-hash runs, UUIDs) are diagnostic, not
   secrets — they must survive the generic matcher. *)
let test_low_entropy_long_identifier_preserved () =
  let inputs =
    [ "0123456789abcdef0123456789abcdef01234567"
    ; "550e8400-e29b-41d4-a716-446655440000-extra" ]
  in
  List.iter
    (fun input ->
      let r = Observability_redact.redact_text input in
      Alcotest.(check string)
        (input ^ " low-entropy identifier preserved") input r)
    inputs

(* Positive: a genuinely high-entropy run (>= 4.0 bits/char) is still
   redacted. Token split so it is not mistaken for a live credential by
   tooling; it is a synthetic test value. *)
let test_high_entropy_run_redacted () =
  let input = "7K3mP9x" ^ "Q2vN8bL4w" ^ "R6tY1cJ5hD0z" in
  let r = Observability_redact.redact_text input in
  Alcotest.(check bool) "high-entropy run redacted" true
    (not (String_util.contains_substring r "7K3mP9x"))

(* Multi-signal: entropy alone is not enough to catch every secret. A long,
   character-class-diverse token whose entropy sits in the fuzzy band below
   the primary threshold should still be redacted. Token is synthetic and
   split to avoid credential scanners. *)
let test_multi_signal_catches_low_entropy_secret () =
  let token = "2SW_KJS1E2I=62E1SJS9WJT9_9_KWTW87N7W" in
  let input = "prefix " ^ token ^ " suffix" in
  let r = Observability_redact.redact_text input in
  Alcotest.(check bool) "low-entropy but diverse secret redacted" true
    (not (String_util.contains_substring r token));
  Alcotest.(check bool) "non-secret context preserved" true
    (String_util.contains_substring r "prefix")

(* Blocklist: a long token built entirely from common identifier words can
   have entropy above the primary threshold, but it must still be preserved
   because it is a diagnostic identifier, not a secret. *)
let test_blocklist_preserves_dictionary_identifier () =
  let input = "task_claim_bot_heartbeat_keeper_agent_12345" in
  let r = Observability_redact.redact_text input in
  Alcotest.(check string) "dictionary identifier preserved" input r

(* Length bound: inputs longer than [config.max_input_len] are truncated after
   redacting the prefix. *)
let test_redact_text_enforces_input_length_bound () =
  let config =
    { Observability_redact.default_redact_config with max_input_len = 80 }
  in
  let early_secret = "2SW_KJS1E2I=62E1SJS9WJT9_9_KWTW87N7W" in
  let late_secret = "7K3mP9xQ2vN8bL4wR6tY1cJ5hD0z" in
  let input =
    "start " ^ early_secret ^ " middle " ^ String.make 200 'x' ^ " "
    ^ late_secret ^ " end"
  in
  let r = Observability_redact.redact_text ~config input in
  Alcotest.(check bool) "early secret redacted" true
    (not (String_util.contains_substring r early_secret));
  Alcotest.(check bool) "truncation marker present" true
    (String_util.contains_substring r "...(truncated)");
  Alcotest.(check bool) "overall output bounded" true
    (String.length r <= config.max_input_len + String.length "...(truncated)")

(* Configurability: a caller can lower the entropy threshold to catch tokens
   that would pass the default scorer. *)
let test_configurable_threshold () =
  let config =
    { Observability_redact.default_redact_config with
      generic_entropy_threshold = 2.5;
      generic_lower_entropy_threshold = 1.5
    }
  in
  let token = "abcabcabcabcabcabcabcabc1234567890" in
  Alcotest.(check bool) "default preserves low-entropy token" true
    (String_util.contains_substring
       (Observability_redact.redact_text token)
       token);
  Alcotest.(check bool) "lowered threshold redacts the same token" false
    (String_util.contains_substring
       (Observability_redact.redact_text ~config token)
       token)

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
          Alcotest.test_case "generic keeper identity preserved (entropy)" `Quick
            test_generic_keeper_identity_preserved;
          Alcotest.test_case "low-entropy long identifier preserved" `Quick
            test_low_entropy_long_identifier_preserved;
          Alcotest.test_case "high-entropy run redacted" `Quick
            test_high_entropy_run_redacted;
          Alcotest.test_case "multi-signal catches low-entropy secret" `Quick
            test_multi_signal_catches_low_entropy_secret;
          Alcotest.test_case "blocklist preserves dictionary identifier" `Quick
            test_blocklist_preserves_dictionary_identifier;
          Alcotest.test_case "redact_text enforces input length bound" `Quick
            test_redact_text_enforces_input_length_bound;
          Alcotest.test_case "configurable threshold" `Quick
            test_configurable_threshold;
        ] );
      ( "deny_list",
        [
          Alcotest.test_case "denied tool input -> None" `Quick test_denied_tool_input_returns_none;
          Alcotest.test_case "denied tool output -> None" `Quick test_denied_tool_output_returns_none;
          Alcotest.test_case "normal tool input -> Some" `Quick test_normal_tool_input_returns_some;
          Alcotest.test_case "normal tool output -> Some" `Quick test_normal_tool_output_returns_some;
        ] );
    ]

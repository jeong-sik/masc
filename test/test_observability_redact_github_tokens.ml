(* Verifies the GitHub token prefix patterns in Observability_redact. The
   installation token (ghs_) is the new case added by RFC-0236 §10; the others
   (ghp_/gho_/ghu_) are covered alongside it so a future regression in any
   prefix family is caught here rather than at a leak. The token value is not
   in any provisioned secret file — the prefix structure alone must mask it. *)

let redact s = Masc.Observability_redact.redact_text s

let contains_substring haystack needle =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let max_start = haystack_len - needle_len in
  let rec loop idx =
    idx <= max_start
    && (String.sub haystack idx needle_len = needle || loop (idx + 1))
  in
  needle_len = 0 || loop 0
;;

let test_github_token_prefixes () =
  List.iter
    (fun (label, token) ->
      let masked = redact token in
      Alcotest.(check bool)
        (label ^ " masked")
        true
        (not (String.equal masked token)))
    [ "ghp (classic PAT)", "ghp_0123456789abcdefghijklmnopqrstuvwx"
    ; "ghs (installation)", "ghs_0123456789abcdefghijklmnopqrstuvwx"
    ; "gho (oauth)", "gho_0123456789abcdefghijklmnopqrstuvwx"
    ; "ghu (user)", "ghu_0123456789abcdefghijklmnopqrstuvwx"
    ]
;;

let test_github_app_private_key_pem_redacted () =
  let pem =
    String.concat
      "\n"
      [ "before"
      ; "-----BEGIN RSA PRIVATE KEY-----"
      ; "MIIEpAIBAAKCAQEAprivate-material"
      ; "-----END RSA PRIVATE KEY-----"
      ; "after"
      ]
  in
  let masked = redact pem in
  Alcotest.(check bool) "begin marker removed" false
    (contains_substring masked "-----BEGIN RSA PRIVATE KEY-----");
  Alcotest.(check bool) "end marker removed" false
    (contains_substring masked "-----END RSA PRIVATE KEY-----");
  Alcotest.(check bool) "private body removed" false
    (contains_substring masked "MIIEpAIBAAKCAQEAprivate-material");
  Alcotest.(check bool) "prefix preserved" true
    (String.starts_with ~prefix:"before" masked);
  Alcotest.(check bool) "suffix preserved" true
    (String.ends_with ~suffix:"after" masked)
;;

let test_truncated_pem_redacts_tail () =
  let pem =
    String.concat
      "\n"
      [ "prefix"; "-----BEGIN PRIVATE KEY-----"; "unclosed-private-material" ]
  in
  let masked = redact pem in
  Alcotest.(check string) "truncated pem tail redacted" "prefix\n[REDACTED]" masked
;;

let () =
  Alcotest.run
    "observability_redact_github_tokens"
    [ ( "github_secrets"
      , [ Alcotest.test_case "github_token_prefixes" `Quick test_github_token_prefixes
        ; Alcotest.test_case
            "github_app_private_key_pem_redacted"
            `Quick
            test_github_app_private_key_pem_redacted
        ; Alcotest.test_case "truncated_pem_redacts_tail" `Quick test_truncated_pem_redacts_tail
        ] )
    ]
;;

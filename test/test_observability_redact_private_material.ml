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

let test_private_key_pem_redacted () =
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
    "observability_redact_private_material"
    [ ( "private_material"
      , [ Alcotest.test_case
            "private_key_pem_redacted"
            `Quick
            test_private_key_pem_redacted
        ; Alcotest.test_case
            "truncated_pem_redacts_tail"
            `Quick
            test_truncated_pem_redacts_tail
        ] )
    ]
;;

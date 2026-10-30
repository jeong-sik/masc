let redact s = Masc.Observability_redact.redact_text s

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
    (String_util.contains_substring masked "-----BEGIN RSA PRIVATE KEY-----");
  Alcotest.(check bool) "end marker removed" false
    (String_util.contains_substring masked "-----END RSA PRIVATE KEY-----");
  Alcotest.(check bool) "private body removed" false
    (String_util.contains_substring masked "MIIEpAIBAAKCAQEAprivate-material");
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

(* The scan this replaced carried two literal marker pairs, so a key of any
   other type went through untouched. A character class covers the family,
   which is what every other redactor of these does. *)
let test_other_private_key_types_are_redacted () =
  List.iter
    (fun kind ->
      let pem =
        String.concat "\n"
          [ "before"
          ; Printf.sprintf "-----BEGIN %sPRIVATE KEY-----" kind
          ; "MIIEpAIBAAKCAQEAprivate-material"
          ; Printf.sprintf "-----END %sPRIVATE KEY-----" kind
          ; "after"
          ]
      in
      let masked = redact pem in
      Alcotest.(check bool)
        (Printf.sprintf "%sprivate body removed" kind)
        false
        (String_util.contains_substring masked "MIIEpAIBAAKCAQEAprivate-material");
      Alcotest.(check string)
        (Printf.sprintf "%sblock replaced whole" kind)
        "before\n[REDACTED]\nafter"
        masked)
    [ ""; "RSA "; "EC "; "DSA "; "OPENSSH "; "ENCRYPTED " ]
;;

(* Two blocks in one message: the first must not swallow the text between
   them. A greedy match would. *)
let test_two_blocks_keep_the_text_between_them () =
  let pem =
    String.concat "\n"
      [ "-----BEGIN PRIVATE KEY-----"; "first-secret"; "-----END PRIVATE KEY-----"
      ; "in between"
      ; "-----BEGIN EC PRIVATE KEY-----"; "second-secret"; "-----END EC PRIVATE KEY-----"
      ]
  in
  let masked = redact pem in
  Alcotest.(check string) "both blocks, text between kept"
    "[REDACTED]\nin between\n[REDACTED]" masked
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
        ; Alcotest.test_case
            "other_private_key_types_are_redacted"
            `Quick
            test_other_private_key_types_are_redacted
        ; Alcotest.test_case
            "two_blocks_keep_the_text_between_them"
            `Quick
            test_two_blocks_keep_the_text_between_them
        ] )
    ]
;;

(* Secret_redactor's prefix scan, at its public surface. *)

open Alcotest

let redact = Llm_provider.Secret_redactor.redact_string

(* A credential whose prefix comes before an earlier-listed prefix in the text
   used to be copied through: the scan took the first listed prefix found
   anywhere and copied everything before it. *)
let test_a_credential_before_an_earlier_listed_prefix_is_redacted () =
  check string "key= before Bearer"
    "key=[REDACTED] Bearer [REDACTED]"
    (redact "key=SECRET1 Bearer SECRET2");
  check string "x-api-key before Bearer"
    "x-api-key: [REDACTED] Bearer [REDACTED]"
    (redact "x-api-key: AAA Bearer BBB");
  check string "key= glued to Bearer"
    "key=[REDACTED]Bearer [REDACTED]"
    (redact "key=abcBearer X")
;;

(* What a listed prefix claims stays its own. [Authorization:] with no token
   right after it is left as written, not marked. *)
let test_a_prefix_keeps_the_token_it_claims () =
  check string "Authorization then Bearer"
    "Authorization: Bearer [REDACTED]"
    (redact "Authorization: Bearer opaque-token");
  check string "Authorization glued to Bearer"
    "Authorization:Bearer [REDACTED]"
    (redact "Authorization:Bearer X");
  check string "repeated prefix"
    "api-key: [REDACTED] api-key: [REDACTED]"
    (redact "api-key: k1 api-key: k2");
  check string "no token after the prefix" "x-api-key: " (redact "x-api-key: ");
  check string "ordinary text" "plain text" (redact "plain text")
;;

(* Each prefix reads the text once. Looking for every prefix again after each
   redacted token made a long run of one prefix ahead of another quadratic:
   120 KB of [key=a ] before a [Bearer ] took 19 s, where one pass takes
   milliseconds. *)
let repeated_credentials = 20_000
let linear_scan_cpu_budget_s = 2.0

let test_a_long_run_of_one_prefix_ahead_of_another_is_one_pass () =
  let run = String.concat "" (List.init repeated_credentials (fun _ -> "key=a ")) in
  let started = Sys.time () in
  let redacted = redact (run ^ "Bearer x") in
  let elapsed = Sys.time () -. started in
  let expected_run =
    String.concat "" (List.init repeated_credentials (fun _ -> "key=[REDACTED] "))
  in
  check string "every token redacted" (expected_run ^ "Bearer [REDACTED]") redacted;
  check bool
    (Printf.sprintf "scan took %.3fs of CPU" elapsed)
    true
    (elapsed < linear_scan_cpu_budget_s)
;;

let test_multiple_urls_and_pem_blocks_are_redacted () =
  check string "URL userinfo after slash-containing path and multiple URLs"
    "reading /var/log/app: https://[REDACTED]@a.example.com?x=1 then https://[REDACTED]@b.example.com/v1"
    (redact "reading /var/log/app: https://u1:secret1@a.example.com?x=1 then https://u2:secret2@b.example.com/v1");
  check string "comma-separated URLs without path slash still redact second URL"
    "http://localhost:8080,https://[REDACTED]@api.example.com/v1"
    (redact "http://localhost:8080,https://user:secret@api.example.com/v1");
  let multi_pem =
    "-----BEGIN PRIVATE KEY-----\nFIRST_SECRET\n-----END PRIVATE KEY-----\n"
    ^ "middle\n"
    ^ "-----BEGIN EC PRIVATE KEY-----\nSECOND_SECRET\n-----END EC PRIVATE KEY-----\ntail"
  in
  check string "all PEM blocks in string are redacted"
    "[REDACTED]middle\n[REDACTED]tail"
    (redact multi_pem)
;;

let () =
  run
    "Secret_redactor"
    [ ( "prefixes"
      , [ test_case
            "a credential before an earlier-listed prefix is redacted"
            `Quick
            test_a_credential_before_an_earlier_listed_prefix_is_redacted
        ; test_case
            "a prefix keeps the token it claims"
            `Quick
            test_a_prefix_keeps_the_token_it_claims
        ; test_case
            "a long run of one prefix ahead of another is one pass"
            `Quick
            test_a_long_run_of_one_prefix_ahead_of_another_is_one_pass
        ; test_case
            "multiple URLs after slashes and multiple PEM blocks are redacted"
            `Quick
            test_multiple_urls_and_pem_blocks_are_redacted
        ] )
    ]
;;

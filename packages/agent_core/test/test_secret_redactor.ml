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
        ] )
    ]
;;

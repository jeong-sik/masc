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

let test_case_insensitive_and_extended_credential_prefixes () =
  check string "mixed-case X-API-Key"
    "X-API-Key: [REDACTED]"
    (redact "X-API-Key: SECRET_123");
  check string "lowercase authorization and bearer"
    "authorization: bearer [REDACTED]"
    (redact "authorization: bearer SECRET_TOK");
  check string "bare lowercase bearer"
    "bearer [REDACTED]"
    (redact "bearer SECRET_BARE");
  check string "x-goog-api-key with space"
    "x-goog-api-key: [REDACTED]"
    (redact "x-goog-api-key: AIzaSySecretKey");
  check string "mixed-case X-Goog-Api-Key without space"
    "X-Goog-Api-Key:[REDACTED]"
    (redact "X-Goog-Api-Key:AIzaSySecretKey");
  check string "mixed-case X-Auth-Token"
    "X-Auth-Token: [REDACTED]"
    (redact "X-Auth-Token: tok_secret_99");
  check string "Authorization Basic with space"
    "Authorization: Basic [REDACTED]"
    (redact "Authorization: Basic c2VjcmV0");
  check string "Authorization Basic without space after colon"
    "Authorization:Basic [REDACTED]"
    (redact "Authorization:Basic c2VjcmV0");
  check string "Authorization Basic with tabs"
    "Authorization:\tBasic\t[REDACTED]"
    (redact "Authorization:\tBasic\tc2VjcmV0");
  check string "Authorization raw token"
    "Authorization: [REDACTED]"
    (redact "Authorization: sk-raw-secret");
  check string "Proxy-Authorization Basic"
    "Proxy-Authorization: Basic [REDACTED]"
    (redact "Proxy-Authorization: Basic c2VjcmV0");
  check string "Cookie header redacted"
    "Cookie: [REDACTED]"
    (redact "Cookie: session=abc");
  check string "Cookie header redacts all semicolon-separated cookies"
    "Cookie: [REDACTED]"
    (redact "Cookie: theme=dark; session=SECRET_COOKIE; csrf=CSRF_VAL");
  check string "Cookie header stops at CRLF and preserves next header"
    "Cookie: [REDACTED]\r\nX-Next: ok"
    (redact "Cookie: theme=dark; session=SECRET_COOKIE\r\nX-Next: ok");
  check string "Cookie header inside JSON string stops at closing quote"
    "{\"header\":\"Cookie: [REDACTED]\",\"ok\":true}"
    (redact "{\"header\":\"Cookie: a=1; session=SECRET_COOKIE\",\"ok\":true}");
  check string "Cookie header inside single-quoted log stops at closing quote"
    "header='Cookie: [REDACTED]' ok=1"
    (redact "header='Cookie: a=1; session=SECRET_COOKIE' ok=1");
  check string "raw Cookie header with quoted cookie value redacts entire line"
    "Cookie: [REDACTED]"
    (redact "Cookie: theme=dark; session=\"quoted-secret\"");
  check string "Set-Cookie header redacted"
    "Set-Cookie: [REDACTED]"
    (redact "Set-Cookie: sid=xyz");
  check string "Set-Cookie with attributes redacts entire header value"
    "Set-Cookie: [REDACTED]"
    (redact "Set-Cookie: sid=xyz; Path=/; HttpOnly; Secure");
  check string "Authorization Token scheme redacted"
    "Authorization: Token [REDACTED]"
    (redact "Authorization: Token SECRET_TOK");
  check string "Authorization Token with tab redacted"
    "Authorization: Token\t[REDACTED]"
    (redact "Authorization: Token\tSECRET_TOK");
  check string "Proxy-Authorization Negotiate scheme redacted"
    "Proxy-Authorization: Negotiate [REDACTED]"
    (redact "Proxy-Authorization: Negotiate YII_SECRET_BLOB==");
  check string "Authorization Bearer with tab redacted"
    "Authorization: Bearer\t[REDACTED]"
    (redact "Authorization: Bearer\tSECRET_TAB");
  check string "bare lowercase bearer with tab redacted"
    "bearer\t[REDACTED]"
    (redact "bearer\tSECRET_TAB_BARE");
  check string "Authorization Digest with quoted params redacts full header"
    "Authorization: Digest [REDACTED]"
    (redact "Authorization: Digest username=\"alice\", realm=\"api\", response=\"DIGEST_SECRET\"");
  check string "Authorization Digest inside JSON string skips escaped quotes"
    "{\"header\":\"Authorization: Digest [REDACTED]\",\"ok\":true}"
    (redact "{\"header\":\"Authorization: Digest username=\\\"alice\\\", response=\\\"DIGEST_SECRET\\\"\",\"ok\":true}");
  check string "Authorization AWS4-HMAC-SHA256 redacts full header"
    "Authorization: AWS4-HMAC-SHA256 [REDACTED]"
    (redact "Authorization: AWS4-HMAC-SHA256 Credential=EXAMPLE/us-east-1, Signature=SIG_SECRET");
  check string "Authorization unknown scheme redacts full value without leaking secret"
    "Authorization: [REDACTED]"
    (redact "Authorization: CustomScheme SECRET_CUSTOM");
  check string "Authorization Token before Bearer redacts both cleanly"
    "Authorization: Token [REDACTED] Bearer [REDACTED]"
    (redact "Authorization: Token SECRET1 Bearer SECRET2");
  check string "Cookie before Bearer redacts both cleanly"
    "Cookie: [REDACTED] Bearer [REDACTED]"
    (redact "Cookie: a=1; session=SECRET1 Bearer SECRET2");
  check string "tab-separated x-goog-api-key"
    "x-goog-api-key:\t[REDACTED]"
    (redact "x-goog-api-key:\tAIzaSecret");
  check string "double-space x-goog-api-key"
    "x-goog-api-key:  [REDACTED]"
    (redact "x-goog-api-key:  AIzaSecret");
  check string "bare Basic in ordinary prose is untouched"
    "Basic math is fun"
    (redact "Basic math is fun");
  check string "identifier-prefixed = keys are not falsely redacted"
    "monkey=1 whiskey=2 cache_key=3 my_token=4"
    (redact "monkey=1 whiskey=2 cache_key=3 my_token=4");
  check string "api_key= and token= query params"
    "https://example.com/v1?api_key=[REDACTED]&token=[REDACTED]&key=[REDACTED]&model=x"
    (redact "https://example.com/v1?api_key=SECRET1&token=SECRET2&key=SECRET3&model=x")
;;

let contains_ci ~haystack ~needle =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let hlen = String.length h in
  let nlen = String.length n in
  let rec loop i =
    if i + nlen > hlen
    then false
    else if String.sub h i nlen = n
    then true
    else loop (i + 1)
  in
  nlen = 0 || loop 0
;;

let test_url_sanitization_and_sensitive_response_headers () =
  (match
     Llm_provider.Http_client.prepare_sync_request
       ~url:"ftp://alice:supersecret@api.example.com/v1?key=AIzaSecret"
       ~headers:[]
       ~body:"{}"
   with
   | Error (Llm_provider.Http_client.NetworkError { message; _ }) ->
     check bool "invalid URL error strips userinfo secret" false
       (contains_ci ~haystack:message ~needle:"supersecret");
     check bool "invalid URL error strips query key secret" false
       (contains_ci ~haystack:message ~needle:"AIzaSecret")
   | _ -> fail "expected NetworkError for unsupported ftp scheme");
  let sanitized =
    Llm_provider.Api_common.sanitize_url_for_log
      "https://alice:supersecret@generativelanguage.googleapis.com/v1beta/models/gemini:generateContent?key=AIzaSecret#frag"
  in
  check bool "sanitize_url_for_log strips userinfo" false
    (contains_ci ~haystack:sanitized ~needle:"supersecret");
  check bool "sanitize_url_for_log strips query key" false
    (contains_ci ~haystack:sanitized ~needle:"AIzaSecret");
  check bool "sanitize_url_for_log preserves host and path" true
    (contains_ci ~haystack:sanitized ~needle:"generativelanguage.googleapis.com/v1beta/models/gemini:generateContent");
  check string "sanitize_url_for_log strips #fragment secrets"
    "https://api.example.com/v1"
    (Llm_provider.Api_common.sanitize_url_for_log
       "https://api.example.com/v1#access_token=SECRET");
  check string "sanitize_url_for_log strips ?query with @ before authority scan"
    "https://api.example.com"
    (Llm_provider.Api_common.sanitize_url_for_log
       "https://api.example.com?email=a@b");
  check string "sanitize_url_for_log preserves @ in path while stripping #fragment"
    "https://api.example.com/u/a@b"
    (Llm_provider.Api_common.sanitize_url_for_log
       "https://api.example.com/u/a@b#token=SECRET")
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
        ; test_case
            "case-insensitive and extended credential prefixes are redacted"
            `Quick
            test_case_insensitive_and_extended_credential_prefixes
        ; test_case
            "URL sanitization and sensitive response headers protect credentials"
            `Quick
            test_url_sanitization_and_sensitive_response_headers
        ] )
    ]
;;

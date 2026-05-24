(** RFC-0142 §Phase 2 — PR-A.  Unit tests for the typed
    [Provider_error_class] SSOT.

    Covers (a) wire-tag stability for every constructor,
    (b) [raw_payload] preserves [Unspecified] verbatim and is [None]
    elsewhere, (c) HTTP status named-constant values match the
    numbers previously inlined in [Keeper_health_probe], and
    (d) [response_timeout_kind] wire tags. *)

open Alcotest

module P = Masc_mcp.Provider_error_class

let tag = testable Fmt.string String.equal

let check_tag label expected actual =
  check tag label expected (P.to_short_tag actual)
;;

(* ---- to_short_tag: every constructor pinned ---- *)

let test_short_tag_client_capacity_exhausted () =
  check_tag "Client_capacity_exhausted" "client_capacity_exhausted"
    P.Client_capacity_exhausted
;;

let test_short_tag_tier_admission_exhausted_some () =
  check_tag "Tier_admission_exhausted Some" "tier_admission_exhausted"
    (P.Tier_admission_exhausted
       { capability_profile = Some "strict_tool_candidates" })
;;

let test_short_tag_tier_admission_exhausted_none () =
  check_tag "Tier_admission_exhausted None" "tier_admission_exhausted"
    (P.Tier_admission_exhausted { capability_profile = None })
;;

let test_short_tag_backpressure () =
  check_tag "Backpressure" "backpressure"
    (P.Backpressure
       { http_status = P.Http_status.too_many_requests
       ; retry_after_ms = Some 2_500
       })
;;

let test_short_tag_dns_resolution_failure () =
  check_tag "Dns_resolution_failure" "dns_resolution_failure"
    (P.Dns_resolution_failure { host = Some "api.provider_a.com" })
;;

let test_short_tag_response_timeout () =
  check_tag "Response_timeout" "response_timeout"
    (P.Response_timeout
       { kind = P.First_token_timeout; elapsed_ms = Some 30_000 })
;;

let test_short_tag_unspecified () =
  check_tag "Unspecified" "unspecified"
    (P.Unspecified { raw_code = "unknown_provider_error"; raw_detail = "" })
;;

(* ---- raw_payload: Unspecified preserves verbatim, others are None ---- *)

let raw_pair = pair string string

let test_raw_payload_unspecified_preserves () =
  check (option raw_pair) "verbatim raw_code + raw_detail"
    (Some ("upstream_5xx", "Bad Gateway (cloudflare proxy)"))
    (P.raw_payload
       (P.Unspecified
          { raw_code = "upstream_5xx"
          ; raw_detail = "Bad Gateway (cloudflare proxy)"
          }))
;;

let test_raw_payload_typed_variants_are_none () =
  check (option raw_pair) "Client_capacity_exhausted" None
    (P.raw_payload P.Client_capacity_exhausted);
  check (option raw_pair) "Tier_admission_exhausted" None
    (P.raw_payload
       (P.Tier_admission_exhausted { capability_profile = None }));
  check (option raw_pair) "Backpressure" None
    (P.raw_payload
       (P.Backpressure
          { http_status = P.Http_status.anthropic_overloaded
          ; retry_after_ms = None
          }));
  check (option raw_pair) "Dns_resolution_failure" None
    (P.raw_payload (P.Dns_resolution_failure { host = None }));
  check (option raw_pair) "Response_timeout" None
    (P.raw_payload
       (P.Response_timeout
          { kind = P.Wall_clock_timeout; elapsed_ms = None }))
;;

(* ---- HTTP status constants pin the magic numbers previously inlined ---- *)

let test_http_status_named_constants () =
  check int "too_many_requests = 429" 429 P.Http_status.too_many_requests;
  check int "anthropic_overloaded = 529" 529 P.Http_status.anthropic_overloaded;
  check int "request_timeout = 408" 408 P.Http_status.request_timeout;
  check int "gateway_timeout = 504" 504 P.Http_status.gateway_timeout;
  check int "cloudflare_origin_timeout = 524" 524
    P.Http_status.cloudflare_origin_timeout
;;

let test_backpressure_http_statuses_set () =
  check (list int) "backpressure set"
    [ 429; 529 ] P.backpressure_http_statuses
;;

let test_timeout_http_statuses_set () =
  check (list int) "timeout set" [ 408; 504; 524 ] P.timeout_http_statuses
;;

(* ---- response_timeout_kind wire tags ---- *)

let test_response_timeout_kind_tags () =
  let kt = P.response_timeout_kind_to_string in
  check string "Connection_timeout" "connection_timeout" (kt P.Connection_timeout);
  check string "First_token_timeout" "first_token_timeout"
    (kt P.First_token_timeout);
  check string "Inter_chunk_idle" "inter_chunk_idle" (kt P.Inter_chunk_idle);
  check string "Wall_clock_timeout" "wall_clock_timeout"
    (kt P.Wall_clock_timeout)
;;

let () =
  run "provider_error_class"
    [ ( "to_short_tag"
      , [ test_case "client_capacity_exhausted" `Quick
            test_short_tag_client_capacity_exhausted
        ; test_case "tier_admission_exhausted Some" `Quick
            test_short_tag_tier_admission_exhausted_some
        ; test_case "tier_admission_exhausted None" `Quick
            test_short_tag_tier_admission_exhausted_none
        ; test_case "backpressure" `Quick test_short_tag_backpressure
        ; test_case "dns_resolution_failure" `Quick
            test_short_tag_dns_resolution_failure
        ; test_case "response_timeout" `Quick test_short_tag_response_timeout
        ; test_case "unspecified" `Quick test_short_tag_unspecified
        ] )
    ; ( "raw_payload"
      , [ test_case "Unspecified preserves verbatim" `Quick
            test_raw_payload_unspecified_preserves
        ; test_case "typed variants → None" `Quick
            test_raw_payload_typed_variants_are_none
        ] )
    ; ( "http_status"
      , [ test_case "named constants" `Quick test_http_status_named_constants
        ; test_case "backpressure set" `Quick test_backpressure_http_statuses_set
        ; test_case "timeout set" `Quick test_timeout_http_statuses_set
        ] )
    ; ( "response_timeout_kind"
      , [ test_case "wire tags" `Quick test_response_timeout_kind_tags ] )
    ]
;;

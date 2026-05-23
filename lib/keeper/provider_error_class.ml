(* RFC-0142 §Phase 2 — PR-A.  SSOT for LLM-provider runtime error
   classification.  See provider_error_class.mli for the contract.

   This module is intentionally dependency-free (no transitive [String_util],
   no Eio, no Unix) so the boundary type can land before any adapter or
   consumer wires it in. *)

type response_timeout_kind =
  | Connection_timeout
  | First_token_timeout
  | Inter_chunk_idle
  | Wall_clock_timeout

type t =
  | Client_capacity_exhausted
  | Tier_admission_exhausted of { capability_profile : string option }
  | Backpressure of
      { http_status : int
      ; retry_after_ms : int option
      }
  | Dns_resolution_failure of { host : string option }
  | Response_timeout of
      { kind : response_timeout_kind
      ; elapsed_ms : int option
      }
  | Unspecified of
      { raw_code : string
      ; raw_detail : string
      }

module Http_status = struct
  let too_many_requests = 429
  let anthropic_overloaded = 529
  let request_timeout = 408
  let gateway_timeout = 504
  let cloudflare_origin_timeout = 524
end

let backpressure_http_statuses =
  [ Http_status.too_many_requests; Http_status.anthropic_overloaded ]
;;

let timeout_http_statuses =
  [ Http_status.request_timeout
  ; Http_status.gateway_timeout
  ; Http_status.cloudflare_origin_timeout
  ]
;;

let response_timeout_kind_to_string = function
  | Connection_timeout -> "connection_timeout"
  | First_token_timeout -> "first_token_timeout"
  | Inter_chunk_idle -> "inter_chunk_idle"
  | Wall_clock_timeout -> "wall_clock_timeout"
;;

let to_short_tag = function
  | Client_capacity_exhausted -> "client_capacity_exhausted"
  | Tier_admission_exhausted _ -> "tier_admission_exhausted"
  | Backpressure _ -> "backpressure"
  | Dns_resolution_failure _ -> "dns_resolution_failure"
  | Response_timeout _ -> "response_timeout"
  | Unspecified _ -> "unspecified"
;;

let raw_payload = function
  | Unspecified { raw_code; raw_detail } -> Some (raw_code, raw_detail)
  | Client_capacity_exhausted
  | Tier_admission_exhausted _
  | Backpressure _
  | Dns_resolution_failure _
  | Response_timeout _ -> None
;;

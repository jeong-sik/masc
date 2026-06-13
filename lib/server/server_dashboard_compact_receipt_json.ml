(* Compact-receipt JSON builders for the dashboard composite endpoint.

   The dashboard composite surface ships a *summary* of the most recent
   keeper receipt (error / runtime blocks) rather than the raw receipt
   JSON.  These helpers do the field projection + truncation so the wire
   payload stays bounded.

   Extracted from [Server_dashboard_http] (godfile decomp). Pure JSON
   mapping over receipt-shaped [Yojson.Safe.t] values.  No shared
   state, no I/O. *)

let compact_preview = Server_dashboard_http_json_utils.compact_preview

(* Local member-lookup helper.  The parent's [json_member] returns
   `Null on miss; matching that shape lets the caller pattern-match
   on `Assoc / `Null without options. *)
let json_member = Server_dashboard_http_json_utils.json_member

let json_string key json = Json_util.get_string json key
let json_int key json = Json_util.get_int json key
let json_bool key json = Json_util.get_bool json key

let compact_receipt_error_json receipt =
  match json_member "error" receipt with
  | `Assoc _ as error ->
    let kind = json_string "kind" error in
    let message = json_string "message" error in
    let message_preview, message_truncated =
      match message with
      | Some value -> compact_preview ~max_chars:900 value
      | None -> "", false
    in
    `Assoc
      [ "kind", Json_util.string_opt_to_json kind
      ; ( "message_preview"
        , match message with
          | Some _ -> `String message_preview
          | None -> `Null )
      ; "message_truncated", `Bool message_truncated
      ]
  | _ -> `Null
;;

let compact_receipt_runtime_json receipt =
  match json_member "runtime" receipt with
  | `Assoc _ as runtime ->
    `Assoc
      [ "name", Json_util.string_opt_to_json (json_string "name" runtime)
      ; "selected_model", `Null
      ; "attempt_count", Json_util.int_opt_to_json (json_int "attempt_count" runtime)
      ; ( "fallback_applied"
        , Json_util.bool_opt_to_json (json_bool "fallback_applied" runtime) )
      ; "outcome", Json_util.string_opt_to_json (json_string "outcome" runtime)
      ; ( "degraded_retry_applied"
        , Json_util.bool_opt_to_json (json_bool "degraded_retry_applied" runtime) )
      ; ( "degraded_retry_runtime"
        , Json_util.string_opt_to_json (json_string "degraded_retry_runtime" runtime) )
      ; ( "fallback_reason"
        , Json_util.string_opt_to_json (json_string "fallback_reason" runtime) )
      ]
  | _ -> `Null
;;

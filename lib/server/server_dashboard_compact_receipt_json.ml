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

(* Which generation of the receipt the row in hand belongs to.

   The store has no version partition and [Keeper_execution_receipt.latest_json]
   hands back the newest row whatever its shape, so every keeper that has not
   taken a turn since the deploy is read through here.

   The question is answered once for the receipt, not per field. Before the
   split there was one bool named [degraded_retry_applied], always written, and
   no [degraded_retry_deferred] at all — and [json_member] answers `Null for a
   key that is not there. Reading the two fields independently would therefore
   mark the first unreadable and report the second as "this turn deferred no
   lane", which is a claim the old row cannot support. So the bool decides for
   both. *)
type receipt_lane_shape =
  | Lanes_split
  | Lanes_predate_the_split

let degraded_retry_shape runtime =
  match json_member "degraded_retry_applied" runtime with
  | `Assoc _ | `Null -> Lanes_split
  | `Bool _
  | `Int _
  | `Float _
  | `String _
  | `List _
  | `Intlit _
  | `Tuple _
  | `Variant _ -> Lanes_predate_the_split
;;

let unreadable_lane_json =
  `Assoc [ "runtime", `Null; "reason", `Null; "unreadable", `Bool true ]
;;

(* A deferred lane travels as one object so the runtime and the reason it was
   deferred for cannot be split apart on the way to the dashboard. Absent stays
   absent: a receipt that took up no lane says so with `Null, not with an
   object holding empty strings.

   Nothing here interprets an older row — that would be the compatibility
   reader the hard cut exists to avoid — but it must not read as "no retry"
   either, so it says [unreadable] and the dashboard prints that instead of
   nothing. *)
let compact_degraded_retry_json shape lane =
  match shape with
  | Lanes_predate_the_split -> unreadable_lane_json
  | Lanes_split ->
    (match lane with
     | `Assoc _ ->
       `Assoc
         [ "runtime", Json_util.string_opt_to_json (json_string "runtime" lane)
         ; "reason", Json_util.string_opt_to_json (json_string "reason" lane)
         ; "unreadable", `Bool false
         ]
     | `Null -> `Null
     (* The row is this generation's and this field still is not a lane. Not
        absence, so not `Null. *)
     | `Bool _
     | `Int _
     | `Float _
     | `String _
     | `List _
     | `Intlit _
     | `Tuple _
     | `Variant _ -> unreadable_lane_json)
;;

let compact_receipt_runtime_json receipt =
  match json_member "runtime" receipt with
  | `Assoc _ as runtime ->
    let shape = degraded_retry_shape runtime in
    `Assoc
      [ "name", Json_util.string_opt_to_json (json_string "name" runtime)
      ; "selected_model", `Null
      ; "attempt_count", Json_util.int_opt_to_json (json_int "attempt_count" runtime)
      ; ( "lane_attempt_count"
        , Json_util.int_opt_to_json (json_int "lane_attempt_count" runtime) )
      ; ( "fallback_applied"
        , Json_util.bool_opt_to_json (json_bool "fallback_applied" runtime) )
      ; "outcome", Json_util.string_opt_to_json (json_string "outcome" runtime)
      ; ( "degraded_retry_applied"
        , compact_degraded_retry_json shape (json_member "degraded_retry_applied" runtime) )
      ; ( "degraded_retry_deferred"
        , compact_degraded_retry_json shape (json_member "degraded_retry_deferred" runtime) )
      ]
  | _ -> `Null
;;

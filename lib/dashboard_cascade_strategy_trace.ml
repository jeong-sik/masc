(** Strategy-trace projection: shapes the most recent
    {!Cascade_strategy_trace} ring events for the dashboard. *)

open Dashboard_cascade_helpers

let strategy_trace_event_to_json (ev : Cascade_strategy_trace.event) : Yojson.Safe.t =
  let opt_float = function
    | Some f -> `Float f
    | None -> `Null
  in
  let cascade_name = Keeper_cascade_profile.runtime_name_to_string ev.cascade_name in
  let trace_id_json =
    match ev.trace_id with
    | None -> `Null
    | Some id -> `String id
  in
  `Assoc
    [ "ts", `Float ev.ts
    ; "cascade_name", `String cascade_name
    ; "strategy", `String ev.strategy
    ; "cycle", `Int ev.cycle
    ; "candidates_in", `Int ev.candidates_in
    ; "candidates_out", `Int ev.candidates_out
    ; "backoff_ms", `Int ev.backoff_ms
    ; "kind", `String (Cascade_strategy_trace.kind_to_string ev.kind)
    ; "trace_id", trace_id_json
    ; "confidence_score", opt_float ev.confidence_score
    ]
;;

let strategy_trace_json ?limit ?cascade () =
  let events = Cascade_strategy_trace.snapshot ?limit ?cascade () in
  let generated_at = now_iso () in
  `Assoc
    [ "updated_at", `String generated_at
    ; "generated_at_iso", `String generated_at
    ; "dashboard_surface", `String "/api/v1/cascade/strategy_trace"
    ; "source", `String "cascade_strategy_trace_ring"
    ; ( "retention"
      , retention_json
          ~scope:"cascade_strategy_trace"
          ~producer:"Cascade_strategy_trace.record"
          ~store_kind:"process_ring_buffer"
          ~ring_capacity:(Cascade_strategy_trace.capacity ())
          ~cache_policy:"uncached; reads the newest entries from the process ring buffer"
          () )
    ; ( "query"
      , cascade_query_json
          [ "limit", (match limit with None -> `Null | Some n -> `Int n)
          ; optional_string_field "cascade" cascade
          ] )
    ; "total_events", `Int (List.length events)
    ; "events", `List (List.map strategy_trace_event_to_json events)
    ]
;;

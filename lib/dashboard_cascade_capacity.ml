(** Client capacity registry + history projections.

    Projects the per-URL/sentinel slot table maintained by
    {!Cascade_client_capacity} and the ring buffer of acquire/release
    events from {!Cascade_client_capacity_history} into dashboard JSON. *)

open Dashboard_cascade_helpers

(** Classify a capacity registry key for the dashboard. CLI transports keep
    their sentinel label; HTTP endpoints are labelled by registered probe
    capability instead of by provider brand or default port. Everything else is
    [other], so operators can spot surprise registrations. *)
let classify_capacity_key url =
  if Masc_network_defaults.is_cli_sentinel_url url
  then "cli"
  else if Cascade_capacity_probe.can_probe ~url
  then "http_probe"
  else "other"
;;

let client_capacity_entry_to_json ((url, info) : string * Cascade_throttle.capacity_info)
  : Yojson.Safe.t
  =
  `Assoc
    [ "key", `String url
    ; "kind", `String (classify_capacity_key url)
    ; "total", `Int info.total
    ; "active", `Int info.process_active
    ; "available", `Int info.process_available
    ]
;;

let client_capacity_json () =
  let entries = Cascade_client_capacity.snapshot () in
  (* Stable ordering by (kind, key) so the dashboard table doesn't
     reshuffle on every poll.  Hashtbl iteration is unordered, so we
     sort here rather than depend on insertion order. *)
  let sorted =
    List.sort
      (fun (k1, _) (k2, _) ->
         let c1 = classify_capacity_key k1 in
         let c2 = classify_capacity_key k2 in
         match String.compare c1 c2 with
         | 0 -> String.compare k1 k2
         | n -> n)
      entries
  in
  let generated_at = now_iso () in
  `Assoc
    [ "updated_at", `String generated_at
    ; "generated_at_iso", `String generated_at
    ; "dashboard_surface", `String "/api/v1/cascade/client_capacity"
    ; "source", `String "cascade_client_capacity_registry"
    ; ( "retention"
      , retention_json
          ~scope:"cascade_client_capacity"
          ~producer:"Cascade_client_capacity.register"
          ~store_kind:"process_registry"
          ~cache_policy:"uncached; reads the live process-local registry" () )
    ; "entries", `List (List.map client_capacity_entry_to_json sorted)
    ]
;;

(* ── Client capacity history projection ─────────────────── *)

let event_kind_to_string = function
  | Cascade_client_capacity_history.Acquired -> "acquired"
  | Released -> "released"
  | Rejected_full -> "rejected_full"
;;

let history_event_to_json (ev : Cascade_client_capacity_history.event) : Yojson.Safe.t =
  `Assoc
    [ "ts", `Float ev.ts
    ; "key", `String ev.key
    ; "kind", `String (event_kind_to_string ev.kind)
    ; "active_after", `Int ev.active_after
    ]
;;

let client_capacity_history_json ?limit ?kind ?since_ts () =
  let events = Cascade_client_capacity_history.snapshot ?limit ?kind ?since_ts () in
  let generated_at = now_iso () in
  `Assoc
    [ "updated_at", `String generated_at
    ; "generated_at_iso", `String generated_at
    ; "dashboard_surface", `String "/api/v1/cascade/client_capacity/history"
    ; "source", `String "cascade_client_capacity_history_ring"
    ; ( "retention"
      , retention_json
          ~scope:"cascade_client_capacity_history"
          ~producer:"Cascade_client_capacity_history.record"
          ~store_kind:"process_ring_buffer"
          ~ring_capacity:(Cascade_client_capacity_history.capacity ())
          ~cache_policy:"uncached; reads the newest entries from the process ring buffer"
          () )
    ; ( "query"
      , cascade_query_json
          [ "limit", (match limit with None -> `Null | Some n -> `Int n)
          ; optional_string_field "kind" kind
          ; optional_float_field "since_ts" since_ts
          ] )
    ; "total_events", `Int (List.length events)
    ; "events", `List (List.map history_event_to_json events)
    ]
;;

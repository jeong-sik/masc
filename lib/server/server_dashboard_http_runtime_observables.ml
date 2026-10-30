(** Read surface for the runtime-observable store cells written by
    [Otel_runtime_observables]. masc#29023 decoupled sampling from OTLP
    export so the cells are populated with or without a collector; this
    module is the in-process consumer that makes them operator-visible.
    Served at [/api/v1/dashboard/runtime-observables]. *)

(* Every family below reads one detached [Otel_metric_store.snapshot]
   pass; labeled families are re-grouped into typed JSON blocks instead of
   a raw series dump so the frontend decodes a stable shape. *)

let served_metric_names =
  [ Otel_metric_store.metric_console_sink_dropped
  ; Otel_metric_store.metric_console_sink_queue_depth
  ; Otel_metric_store.metric_transition_audit_queue_depth
  ; Otel_metric_store.metric_fd_open
  ; Otel_metric_store.metric_fd_limit
  ; Otel_metric_store.metric_fd_active_operations
  ; Otel_metric_store.metric_fd_resource_errors
  ; Otel_metric_store.metric_store_bytes
  ; Otel_metric_store.metric_store_files
  ; Otel_metric_store.metric_bus_subscribers
  ; Otel_metric_store.metric_bus_subscriber_depth
  ; Otel_metric_store.metric_bus_subscriber_dropped
  ; Otel_metric_store.metric_agent_core_bus_capacity
  ; Otel_metric_store.metric_pool_idle
  ; Otel_metric_store.metric_pool_inflight
  ; Otel_metric_store.metric_pool_reuse
  ; Otel_metric_store.metric_pool_evict
  ; Otel_metric_store.metric_pool_evict_failure
  ; Otel_metric_store.metric_pool_create
  ; Otel_metric_store.metric_runtime_observables_last_write_unixtime
  ]
;;

let rows metrics name =
  List.filter
    (fun (m : Otel_metric_store.metric) -> String.equal m.name name)
    metrics
;;

let label (m : Otel_metric_store.metric) key = List.assoc_opt key m.labels

let unlabeled_value metrics name =
  List.find_map
    (fun (m : Otel_metric_store.metric) ->
       if String.equal m.name name && m.labels = [] then Some m.value else None)
    metrics
;;

(* Cells absent from the store (a process that never ran the writer) render
   as [null]: absence must stay distinguishable from a written zero. *)
let opt_int = function
  | Some v -> `Int (int_of_float v)
  | None -> `Null
;;

let console_sink_json metrics =
  `Assoc
    [ ( "queue_depth"
      , opt_int
          (unlabeled_value metrics Otel_metric_store.metric_console_sink_queue_depth) )
    ; ( "dropped_total"
      , opt_int (unlabeled_value metrics Otel_metric_store.metric_console_sink_dropped)
      )
    ]
;;

let transition_audit_json metrics =
  `Assoc
    [ ( "queue_depth"
      , opt_int
          (unlabeled_value
             metrics
             Otel_metric_store.metric_transition_audit_queue_depth) )
    ]
;;

let fd_json metrics =
  let active =
    rows metrics Otel_metric_store.metric_fd_active_operations
    |> List.filter_map (fun (m : Otel_metric_store.metric) ->
      match label m "kind" with
      | Some kind -> Some (kind, m.value)
      | None -> None)
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
    |> List.map (fun (kind, count) ->
      `Assoc [ "kind", `String kind; "count", `Int (int_of_float count) ])
  in
  let errors =
    rows metrics Otel_metric_store.metric_fd_resource_errors
    |> List.filter_map (fun (m : Otel_metric_store.metric) ->
      match label m "kind", label m "error" with
      | Some kind, Some error -> Some (kind, error, m.value)
      | _ -> None)
    |> List.sort (fun (ka, ea, _) (kb, eb, _) ->
      match String.compare ka kb with
      | 0 -> String.compare ea eb
      | c -> c)
    |> List.map (fun (kind, error, count) ->
      `Assoc
        [ "kind", `String kind
        ; "error", `String error
        ; "count", `Int (int_of_float count)
        ])
  in
  `Assoc
    [ "open", opt_int (unlabeled_value metrics Otel_metric_store.metric_fd_open)
    ; "limit", opt_int (unlabeled_value metrics Otel_metric_store.metric_fd_limit)
    ; "active_operations", `List active
    ; "resource_errors", `List errors
    ]
;;

let stores_json metrics =
  let files_for store =
    rows metrics Otel_metric_store.metric_store_files
    |> List.find_map (fun (m : Otel_metric_store.metric) ->
      if label m "store" = Some store then Some m.value else None)
  in
  rows metrics Otel_metric_store.metric_store_bytes
  |> List.filter_map (fun (m : Otel_metric_store.metric) ->
    match label m "store" with
    | Some store -> Some (store, m.value)
    | None -> None)
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  |> List.map (fun (store, bytes) ->
    `Assoc
      [ "store", `String store
      ; "bytes", `Int (int_of_float bytes)
      ; "files", opt_int (files_for store)
      ])
  |> fun entries -> `List entries
;;

let event_bus_json metrics =
  let canon (m : Otel_metric_store.metric) = List.sort compare m.labels in
  let find_by_labels rows_ canon_labels =
    List.find_map
      (fun (m : Otel_metric_store.metric) ->
         if canon m = canon_labels then Some m.value else None)
      rows_
  in
  let depth_rows = rows metrics Otel_metric_store.metric_bus_subscriber_depth in
  let dropped_rows = rows metrics Otel_metric_store.metric_bus_subscriber_dropped in
  let capacity_rows = rows metrics Otel_metric_store.metric_agent_core_bus_capacity in
  rows metrics Otel_metric_store.metric_bus_subscribers
  |> List.filter_map (fun (m : Otel_metric_store.metric) ->
    match label m "bus" with
    | Some bus -> Some (bus, m.value)
    | None -> None)
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  |> List.map (fun (bus, subscribers) ->
    let contracts =
      depth_rows
      |> List.filter (fun m -> label m "bus" = Some bus)
      |> List.sort (fun a b -> compare (canon a) (canon b))
      |> List.map (fun (m : Otel_metric_store.metric) ->
        let canon_labels = canon m in
        (* The producer encodes an absent subscription purpose as
           "unspecified" (bus_samples_of); mirroring that encoding is a
           projection of the producer's own default, not a guess on
           unknown input. sound-partial: allow *)
        let purpose = Option.value (label m "purpose") ~default:"unspecified" in
        let overflow = Option.value (label m "overflow") ~default:"unspecified" in
        `Assoc
          [ "purpose", `String purpose
          ; ( "capacity"
            , match Option.bind (label m "capacity") int_of_string_opt with
              | Some capacity -> `Int capacity
              | None -> `Null )
          ; "overflow", `String overflow
          ; "depth", `Int (int_of_float m.value)
          ; "dropped_total", opt_int (find_by_labels dropped_rows canon_labels)
          ; "capacity_total", opt_int (find_by_labels capacity_rows canon_labels)
          ])
    in
    `Assoc
      [ "bus", `String bus
      ; "subscribers", `Int (int_of_float subscribers)
      ; "contracts", `List contracts
      ])
  |> fun entries -> `List entries
;;

let pool_json metrics =
  let v name = opt_int (unlabeled_value metrics name) in
  `Assoc
    [ "idle", v Otel_metric_store.metric_pool_idle
    ; "inflight", v Otel_metric_store.metric_pool_inflight
    ; "reuse_total", v Otel_metric_store.metric_pool_reuse
    ; "evict_total", v Otel_metric_store.metric_pool_evict
    ; "evict_failure_total", v Otel_metric_store.metric_pool_evict_failure
    ; "create_total", v Otel_metric_store.metric_pool_create
    ]
;;

let runtime_observables_http_json () =
  let metrics = Otel_metric_store.snapshot () in
  let last_write =
    unlabeled_value
      metrics
      Otel_metric_store.metric_runtime_observables_last_write_unixtime
  in
  let last_write_json, age_json =
    (* NDT-OK: wall-clock feeds only the presented age of the freshness
       stamp; no deterministic branch depends on the value. *)
    let now = Unix.gettimeofday () in
    match last_write with
    | Some t -> `Float t, `Float (Float.max 0.0 (now -. t))
    | None -> `Null, `Null
  in
  `Assoc
    [ "last_write_unixtime", last_write_json
    ; "age_seconds", age_json
    ; "console_sink", console_sink_json metrics
    ; "transition_audit", transition_audit_json metrics
    ; "fd", fd_json metrics
    ; "stores", stores_json metrics
    ; "event_bus", event_bus_json metrics
    ; "pool", pool_json metrics
    ]
;;

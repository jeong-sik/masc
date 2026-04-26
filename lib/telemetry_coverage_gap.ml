(** Durable telemetry coverage gaps.

    This store records write-path failures that leave one telemetry lane behind
    another.  Unified telemetry can then surface the gap even when the primary
    lane itself has no fresh rows to read. *)

let store_dir masc_root = Filename.concat masc_root "telemetry-coverage-gaps"

let string_opt_json = function
  | Some value when String.trim value <> "" -> `String value
  | _ -> `Null
;;

let record
      ~masc_root
      ~source
      ~producer
      ~durable_store
      ~dashboard_surface
      ~stale_reason
      ?keeper_name
      ?trace_id
      ?error
      ()
  =
  Prometheus.inc_counter
    Prometheus.metric_telemetry_coverage_gap
    ~labels:
      [ "source", source
      ; "producer", producer
      ; "dashboard_surface", dashboard_surface
      ; "stale_reason", stale_reason
      ]
    ();
  let store = Dated_jsonl.create ~base_dir:(store_dir masc_root) () in
  let now = Time_compat.now () in
  let json =
    `Assoc
      [ "schema", `String "masc.telemetry_coverage_gap.v1"
      ; "ts", `Float now
      ; "ts_iso", `String (Types.iso8601_of_unix_seconds now)
      ; "source", `String source
      ; "producer", `String producer
      ; "durable_store", `String durable_store
      ; "dashboard_surface", `String dashboard_surface
      ; "stale_reason", `String stale_reason
      ; "keeper_name", string_opt_json keeper_name
      ; "trace_id", string_opt_json trace_id
      ; "error", string_opt_json error
      ]
  in
  Dated_jsonl.append store json
;;

let read_recent ~masc_root ~n =
  if n <= 0
  then []
  else (
    let dir = store_dir masc_root in
    if not (Sys.file_exists dir)
    then []
    else Dated_jsonl.read_recent (Dated_jsonl.create ~base_dir:dir ()) n)
;;

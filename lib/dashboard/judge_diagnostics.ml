(* #9774: shared helpers for governance / operator judge LLM-output
   diagnostics. Formatting remains pure; [record_lenient_fallback]
   is the explicit metric-emitting wrapper used by production fallback
   branches. *)

(* Truncate a string to at most [max_bytes] bytes, appending an ellipsis
   marker that records how many bytes were dropped. Byte-count is
   acceptable here because the consumer is a log line, not a UI surface. *)
let truncate_with_marker ?(max_bytes = 500) s =
  let len = String.length s in
  if len <= max_bytes then s
  else String.sub s 0 max_bytes ^ Printf.sprintf "…[+%d chars]" (len - max_bytes)

(* When a judge's [Lenient_json.parse] returns the [`Assoc [("raw", _)]]
   fallback, format a single message that names the judge, the raw size,
   and a bounded preview. The same string is used both as the warn log
   payload and as the [Error] returned upstream so any consumer sees the
   diagnostic without enabling raw provider logging. *)
let format_lenient_fallback ~judge_label raw =
  Printf.sprintf
    "%s judge returned unparseable response (Lenient_json fallback hit; %d chars; preview: %s)"
    judge_label
    (String.length raw)
    (truncate_with_marker raw)

let record_lenient_fallback ~judge_label raw =
  let labels = [("judge", String.lowercase_ascii judge_label)] in
  Prometheus.inc_counter
    Prometheus.metric_governance_judge_unparseable
    ~labels
    ();
  Prometheus.inc_counter
    Prometheus.metric_governance_lenient_json_fallback_hit
    ~labels
    ();
  format_lenient_fallback ~judge_label raw

let int_metric_value metric_name ~labels =
  int_of_float (Prometheus.metric_value_or_zero metric_name ~labels ())

let lenient_fallback_metrics_json ~judge_label =
  let judge = String.lowercase_ascii judge_label in
  let labels = [("judge", judge)] in
  `Assoc
    [
      ("judge", `String judge);
      ( "governance_judge_unparseable_total",
        `Int
          (int_metric_value Prometheus.metric_governance_judge_unparseable
             ~labels) );
      ( "governance_lenient_json_fallback_hit_total",
        `Int
          (int_metric_value
             Prometheus.metric_governance_lenient_json_fallback_hit ~labels) );
    ]

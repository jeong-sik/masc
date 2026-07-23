(* #9774: shared helpers for structured judge LLM-output
   diagnostics. Formatting remains pure. [record_lenient_fallback] keeps the
   legacy metric counter name for dashboard compatibility, but structured-output
   judges no longer recover prose-prefixed JSON. *)

(* Truncate a string to at most [max_bytes] bytes, appending an ellipsis
   marker that records how many bytes were dropped. Byte-count is
   acceptable here because the consumer is a log line, not a UI surface. *)
let truncate_with_marker ?(max_bytes = 500) s =
  let len = String.length s in
  if len <= max_bytes then s
  else String.sub s 0 max_bytes ^ Printf.sprintf "…[+%d chars]" (len - max_bytes)

(* Format a single message that names the judge, the raw size, and a bounded
   preview. The same string is used both as the warn log payload and as the
   [Error] returned upstream so any consumer sees the diagnostic without
   enabling raw provider logging. *)
let format_lenient_fallback ~judge_label raw =
  Printf.sprintf
    "%s judge returned unparseable structured response (parse failure; %d chars; preview: %s)"
    judge_label
    (String.length raw)
    (truncate_with_marker raw)

let format_unparseable_response ~judge_label ~reason raw =
  Printf.sprintf
    "%s judge returned structurally invalid response (%s; %d chars; preview: %s)"
    judge_label
    reason
    (String.length raw)
    (truncate_with_marker raw)

let record_lenient_fallback ~judge_label raw =
  let labels = [("judge", String.lowercase_ascii judge_label)] in
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_structured_judge_unparseable
    ~labels
    ();
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_structured_judge_lenient_json_fallback_hit
    ~labels
    ();
  format_lenient_fallback ~judge_label raw

let record_unparseable_response ~judge_label ~reason raw =
  let labels = [("judge", String.lowercase_ascii judge_label)] in
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_structured_judge_unparseable
    ~labels
    ();
  format_unparseable_response ~judge_label ~reason raw

let int_metric_value metric_name ~labels =
  int_of_float (Otel_metric_store.metric_value_or_zero metric_name ~labels ())

let lenient_fallback_metrics_json ~judge_label =
  let judge = String.lowercase_ascii judge_label in
  let labels = [("judge", judge)] in
  `Assoc
    [
      ("judge", `String judge);
      ( "structured_judge_unparseable_total",
        `Int
          (int_metric_value Otel_metric_store.metric_structured_judge_unparseable
             ~labels) );
      ( "structured_judge_lenient_json_fallback_hit_total",
        `Int
          (int_metric_value
             Otel_metric_store.metric_structured_judge_lenient_json_fallback_hit
             ~labels) );
    ]

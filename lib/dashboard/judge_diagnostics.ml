(* #9774: shared helpers for governance / operator judge LLM-output
   diagnostics. Formatting remains pure; [record_strict_json_parse_reject]
   is the explicit metric-emitting wrapper used by production strict-parse
   rejection branches. *)

(* Truncate a string to at most [max_bytes] bytes, appending an ellipsis
   marker that records how many bytes were dropped. Byte-count is
   acceptable here because the consumer is a log line, not a UI surface. *)
let truncate_with_marker ?(max_bytes = 500) s =
  let len = String.length s in
  if len <= max_bytes then s
  else String.sub s 0 max_bytes ^ Printf.sprintf "…[+%d chars]" (len - max_bytes)

(* When the provider-native strict JSON parser rejects a judge response,
   format a single message that names the judge, the raw size, and a bounded
   preview. The same string is used both as the warn log payload and as the
   [Error] returned upstream so any consumer sees the diagnostic without
   enabling raw provider logging. *)
let format_strict_json_parse_reject ~judge_label raw =
  Printf.sprintf
    "%s judge returned unparseable response (strict JSON parse rejected; %d chars; preview: %s)"
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

let record_strict_json_parse_reject ~judge_label raw =
  let labels = [("judge", String.lowercase_ascii judge_label)] in
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_governance_judge_unparseable
    ~labels
    ();
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_governance_strict_json_parse_reject
    ~labels
    ();
  format_strict_json_parse_reject ~judge_label raw

let record_unparseable_response ~judge_label ~reason raw =
  let labels = [("judge", String.lowercase_ascii judge_label)] in
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_governance_judge_unparseable
    ~labels
    ();
  format_unparseable_response ~judge_label ~reason raw

let int_metric_value metric_name ~labels =
  int_of_float (Otel_metric_store.metric_value_or_zero metric_name ~labels ())

let strict_json_parse_metrics_json ~judge_label =
  let judge = String.lowercase_ascii judge_label in
  let labels = [("judge", judge)] in
  `Assoc
    [
      ("judge", `String judge);
      ( "governance_judge_unparseable_total",
        `Int
          (int_metric_value Otel_metric_store.metric_governance_judge_unparseable
             ~labels) );
      ( "governance_strict_json_parse_reject_total",
        `Int
          (int_metric_value
             Otel_metric_store.metric_governance_strict_json_parse_reject ~labels) );
    ]

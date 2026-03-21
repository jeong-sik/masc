type metrics_summary

val empty_metrics_summary : metrics_summary
val metrics_summary_to_json : metrics_summary -> Yojson.Safe.t
val summarize_metrics_lines :
  string list -> default_generation:int -> metrics_summary

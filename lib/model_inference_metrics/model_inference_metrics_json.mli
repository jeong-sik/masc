(** JSON and prompt serializers for model inference metrics. *)

open Model_inference_metrics_entry

val to_json : aggregate -> Yojson.Safe.t
val render_keeper_prompt_feedback : aggregate -> string
(** Redacted planning feedback. Pricing and billing fields are excluded. *)
val compute_cost_latency_json :
  base_path:string -> window_minutes:int -> Yojson.Safe.t

(** Operator-only runtime history. Groups by the exact executed runtime from
    decision records; unpaired cost observations and records without an answerer
    remain unattributed. The window and store diagnostics accompany the samples.
    Call this from an asynchronous cached producer, never on a request's I/O path. *)
val compute_runtime_metrics_json : base_path:string -> window_minutes:int -> Yojson.Safe.t

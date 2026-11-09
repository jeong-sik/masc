(** Run metrics — the quantitative record one agent run can carry.

    [metric_value] is a closed variant. [run_metrics] groups the metrics and
    {!Harness.verdict}s of a run and serializes to JSON for the trajectory
    record.

    @stability Evolving
    @since 0.93.1 *)

(** {1 Metric value} *)

(** A metric value: typed scalar. *)
type metric_value =
  | Int_val of int
  | Float_val of float
  | Bool_val of bool
  | String_val of string

val metric_value_to_yojson : metric_value -> Yojson.Safe.t

(** {1 Metric} *)

(** A named metric with optional unit and tags. *)
type metric =
  { name : string
  ; value : metric_value
  ; unit_ : string option
  ; tags : (string * string) list
  }

val metric_to_yojson : metric -> Yojson.Safe.t

(** {1 Run metrics} *)

(** Metrics and harness verdicts of one agent run. *)
type run_metrics =
  { run_id : string
  ; agent_name : string
  ; timestamp : float
  ; metrics : metric list
  ; harness_verdicts : Harness.verdict list
  }

val run_metrics_to_yojson : run_metrics -> Yojson.Safe.t

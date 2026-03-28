(** Golden_set — Baseline evaluation fixtures for coding_task workloads.

    Provides representative positive, negative, edge, and drift probe
    cases for CDAL evaluator calibration per RFC #3475 Labeling Protocol
    Section 4.

    Minimum sizes: positive 20+, negative 20+, edge 5+, drift 5+. *)

type case_class =
  | Positive
  | Negative
  | Edge
  | Drift_probe

type golden_case = {
  case_id : string;
  case_class : case_class;
  task_title : string;
  task_description : string;
  expected_verdict : string;  (** "pass" | "fail" | "ambiguous" *)
  risk_class : string;        (** "low" | "medium" | "high" | "critical" *)
  tags : string list;
}

val all_cases : golden_case list
(** The complete golden set. *)

val positive_cases : golden_case list
val negative_cases : golden_case list
val edge_cases : golden_case list
val drift_probes : golden_case list

val case_class_to_string : case_class -> string
val case_to_yojson : golden_case -> Yojson.Safe.t

type baseline_lock = {
  golden_set_version : string;
  schema_version : string;
  case_count : int;
  positive_count : int;
  negative_count : int;
  edge_count : int;
  drift_count : int;
  created_at_iso : string;
}

val current_lock : baseline_lock
(** The current baseline measurement lock. *)

val lock_to_yojson : baseline_lock -> Yojson.Safe.t

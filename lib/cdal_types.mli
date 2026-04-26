(** Cdal_types -- Typed CDAL verdict and check-result types.

    Phase 1A foundation: replaces loose JSON with structured OCaml types
    for contract status, findings, completeness gaps, and verdicts.
    All types support canonical JSON serialization with sorted keys
    and content-addressed hashing (judgment_hash).

    @since CDAL Phase 1A *)

(** Contract check status. *)
type contract_status =
  | Satisfied
  | Violated
  | Inconclusive

(** Whether a completeness gap blocks the verdict or is annotation-only. *)
type completeness_impact =
  | Blocks_verdict
  | Annotation_only

(** A single finding from a contract check. *)
type contract_finding =
  { check_id : string
  ; event_id : string option
  ; observed : Yojson.Safe.t
  ; expected : Yojson.Safe.t
  ; trace_ref : string option
  }

(** A gap in the evidence completeness. *)
type completeness_gap =
  { artifact : string
  ; reason : string
  ; impact : completeness_impact
  }

(** Result of a single contract check. *)
type check_result =
  { check_id : string
  ; status : contract_status
  ; findings : contract_finding list
  ; completeness_gaps : completeness_gap list
  }

(** Full verdict for a contract evaluation run. *)
type contract_verdict =
  { run_id : string
  ; contract_id : string
  ; claim_scope : string
  ; judgment_basis_hash : string
  ; judgment_hash : string
  ; loader_semantics_version : string
  ; schema_compat_mode : string
  ; status : contract_status
  ; findings : contract_finding list
  ; completeness_gaps : completeness_gap list
  ; check_results : check_result list
  }

(** {2 Claim scope constant} *)

val claim_scope_phase1 : string
val loader_semantics_version_phase1 : string
val schema_compat_mode_v1 : string

(** {2 String conversions} *)

val contract_status_to_string : contract_status -> string
val contract_status_of_string : string -> (contract_status, string) result
val completeness_impact_to_string : completeness_impact -> string
val completeness_impact_of_string : string -> (completeness_impact, string) result

(** {2 JSON serialization}

    All [to_json] functions produce canonical JSON with sorted keys
    via [Yojson.Safe.sort]. *)

val contract_finding_to_json : contract_finding -> Yojson.Safe.t
val contract_finding_of_json : Yojson.Safe.t -> (contract_finding, string) result
val completeness_gap_to_json : completeness_gap -> Yojson.Safe.t
val completeness_gap_of_json : Yojson.Safe.t -> (completeness_gap, string) result
val check_result_to_json : check_result -> Yojson.Safe.t
val check_result_of_json : Yojson.Safe.t -> (check_result, string) result
val contract_verdict_to_json : contract_verdict -> Yojson.Safe.t
val contract_verdict_of_json : Yojson.Safe.t -> (contract_verdict, string) result

(** {2 Hashing}

    [compute_judgment_hash] computes MD5 of the canonical JSON
    representation with [judgment_hash] set to [""] during computation. *)

val compute_judgment_hash : contract_verdict -> string

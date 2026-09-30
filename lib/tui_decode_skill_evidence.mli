(** Strict hard-cut decoder for [/api/v1/skills/evidence]. The endpoint's
    current projection is explicitly incomplete; missing or weakened coverage
    fields are rejected instead of becoming zeroes in the terminal. *)
type skill_evidence_status =
  | Skill_evidence_observed
  | Skill_evidence_not_observed_in_retained_coverage

type skill_evidence_composition_scope =
  | Skill_evidence_exact_reference_latest_completed
  | Skill_evidence_composition_unavailable

type skill_evidence_coverage =
  { sec_composition_scope : skill_evidence_composition_scope
  ; sec_composition_records_read : int
  ; sec_composition_unavailable : string list
  ; sec_activation_scope : string
  ; sec_activation_sessions_inspected : int
  ; sec_activation_ledgers_loaded : int
  ; sec_activation_gap_count : int
  ; sec_activation_owner_gap_count : int
  }

type skill_evidence_owner_claim =
  { seo_keeper : string
  ; seo_source : string
  }

type skill_evidence_activation_item =
  { sea_trace_id : string
  ; sea_owner_status : string
  ; sea_owner_claims : skill_evidence_owner_claim list
  ; sea_owner_gap_count : int
  ; sea_activation : Yojson.Safe.t
  }

type skill_evidence_activation =
  | Skill_evidence_most_recent_observed of skill_evidence_activation_item
  | Skill_evidence_most_recent_observed_timestamp_tie of
      skill_evidence_activation_item list

type skill_evidence =
  { se_status : skill_evidence_status
  ; se_activation : skill_evidence_activation option
  ; se_composition : Yojson.Safe.t option
  ; se_coverage : skill_evidence_coverage
  }

val decode_skill_evidence : Yojson.Safe.t -> (skill_evidence, string) result

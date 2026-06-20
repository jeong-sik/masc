(** Skill_candidate_projection — read-side draft skill candidates from MASC
    memory.

    This module is deliberately advisory. It projects crystallized procedures
    into reviewable skill candidates, but never installs skills or injects them
    into keeper prompts. *)

type promotion_state = Candidate

type skill_candidate =
  { id : string
  ; agent_name : string
  ; source_kind : string
  ; source_id : string
  ; source_ref : string
  ; pattern : string
  ; evidence_refs : string list
  ; success_count : int
  ; failure_count : int
  ; confidence : float
  ; applicable_tools : string list
  ; promotion_state : promotion_state
  ; risk_notes : string list
  }

val promotion_state_to_string : promotion_state -> string

(** Stable URI for a procedure row. *)
val source_procedure_ref : Procedural_memory.procedure -> string

(** Stable URI for a Memory OS fact row. *)
val source_memory_fact_ref
  :  agent_name:string
  -> Keeper_memory_os_types.fact
  -> string

(** Project one crystallized procedure into a candidate. Non-crystallized
    procedures return [None]. *)
val candidate_of_procedure : Procedural_memory.procedure -> skill_candidate option

(** Project one Memory OS fact into a candidate. Only [Validated_approach] and
    [Lesson] facts are eligible; other facts return [None]. *)
val candidate_of_memory_fact
  :  agent_name:string
  -> Keeper_memory_os_types.fact
  -> skill_candidate option

(** Project and sort candidates by confidence. *)
val candidates_of_procedures : Procedural_memory.procedure list -> skill_candidate list

(** Project eligible Memory OS facts and sort them by confidence. Memory OS facts
    do not carry numeric outcome confidence, so candidates use [0.0] until a
    human or verifier links concrete outcome evidence. *)
val candidates_of_memory_facts
  :  agent_name:string
  -> Keeper_memory_os_types.fact list
  -> skill_candidate list

(** Load the top crystallized procedures for [agent_name] and project them to
    candidates. *)
val top_candidates : agent_name:string -> limit:int -> skill_candidate list

val to_json : skill_candidate -> Yojson.Safe.t

(** Render a human-reviewable SKILL.md draft. The rendered text remains marked
    as [candidate] and must not be installed without approval. *)
val render_skill_draft : skill_candidate -> string

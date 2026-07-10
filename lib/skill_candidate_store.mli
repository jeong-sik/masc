(** Durable draft-skill candidate store.

    This is the write-side companion to {!Skill_candidate_projection}. It
    persists reviewable draft artifacts under [.masc/draft-skills/] but never
    installs a skill or changes Keeper runtime capability. *)

type stored_draft =
  { candidate : Skill_candidate_projection.skill_candidate
  ; dir : string
  ; json_path : string
  ; toml_path : string
  ; skill_md_path : string
  ; index_path : string
  }

type draft_summary =
  { id : string
  ; agent_name : string
  ; source_kind : string
  ; source_ref : string
  ; promotion_state : string
  ; dir : string
  ; json_path : string
  ; toml_path : string
  ; skill_md_path : string
  ; created_at : float option
  }

type draft_listing =
  { total : int
  ; shown : int
  ; limit : int
  ; index_path : string
  ; items : draft_summary list
  }

val drafts_dir : base_path:string -> string

(** Durable artifact directory for one candidate. The directory key includes
    source identity, not just display [id], so different keepers/sources with the
    same candidate id do not overwrite each other. *)
val draft_dir : base_path:string -> Skill_candidate_projection.skill_candidate -> string

val index_path : base_path:string -> string

(** Render a compact metadata TOML for operator review. This is intentionally
    candidate-only and includes no executable install marker. *)
val render_candidate_toml : Skill_candidate_projection.skill_candidate -> string

(** Persist [candidate.json], [candidate.toml], [SKILL.md], and append a compact
    [index.jsonl] event. All paths are under [.masc/draft-skills/]. *)
val write_candidate
  :  base_path:string
  -> Skill_candidate_projection.skill_candidate
  -> (stored_draft, string) result

val write_candidates
  :  base_path:string
  -> Skill_candidate_projection.skill_candidate list
  -> (stored_draft list, string) result

(** Close the post-turn Memory OS -> draft skill loop for one keeper.

    Reads recent Memory OS facts for [keeper_id] and crystallized procedural
    memories, projects only reviewable candidates, and writes changed drafts
    under [.masc/draft-skills/]. This remains advisory: it never installs a
    skill or changes Keeper runtime capability. *)
val write_post_turn_candidates
  :  base_path:string
  -> keeper_id:string
  -> fact_tail_limit:int
  -> procedure_limit:int
  -> (stored_draft list, string) result

val write_all_post_turn_candidates
  :  base_path:string
  -> keeper_id:string
  -> fact_tail_limit:int
  -> (stored_draft list, string) result
(** Production post-turn projection with no arbitrary procedure-count cap.
    Every crystallized procedure is considered. Fact and procedure JSONL are
    both loaded via strict parsers so malformed persisted rows are explicit
    errors rather than silent omissions. *)

(** Read the latest unique candidate rows from [.masc/draft-skills/index.jsonl],
    newest first. Missing index files return an empty listing. *)
val list_drafts : base_path:string -> limit:int -> (draft_listing, string) result

val draft_summary_to_json : draft_summary -> Yojson.Safe.t

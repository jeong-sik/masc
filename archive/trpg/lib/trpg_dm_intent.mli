(** trpg_dm_intent.mli — DM Intent Extraction (keyword + LLM hybrid).

    Extracts DM's narrative intent from their action text.
    Mode selection via MASC_TRPG_DM_INTENT_MODE:
    - keyword: Pure keyword matching, zero latency
    - llm: LLM structured classification via Llm_orchestration cascade
    - hybrid (default): LLM with keyword fallback on failure

    @since 2.70.0 *)

(** Categories of DM intent. *)
type intent_category =
  | Combat_setup       (** Monsters appear, weapons drawn, initiative *)
  | Social_encounter   (** NPCs speak, negotiate, persuade *)
  | Puzzle_challenge   (** Riddles, traps, mechanisms, investigation *)
  | Exploration        (** Travel, discover, describe environment *)
  | Rest_downtime      (** Camp, heal, craft, shop *)
  | Plot_reveal        (** Lore, backstory, revelation *)
  | Tension_building   (** Ominous signs, foreshadowing, atmosphere *)
  | Unknown            (** No clear intent detected *)

(** Extracted DM intent with confidence. *)
type dm_intent = {
  primary : intent_category;
  secondary : intent_category option;  (** Second strongest signal, if any *)
  confidence : float;                  (** 0.0-1.0 *)
  keywords_matched : string list;      (** Which keywords triggered the match *)
  mode : string;                       (** keyword | llm | hybrid *)
  provenance : string;                 (** judgment | derived | fallback *)
}

(** Extract DM intent from action text.
    In keyword mode: keyword pattern matching.
    In llm mode: LLM structured classification (returns Unknown on failure).
    In hybrid mode: LLM first, keyword fallback on failure. *)
val extract : string -> dm_intent

(** Convert intent to a one-line hint for player keeper prompts. *)
val to_hint : dm_intent -> string

(** String representation of intent category. *)
val string_of_category : intent_category -> string

(** Parse intent category from string (case-insensitive, accepts aliases). *)
val category_of_string : string -> intent_category

(** Parse dm_intent from LLM text response (JSON extraction).
    Exposed for testing. *)
val parse_llm_intent : string -> (dm_intent, string) result

(** Serialize to JSON. *)
val to_yojson : dm_intent -> Yojson.Safe.t

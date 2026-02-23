(** trpg_dm_intent.mli — DM Intent Extraction (deterministic, keyword-based).

    Extracts DM's narrative intent from their action text.
    No LLM required - pure keyword matching for reproducibility and zero cost.

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
}

(** Extract DM intent from action text.
    Analyzes the text for keyword patterns associated with each intent category.
    Returns the strongest match, or Unknown if no patterns exceed threshold. *)
val extract : string -> dm_intent

(** Convert intent to a one-line hint for player keeper prompts. *)
val to_hint : dm_intent -> string

(** String representation of intent category. *)
val string_of_category : intent_category -> string

(** Serialize to JSON. *)
val to_yojson : dm_intent -> Yojson.Safe.t

(** trpg_bdi.mli -- BDI (Belief-Desire-Intention) Memory Module.

    Based on CharacterBox (NAACL 2025) BDI mechanisms.
    Each Keeper maintains beliefs (with confidence decay),
    desires (prioritized goals), and intentions (active plans).

    @since 2.70.0 *)

(** A belief about the game world or other characters. *)
type belief = {
  subject : string;       (** What/who this belief is about *)
  content : string;       (** The belief content *)
  confidence : float;     (** 0.0-1.0, decays over time *)
  source_turn : int;      (** Turn number when formed *)
  last_reinforced : int;  (** Turn number when last confirmed *)
}

(** A character's desire/goal. *)
type desire = {
  goal : string;          (** What the character wants *)
  priority : float;       (** 0.0-1.0, higher = more important *)
  category : string;      (** e.g. "survival", "social", "quest" *)
  active : bool;          (** Whether still pursuing *)
}

(** An active intention/plan. *)
type intention = {
  plan : string;          (** Current plan description *)
  target_desire : string; (** Which desire this serves *)
  progress : float;       (** 0.0-1.0 completion *)
  blocked : bool;         (** Whether currently blocked *)
}

(** Full BDI state for one actor. *)
type bdi_state = {
  actor_id : string;
  beliefs : belief list;
  desires : desire list;
  intentions : intention list;
  turn_number : int;      (** Current game turn for decay calculation *)
}

(** Empty initial state for an actor. *)
val empty : actor_id:string -> bdi_state

(** Apply confidence decay to all beliefs based on turns elapsed.
    Decay formula: confidence * 0.95^(current_turn - last_reinforced) *)
val decay_beliefs : current_turn:int -> bdi_state -> bdi_state

(** Add or reinforce a belief. If a belief with same subject exists, update it. *)
val update_belief : subject:string -> content:string -> confidence:float -> turn:int -> bdi_state -> bdi_state

(** Add or update a desire. *)
val update_desire : goal:string -> priority:float -> category:string -> bdi_state -> bdi_state

(** Set a desire as inactive (fulfilled or abandoned). *)
val deactivate_desire : goal:string -> bdi_state -> bdi_state

(** Add or update an intention. *)
val update_intention : plan:string -> target_desire:string -> progress:float -> bdi_state -> bdi_state

(** Mark an intention as blocked. *)
val block_intention : plan:string -> bdi_state -> bdi_state

(** Remove beliefs below confidence threshold. Default threshold: 0.1 *)
val prune_beliefs : ?threshold:float -> bdi_state -> bdi_state

(** Generate a prompt fragment summarizing the BDI state for inclusion in keeper prompts.
    Max length is soft-capped at max_len characters. *)
val to_prompt_fragment : ?max_len:int -> bdi_state -> string

(** Serialize BDI state to JSON. *)
val to_yojson : bdi_state -> Yojson.Safe.t

(** Deserialize BDI state from JSON. *)
val of_yojson : Yojson.Safe.t -> (bdi_state, string) result

(** Load BDI state from file. Returns empty state if file doesn't exist. *)
val load : room_dir:string -> actor_id:string -> bdi_state

(** Save BDI state to file. *)
val save : room_dir:string -> bdi_state -> (unit, string) result

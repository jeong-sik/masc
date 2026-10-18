(** Exact source messages omitted after an exhausted single-message walk.
    The inference caller must establish that exhaustion before recording. *)
type source =
  | Atom of
      { trace_id : string
      ; history_start_boundary_line : int
      ; atom : int
      ; message_in_atom : int
      ; message_sha256 : string
      }
  | Official_turn of
      { turn_ref : Ids.Turn_ref.t
      ; boundary_line : int
      ; message_in_turn : int
      ; message_sha256 : string
      }
type t = private
  { source : source
  ; reasons : Keeper_librarian_input_refusal.t list
      (** Nonempty canonical set of actual named provider refusals. *)
  }

val message_digest : Agent_core.Types.message -> string
val source_to_json : source -> Yojson.Safe.t
val source_of_json : Yojson.Safe.t -> (source, string) result
(** The shared exact source identity for processed messages and unread holes.
    Decoding validates coordinates and digest without inventing a refusal. *)

val sources_for_atom_range :
  trace_id:string -> history_start_boundary_line:int -> start_atom:int -> end_atom:int ->
  messages:Agent_core.Types.message list -> (source list, string) result
(** Enumerate every exact unpinned message in the original complete atom range,
    using the same checkpoint labelling as unread holes. *)

val for_atom
  : trace_id:string -> history_start_boundary_line:int -> atom:int
  -> message_in_atom:int -> messages:Agent_core.Types.message list
  -> reasons:Keeper_librarian_input_refusal.t list -> (t, string) result
(** Locate and hash the exact message using shared checkpoint atom labelling.
    Pinned messages cannot become holes. *)
val for_official_turn
  : turn_ref:Ids.Turn_ref.t -> boundary_line:int -> message_in_turn:int
  -> messages:Agent_core.Types.message list
  -> reasons:Keeper_librarian_input_refusal.t list -> (t, string) result
(** [messages] is the exact selected source list of this official turn. *)
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Field-exact; unknown or empty refusal sets are rejected. *)
val list_to_json : t list -> Yojson.Safe.t
val list_of_json : Yojson.Safe.t -> (t list, string) result
(** Duplicate source coordinates, including conflicting hashes, are rejected. *)
val validate_atom_bounds
  : trace_id:string -> history_start_boundary_line:int -> end_atom:int
  -> t list -> (unit, string) result
(** All holes must be atom messages within this snapshot's history generation
    and exclusive end. Official-turn holes belong to their own receipt. *)
val validate_atom_history
  : trace_id:string -> history_start_boundary_line:int -> end_atom:int
  -> messages:Agent_core.Types.message list -> t list -> (unit, string) result
(** Also verify every exact message hash against the retained checkpoint. *)

val merge : t list -> t list -> (t list, string) result
(** Cumulative canonical union. Equal coordinates with another original hash
    refuse the merge; identical originals union their named causes. *)

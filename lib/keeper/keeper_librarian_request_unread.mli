(** Immutable request evidence. Each source keeps its own observation, including
    read failure. This value grants no consumption or skip authority. *)
type reading = Available of Keeper_librarian_unread.t list | Unavailable
type t = { snapshot : reading; memory : reading }
val empty : t
val of_results :
  snapshot:(Keeper_librarian_unread.t list, string) result ->
  memory:(Keeper_librarian_unread.t list, string) result -> t
val to_json : t -> Yojson.Safe.t
val text : ?include_empty:bool -> t -> (string option, string) result
(** By default, omit a known empty pair. [include_empty:true] carries that
    frozen observation explicitly, so native requests can replace earlier
    unread evidence and include the carrier in capacity measurements. *)
val attach : ?include_empty:bool -> role:Agent_core.Types.role -> t ->
  Agent_core.Types.message list -> Agent_core.Types.message list
(** Replace any previous unread carrier before measuring or sending. Preserve
    original source coordinates/hashes even for a candidate's media rendering.
    A known empty pair is omitted unless [include_empty] is true; an
    unavailable source always has a carrier. If managed guidance cannot render,
    the carrier retains the exact JSON and reports the error in its
    [masc.librarian_unread_guidance_error] metadata. *)

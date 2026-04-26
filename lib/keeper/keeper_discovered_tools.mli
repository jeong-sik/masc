(** Per-session discovered tool tracking with turn-based decay.

    Tools discovered via [keeper_tool_search] can be added to this set.
    Callers can query [active_names] to retrieve discovered tools that
    have not yet decayed.  Tools decay after [decay_turns] of non-use. *)

type t

(** [create ~decay_turns] returns an empty discovered-tool set.
    [decay_turns] controls how many turns a tool survives without being
    called before it is removed from the active set. *)
val create : decay_turns:int -> t

(** [add t ~turn ~names] registers tool names as discovered at [turn].
    Idempotent: re-adding a name resets its decay clock. *)
val add : t -> turn:int -> names:string list -> unit

(** [mark_used t ~turn ~name] updates [last_used_turn] for [name].
    No-op if [name] is not in the set. *)
val mark_used : t -> turn:int -> name:string -> unit

(** [active_names t ~turn] returns names that have not yet decayed.
    A tool is active if [turn - last_active_turn <= decay_turns]. *)
val active_names : t -> turn:int -> string list

(** [decay t ~turn] removes expired entries and returns their names. *)
val decay : t -> turn:int -> string list

(** Number of entries (including expired but not yet decayed). *)
val count : t -> int

(** Remove all entries. *)
val clear : t -> unit

(** JSON representation for dashboard / debugging. *)
val to_json : t -> Yojson.Safe.t

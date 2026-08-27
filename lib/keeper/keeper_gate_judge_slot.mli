(** Which admitted judge a Keeper's Auto Judge decisions are put to first.

    The workspace declares one lane of judges in [runtime.toml] and the
    registry admits its slots at boot. This says which of those admitted
    slots to reach for first when the call being judged belongs to a
    particular Keeper.

    Among the admitted slots, and only among them. Naming a runtime the lane
    never declared would decide a Keeper's external effects on a model the
    boot-time topology check never saw, which is the check being relied on
    everywhere else. A preference the lane cannot satisfy is an error rather
    than a quiet fall back to the lane's own order: an operator who set one
    believes it is in force, and the whole point of setting it is that the
    default was not good enough for this Keeper.

    A preference, not a restriction. The rest of the lane stays behind it in
    declaration order, so the reasons the lane has failover in the first
    place -- a weekly quota, a context window a bundle outgrew -- still
    apply. *)

type t = {
  keeper_name : string;
  slot_id : string;  (** a slot id the lane declares, e.g. a runtime id *)
  actor : string;
  changed_at : string;
}

val all : base_path:string -> (t list, string) result
(** Every Keeper an operator has pointed at a particular judge, in the order
    they were set.

    A file that cannot be read is an error rather than an empty list. Empty
    means "everyone takes the lane's own order", which is a working
    configuration, and a file nobody can read must not be able to look like
    one. *)

val find : base_path:string -> keeper_name:string -> (t option, string) result

val prefer :
  slots:'slot list ->
  slot_id_of:('slot -> string) ->
  preferred:string ->
  ('slot list, string) result
(** Move the preferred slot to the front of [slots], keeping the rest in
    order. [Error] when no slot carries that id, naming what the lane does
    offer so an operator can see what they may choose between.

    Takes the id projection rather than the slot type: the registry owns that
    type, and this module has no reason to depend on it. *)

val set :
  Workspace.config ->
  actor:string ->
  keeper_name:string ->
  string option ->
  (t option, string) result
(** [None] clears the preference. Returns what is now on file for this
    Keeper, so a caller can report it without reading again. *)

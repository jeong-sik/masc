(** Worker-owned copies of host-authorized upload snapshots. This is a private
    broker, not a browser tool or an ambient filesystem reader. *)
type t
val create : directory:string -> (t, string) result
(** Create a fresh private [uploads] directory inside the original allocation.
    Existing contents are refused, never adopted or reset. *)
val stage : t -> id:string -> actor:string -> route:Browser_lane.route ->
  verb:Browser_lane.verb -> (unit, string) result
(** The trusted host supplies a bound upload command whose paths are its own
    authorized snapshots. Copy regular, same-UID, single-link 0600 sources into
    the worker allocation before publishing the one-use grant. The original
    command, actor and route remain immutable. This performs no browser input. *)
val with_claim : t -> id:string -> actor:string -> route:Browser_lane.route ->
  verb:Browser_lane.verb -> (Browser_lane.verb -> 'a) -> ('a, string) result
(** Consume only an exact original actor/route/command once. The callback gets
    the worker's registered copies. Their pending scope is released on every
    exit; a WebDriver claim retains them until confirmed session teardown. *)
val discard : t -> id:string -> unit
(** Release only a pending grant; a consumed or browser-owned batch is untouched. *)
val revoke : t -> unit
(** Fence publication and claims without doing filesystem I/O. *)
val cleanup : t -> (unit, string) result
(** Release pending grants after revocation. Owned batches remain with their
    browser session. Unknown, replaced or still populated resources are not
    recursively deleted. Blocking I/O must run outside the owner domain. *)

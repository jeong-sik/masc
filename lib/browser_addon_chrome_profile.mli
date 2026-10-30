(** Host-selected Chrome profile lifetime. All filesystem operations are blocking
    and must be offloaded by server callers. Persistent profiles are dedicated
    to MASC: external concurrent Chrome starts are outside the lease contract. *)
type persistent
type t = Private | Persistent of persistent
val select : path:string option -> (t, string) result
(** [None] selects a fresh allocation. [Some path] selects an existing private,
    host-owned directory, pins its identity and bootstraps its stable native
    resource slot once. An incomplete or replaced anchor is refused, not reset. *)
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val path : persistent -> string
val claim_directory : persistent -> string
val verify : persistent -> (unit, string) result
(** Revalidate the original profile, anchor, slot, gate and lease inodes. Does
    not acquire authority or inspect processes. Stable claim files and the
    anchor must never be deleted or replaced. *)
val before_launch : persistent -> (unit, string) result
(** Verify identity and refuse any existing Chrome SingletonLock,
    SingletonSocket or SingletonCookie, including dangling links. Never deletes
    or signals from browser singleton metadata. A successful check does not
    exclude a later external start: use a dedicated profile cooperatively. *)

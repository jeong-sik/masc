(** Durable store for RFC-0379 keeper monitors.

    One locked JSON array at [<masc>/monitors/monitors-v1.json], rewritten
    atomically under the shared per-path mutex. Records reload without their
    observation baseline ([Monitor_domain.of_yojson] drops it), so a server
    restart re-baselines every monitor instead of firing transitions that
    happened while the server was down. *)

val load : base_path:string -> (Monitor_domain.t list, string) result
(** Locked read. An absent store file is an empty list; a malformed store is
    an error, never a silent reset. *)

val create : base_path:string -> Monitor_domain.t -> (unit, string) result
(** Fails when the id already exists or the keeper already holds
    {!Monitor_domain.max_active_monitors_per_keeper} active monitors. *)

val cancel :
  base_path:string -> keeper:string -> id:string -> (bool, string) result
(** [Ok true] when the keeper's own monitor was removed, [Ok false] when no
    monitor with that id exists. A monitor owned by another keeper is an
    error, not a removal. *)

type fire_outcome =
  | Fire_recorded_retained
  | Fire_recorded_removed
      (** The fire consumed the record's last remaining allowance
          ([fired_count] reached [max_fires]); the record was deleted so no
          exhausted rows persist. *)

val record_fire : base_path:string -> id:string -> (fire_outcome, string) result
(** An unknown id is an error: the runner observed a record that the store no
    longer holds (raced cancel), and the caller decides how loudly to say so. *)

val remove_expired : base_path:string -> now:float -> (string list, string) result
(** Deletes every expired record and returns the removed ids. *)

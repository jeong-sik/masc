(** What the MASC server started as a workspace's Keeper Firefox, kept in
    [<base>/.masc/browser-lane/keeper-firefox.json]
    (RFC-browser-keeper-firefox §3.4).

    The server writes it as soon as it has started that Firefox, before
    waiting for its port; the start counts only once the record is written.
    A server whose workspace no longer asks for a Keeper Firefox reads it to
    stop the one MASC started and no other process (§3.3). *)

(** How the process started here is told from a later process given its
    number. *)
type leader =
  | Started_at of string
      (** When it started ({!Posix_spawn_detached.process_start}). A
          Firefox that goes on in another process of its group, as one
          applying an update does, leaves this naming a process that ended,
          so that group is not told from a later one with its number. *)
  | Start_unreadable
      (** When it started could not be read. Nothing tells it from a later
          process with its number. *)

type entry =
  { group : int
        (** Its process group, numbered after the process started here. *)
  ; leader : leader
  ; profile : string
  ; port : int
  ; started_at : float
  }

val record_path : base_path:string -> string

type read =
  | Absent
  | Recorded of entry
  | Unreadable of string  (** Why the file there is not a record this reader knows. *)

val read : base_path:string -> read

type write_failure =
  | Not_written of string  (** The file is what it was before. *)
  | Not_synced of string
      (** The record is there, and its directory entry was not flushed: a
          crash of this machine may lose it. *)

val write_failure_message : write_failure -> string

(** Replaces the record whole. *)
val write : base_path:string -> entry -> (unit, write_failure) result

(** Removes the record; one that is not there is removed already. *)
val remove : base_path:string -> (unit, string) result

val entry_to_json : entry -> Yojson.Safe.t
val entry_of_json : Yojson.Safe.t -> (entry, string) result

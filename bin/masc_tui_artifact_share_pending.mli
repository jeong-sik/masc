(** Durable client-side intent for exactly one artifact-share operation. *)
type entry = {
  base_path : string;
  masc_root : string;
  artifact_id : string;
  request : Masc.Published_artifact_share.request;
}

val witness : entry -> entry list -> entry list
val resolve : entry -> entry list -> entry list
val for_resource : entry -> entry list -> entry list
(** Preserve distinct observed tuples, and retire only an exact tuple. *)

type cursor
val same_cursor : cursor -> cursor -> bool
type preparation = Prepared | Already_pending of entry | Not_prepared of string
  | Already_pending_with_storage_failure of entry * string

val journal_path : masc_root:string -> string

(** [on_observed] runs inside the filesystem transaction, before it returns or
    reports cleanup failure. It must be thread-safe and must not use Eio effects. *)
val read : ?on_observed:(entry list -> unit) -> path:string -> unit -> (entry list, string) result
(** A torn suffix is removed only after the complete prefix validates. A
    malformed complete record or unreadable journal fails closed. *)
val observe : ?on_observed:(entry list -> unit) -> path:string -> unit -> (cursor * entry list, string) result
(** Return the file identity and exact journal contents with pending entries under
    the same lock. A changed cursor invalidates an overlapping share read. *)
val confirm : ?on_observed:(entry list -> unit) -> path:string -> entry -> (bool, string) result
(** Confirm that the exact recovered tuple remains present and fsync the
    existing journal before it can be dispatched again. *)
val prepare_checked : ?on_observed:(entry list -> unit) -> path:string -> entry -> (preparation, string) result
(** A known existing intent is distinct from an uncertain storage failure. *)
val prepare : ?on_observed:(entry list -> unit) -> path:string -> entry -> (unit, string) result
(** Flush before dispatch and exclude another operation for this workspace and
    artifact, including operations from another TUI process. *)
val restore : ?on_observed:(entry list -> unit) -> path:string -> entry -> (unit, string) result
(** After explicit confirmation, durably re-record a missing original tuple or
    confirm an existing one. A different pending operation prevents dispatch. *)
val settle : ?on_observed:(entry list -> unit) -> path:string -> entry -> (bool, string) result
(** Remove only the complete matching tuple after a verified operation receipt.
    A non-dispatched local attempt does not rule out another TUI's retry. A
    failed acknowledgement leaves recovery required. *)

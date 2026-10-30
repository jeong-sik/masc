(** Current public Board address projection. Read effective metadata, exactly
    as the event-time Board routing path does; never reuse a cached raw row. *)
type unavailable = Metadata_absent | Effective_metadata_unread

type t =
  | Ready of Keeper_identity.Keeper_id.t list
  | Unavailable of unavailable

val of_effective_meta : Keeper_meta_contract.keeper_meta -> t
val read : Workspace.config -> string -> t
val to_yojson : t -> Yojson.Safe.t

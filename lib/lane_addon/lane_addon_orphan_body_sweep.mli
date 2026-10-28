(** Conservative startup cleanup of unreferenced original request bodies. *)
type archive =
  | Archive_not_needed
      (** The live records protect every live body, so the settled archive
          could protect nothing more and was not read. *)
  | Archive_read
      (** A live body was unprotected by the live records, so the settled
          records were read before anything was removed. *)
type report = { protected_digests : int; removed : int; archive : archive }
(** [protected_digests] counts the digests of the records that were read. *)
val archive_to_string : archive -> string
type error =
  | Inventory_unavailable of string
  | Removal_incomplete of { removed : int; detail : string }
val error_to_string : error -> string
val run : store:Lane_addon_store.t -> (report, error) result
(** Call only while the workspace process lease is held and before original
    request writers begin. Complete, durable inventories of live records and
    live bodies precede every removal, and so does the inventory of archived
    records whenever a live body is not protected by a live record. Archived
    records only add protection, so when every live body is protected they are
    not read and the archive is not validated. Every named digest, including
    successor intents without a scope, is protected globally. Archived records
    protect their live bodies even when archive settlement was interrupted;
    this sweep does not repair that archive. Unknown entries in the inventories
    that were read fail closed before removal; archive body contents are not
    inspected. A removal error may be partial or have an unconfirmed last effect.
    The lease excludes cooperating writers using the same lease namespace; it
    is not an atomic compare-unlink against an unrelated process. *)
val run_at_startup : base_path:string -> (report, error) result
(** As {!run} for the workspace's runtime store. A missing runtime root has
    nothing to sweep. The caller holds the same lease and pre-writer boundary. *)
module For_testing : sig
  val run : before_remove:(Lane_addon_store.tool_request_body_entry -> unit) ->
    store:Lane_addon_store.t -> (report, error) result
end

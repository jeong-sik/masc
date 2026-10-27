(** Conservative startup cleanup of unreferenced original request bodies. *)
type report = { protected_digests : int; removed : int }
type error =
  | Inventory_unavailable of string
  | Removal_incomplete of { removed : int; detail : string }
val error_to_string : error -> string
val run : store:Lane_addon_store.t -> (report, error) result
(** Call only while the workspace process lease is held and before original
    request writers begin. Complete, durable inventories of live and archived
    records and live bodies precede every removal. Every named digest, including
    successor intents without a scope, is protected globally. Archived records
    protect their live bodies even when archive settlement was interrupted;
    this sweep does not repair that archive. Unknown entries in the record and
    live-body inventories fail closed before removal; archive body contents are
    not inspected. A removal error may be partial or have an unconfirmed last effect.
    The lease excludes cooperating writers using the same lease namespace; it
    is not an atomic compare-unlink against an unrelated process. *)
val run_at_startup : base_path:string -> (report, error) result
(** As {!run} for the workspace's runtime store. A missing runtime root has
    nothing to sweep. The caller holds the same lease and pre-writer boundary. *)
module For_testing : sig
  val run : before_remove:(Lane_addon_store.tool_request_body_entry -> unit) ->
    store:Lane_addon_store.t -> (report, error) result
end

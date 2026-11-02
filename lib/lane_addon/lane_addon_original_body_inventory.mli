(** Startup observation of original request bodies and their known owners. *)
type archive =
  | Archive_not_needed
      (** Live records protect every observed live body, so the settled
          archive was not read. *)
  | Archive_read
      (** Some live body lacked live-record protection, so settled records
          were also read before producing a count. *)

type report =
  { protected_digests : int
  ; unprotected_files : int
  ; unprotected_logical_bytes : int64
  ; archive : archive
  }
(** [unprotected_files] counts live body files whose digest was not protected
    by any live or read settled record or successor intent. Because successor
    digests protect every scope, this is not a count of missing owners. The
    byte count sums logical file sizes, not allocated disk space. Archived
    bodies and incomplete staging files are not included. *)

type error = Inventory_unavailable of string
val archive_to_string : archive -> string
val error_to_string : error -> string
val run : store:Lane_addon_store.t -> (report, error) result
(** Call while the workspace process lease excludes original writers. Inventory
    live owners and live bodies; read the settled owner archive when a live
    body is not protected by live owners. Unknown, malformed, aliased, missing
    or changing inputs refuse the observation instead of producing a zero
    count. Bodies are never removed: an owner absent from these namespaces
    does not prove its request was never dispatched. The lease excludes only
    cooperating writers in the same namespace. *)
val run_at_startup : base_path:string -> (report, error) result
(** As {!run} for the workspace runtime store. A missing runtime root has no
    observed bodies. This observation neither recovers owners nor authorizes
    their requests to be sent again. *)

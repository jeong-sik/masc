(** Installed-release authority, independent of checkout/inode build provenance.
    Selection is frozen at server startup; an invalid selected release never
    falls back to another directory. Receipt mtimes are evidence, not freshness. *)
type error =
  | Invalid_receipt
  | Receipt_identity_mismatch
  | Binary_commit_unavailable
  | Binary_commit_mismatch of { expected : string; actual : string }
  | Digest_mismatch of { path : string; expected : string; actual : string }
  | Size_mismatch of string
  | Exact_read_failed of string
  | Root_identity_changed
  | Not_manifested

type binding

type selection = Not_installed | Unavailable of error | Bound of binding

val inspect : executable_path:string -> binary_commit:string option -> selection
(** [executable_path] is the canonical executable path captured at process start,
    not a symlink resolved on each request. *)
val initialize : executable_path:string -> binary_commit:string option -> unit
(** Call once, before starting the server's fibers. *)
val current : unit -> selection
val assets_root : binding -> string
val build_stamp_mtime : binding -> float option
val asset_path : binding -> string -> string option
val load : binding -> string -> (string, error) result
(** Revalidate the receipt and requested asset on every read. Digest computation
    uses the shared CPU pool when called from a server fiber; startup and
    callers already in a worker retain the pool's inline policy. *)
val evidence : selection -> Yojson.Safe.t
val error_json : error -> Yojson.Safe.t

(** The shim a guest runs commands through (RFC-0400): the keeper's work root
    on the host, the shim's names and paths on the host and in the guest, the
    sidecar that says whether the binary is the release's (RFC-0427), the
    mount that hands it to a guest, its config, and the environment and
    limits of a remote session.

    [Keeper_sandbox_microvm] includes this module. *)

val keeper_work_root : keeper_name:string -> string

val shim_guest_dir : string

val shim_binary_name : string

val shim_config_name : string

val shim_sidecar_name : string

(* RFC-0427 B-2. The installer places the release's shim and, beside it, the
   sha256 the release's SHA256SUMS gave for that asset. The boot reads the
   pair: a binary that does not match its own sidecar is refused by name,
   because a shim the release did not ship is the 2026-09-05 outage waiting
   to recur. No sidecar means a hand-built shim; it runs, and the boot log
   says it was not verified. *)
type shim_provenance =
  | Shim_verified of { sha256 : string }
  | Shim_unverified

val verify_shim_sidecar : dir:string -> (shim_provenance, string) result

val shim_guest_path : string

val shim_config_guest_path : string

val shim_mount_args : host_dir:string -> string list

val shim_config_content : payload_path:string -> string

val remote_env_allowlist : string list

val remote_connect_timeout_sec : int

val remote_max_concurrent_sessions : int

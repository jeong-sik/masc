(** Bidirectional path translation for the remote execution lane.

    This module is the sole owner of the mapping between the host bookkeeping
    playground and an endpoint's resolved workspace. The caller supplies that
    root explicitly; this module does not infer endpoint layout. *)

val normalize_remote : string -> string
(** Lexical dot-segment cleanup for an endpoint-namespace path. Host realpath
    is deliberately absent: it substitutes host symlinks and macOS firmlinks
    (/home/x → /System/Volumes/Data/home/x) into paths that only exist on the
    endpoint. *)

type lane =
  | Ssh_endpoint
  | Microvm_guest
(** Which remote lane owns the endpoint namespace. A refusal is worded for the
    Keeper on that lane. *)

type breach =
  | Relative_escape  (** A keeper-relative path climbs out with [..]. *)
  | Outside_keeper_root
  (** An absolute path is under neither the endpoint root nor the Keeper's
      host bookkeeping root. *)

type jail_refusal =
  { lane : lane
  ; breach : breach
  ; path : string  (** The path as the caller gave it. *)
  ; host_root : string
  ; endpoint_root : string
  }

val jail_refusal_to_string : jail_refusal -> string
(** [remote_ssh_path_jail_violation: ...] naming the host bookkeeping root on
    the SSH lane; [microvm_remote_path_jail_violation: ...] naming the guest
    root on the microVM lane. *)

val host_to_remote :
  lane:lane ->
  base_path:string ->
  remote_workspace_root:string ->
  keeper:string ->
  string ->
  (string, jail_refusal) result
(** Translate an absolute host bookkeeping path or a keeper-relative path to
    [remote_workspace_root/...]. An absolute path already at or below
    [remote_workspace_root] is returned as itself. Any other path is refused. *)

val remote_to_logical : remote_workspace_root:string -> string -> string
(** Translate a path below [remote_workspace_root] to the keeper-relative path
    the model uses. The root itself becomes ["."]. Paths outside that root are
    returned unchanged. *)

val endpoint_to_host :
  base_path:string -> remote_workspace_root:string -> keeper:string ->
  string -> string option
(** Project a path at/below the endpoint workspace into internal bookkeeping
    coordinates. [None] means it is outside that workspace, not a host path. *)

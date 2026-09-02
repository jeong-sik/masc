(** Bidirectional path translation for the remote execution lane.

    This module is the sole owner of the mapping between the host bookkeeping
    playground and an endpoint's remote playground. The endpoint is named by
    its [remote_root] alone, so the OpenSSH lane and the Apple [container]
    guest lane translate the same way. *)

val normalize_remote : string -> string
(** Lexical dot-segment cleanup for an endpoint-namespace path. Host realpath
    is deliberately absent: it substitutes host symlinks and macOS firmlinks
    (/home/x → /System/Volumes/Data/home/x) into paths that only exist on the
    endpoint. *)

val host_to_remote :
  base_path:string ->
  remote_root:string ->
  keeper:string ->
  string ->
  (string, string) result
(** Translate an absolute host bookkeeping path or a keeper-relative path to
    [remote_root/<keeper>/...]. Paths outside the keeper's host playground are
    rejected with [remote_ssh_path_jail_violation]. *)

val remote_to_logical :
  remote_root:string -> keeper:string -> string -> string
(** Translate a path below [remote_root/<keeper>] to the keeper-relative path
    the model uses. The root itself becomes ["."]. Paths outside that root are
    returned unchanged. *)

val rewrite_output :
  base_path:string ->
  remote_root:string ->
  keeper:string ->
  string ->
  string
(** Rewrite occurrences of [remote_root/<keeper>] in tool output back to the
    absolute host bookkeeping path. Component boundaries are respected, so a
    sibling such as [keeper-a-copy] is untouched. *)

type stream

val stream :
  base_path:string ->
  remote_root:string ->
  keeper:string ->
  emit:(string -> unit) ->
  stream

val rewrite_stream_chunk : stream -> string -> unit
val finish_stream : stream -> unit
(** Boundary-safe streaming form of {!rewrite_output}. At most one remote-root
    pattern length is retained between chunks. *)

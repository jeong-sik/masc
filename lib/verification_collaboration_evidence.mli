(** Referenced collaboration sources for a standalone reviewer. The Task
    principal is the actual producer, including non-Keeper producers. Goal
    authority covers shared records in the active workspace, not private Direct
    discussions. Direct target readership cannot be reconstructed from mutable
    post text; only the author can expose a Direct post through Task review. *)
type authority = Task_producer of string | Goal_workspace

type error =
  | Invalid_request of string
  | Access_denied of string
  | Source_unavailable of string
  | Storage_failed of string

val error_to_string : error -> string
(** Large responses are bounded JSON-text pages. The caller follows next_cursor
    with unchanged source arguments and concatenates content to recover the exact
    structured source. Each cursor pins SHA-256 and UTF-8 byte offset; every page
    rechecks source authority and refuses changed source observations. *)
val read_board : config:Workspace.config -> authority:authority -> args:Yojson.Safe.t ->
  (Yojson.Safe.t, error) result
val read_fusion : config:Workspace.config -> authority:authority -> args:Yojson.Safe.t ->
  (Yojson.Safe.t, error) result

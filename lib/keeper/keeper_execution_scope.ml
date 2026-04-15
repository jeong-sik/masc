(** Typed execution scope for keeper agents. *)

type t =
  | Observe_only
  | Workspace
  | Local

let default = Workspace

let all = [ Observe_only; Workspace; Local ]

let to_string = function
  | Observe_only -> "observe_only"
  | Workspace -> "workspace"
  | Local -> "local"

let of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "observe_only" -> Ok Observe_only
  | "workspace" -> Ok Workspace
  | "local" -> Ok Local
  | _ -> Error (`Unknown_scope s)

let of_string_lossy ?(default = Workspace) s =
  match of_string s with
  | Ok v -> v
  | Error (`Unknown_scope raw) ->
    Log.Keeper.warn "unknown execution_scope %S, falling back to %s"
      raw (to_string default);
    default

let equal a b =
  match (a, b) with
  | Observe_only, Observe_only -> true
  | Workspace, Workspace -> true
  | Local, Local -> true
  | _ -> false

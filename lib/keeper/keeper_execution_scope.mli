(** Typed execution scope for keeper agents.

    Replaces the previous [string] representation to prevent typos and
    silent fallthrough on unknown values (Parse, Don't Validate). *)

type t =
  | Observe_only
  | Workspace
  | Local

val default : t

(** All valid scopes, in declaration order. *)
val all : t list

(** Wire-compatible string representation (byte-identical to the legacy
    string values: ["observe_only"], ["workspace"], ["local"]). *)
val to_string : t -> string

(** Parse from string.  Returns [Error (`Unknown_scope s)] for
    unrecognised inputs. *)
val of_string : string -> (t, [ `Unknown_scope of string ]) result

(** Parse from string with a fallback default (default: {!default}).
    Logs a warning on unknown input via [Log.Keeper.warn]. *)
val of_string_lossy : ?default:t -> string -> t

val equal : t -> t -> bool

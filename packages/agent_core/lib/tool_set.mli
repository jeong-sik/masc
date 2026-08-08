(** Tool Set: composable, deduplicated tool collections.

    A monoid over tool collections with last-writer-wins semantics on
    name conflicts.  Enables safe composition of agent, MCP, and
    handoff tool lists.

    Laws (verified by QCheck):
    - [merge (merge a b) c = merge a (merge b c)]  (associativity)
    - [merge empty s = s]                           (left identity)
    - [merge s empty = s]                           (right identity)
    - [merge s s = s]                               (idempotence)

    @stability Stable
    @since 0.93.1 *)

type t

(** {1 Construction} *)

val empty : t
val singleton : Tool.t -> t
val of_list : Tool.t list -> t

(** {1 Composition} *)

(** Merge two tool sets.  On name conflict the right-hand tool wins. *)
val merge : t -> t -> t

(** Merge a list of tool sets left-to-right. *)
val concat : t list -> t

(** {1 Query} *)

val to_list : t -> Tool.t list
val find : string -> t -> Tool.t option
val mem : string -> t -> bool
val size : t -> int
val names : t -> string list

(** {1 Validation} *)

type dep_error =
  | DuplicateName of string
  | EmptyName

(** Validate the tool set.  Returns [Ok ()] if all tool names are
    non-empty and unique within the set (which is guaranteed by
    construction, so this always returns [Ok ()] unless the internal
    invariant is broken). *)
val validate : t -> (unit, dep_error list) result

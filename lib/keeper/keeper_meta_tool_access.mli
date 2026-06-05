(** Keeper tool-access helpers.

    A keeper's [tool_access] is the persisted candidate profile list —
    [keeper_meta.tool_access : string list]. It is only one policy input:
    descriptor/registry availability, denylist filtering, per-turn OAS
    allowlists, and eval gates still constrain execution. There is no wrapper
    type. *)

(** Trim, drop blanks, dedupe (preserve first-seen order). *)
val normalize_tool_names : string list -> string list

(** Parse [tool_access] from persisted meta JSON. Canonical form is a JSON
    array of tool names. *)
val tool_access_of_meta_json :
  Yojson.Safe.t -> (string list, string) result

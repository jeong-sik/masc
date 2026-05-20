(* Local kind diagnostic for shared_types of_json error messages.

   Duplicates the canonical [Json_util.kind_name] from
   [lib/core/json_util.ml:149] because [shared_types] is a leaf
   library (only deps: unix, yojson) and cannot reach
   [masc_core.Json_util] without introducing an upward dependency.

   Same situation noted in [lib/shared_audit/envelope.ml] (iter#86,
   PR #16914) — current count: 5 inline duplicates of the same
   total mapping across the tree.  RFC candidate: a shared
   sub-leaf module for json kind diagnostics.  This file is the
   first consolidation step *within* shared_types itself. *)

let name : Yojson.Safe.t -> string = function
  | `Null -> "null"
  | `Bool _ -> "bool"
  | `Int _ -> "int"
  | `Intlit _ -> "int"
  | `Float _ -> "float"
  | `String _ -> "string"
  | `Assoc _ -> "object"
  | `List _ -> "array"

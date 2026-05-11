type scope =
  | Surface
  | Keeper_internal

(* Initial classification is empty. Subsequent PRs (PR-N1+) add specific
   tool names here as they are migrated from the orchestrator MCP surface
   into the keeper-internal dispatch table. *)
let keeper_internal_list : string list = []

let keeper_internal_names () = keeper_internal_list

let classify ~name =
  if List.mem name keeper_internal_list then Keeper_internal else Surface

let scope_to_string = function
  | Surface -> "surface"
  | Keeper_internal -> "keeper_internal"

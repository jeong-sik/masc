type scope =
  | Surface
  | Keeper_internal

(* Wave 1 (PR-N1): 8 universal tools that keeper personas invoke during
   their own work but that the external MCP orchestrator surface should
   not expose. code_* helpers, web_* fetchers, worktree management. *)
let keeper_internal_list : string list =
  [ (* code helpers *)
    "masc_code_read"
  ; "masc_code_search"
  ; "masc_code_symbols"
    (* web fetchers *)
  ; "masc_web_fetch"
  ; "masc_web_search"
    (* worktree management *)
  ; "masc_worktree_create"
  ; "masc_worktree_list"
  ; "masc_worktree_remove"
  ]

let keeper_internal_names () = keeper_internal_list

let classify ~name =
  if List.mem name keeper_internal_list then Keeper_internal else Surface

let scope_to_string = function
  | Surface -> "surface"
  | Keeper_internal -> "keeper_internal"

type scope =
  | Surface
  | Keeper_internal

(* keeper-internal: tools that keeper personas invoke during their own
   work but that the external MCP orchestrator surface should not
   expose. Wave 1 (PR-N1, #14627): code/web/worktree (8). Wave 2
   (PR-N2d): coord/inline admin observability audit verdict (5),
   plan_* (6), run_* (6), webrtc (2). *)
let keeper_internal_list : string list =
  [ (* === Wave 1 (PR #14627) === *)
    (* code helpers *)
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
    (* === Wave 2 (this PR) === *)
    (* coord/inline admin observability (PR-N5 audit verdict, #14618) *)
  ; "masc_check"
  ; "masc_coordination_fsm_snapshot"
  ; "masc_reset"
  ; "masc_workflow_guide"
  ; "masc_mcp_session"
    (* plan management (keeper persona authoring) *)
  ; "masc_plan_clear_task"
  ; "masc_plan_get_task"
  ; "masc_plan_get"
  ; "masc_plan_init"
  ; "masc_plan_set_task"
  ; "masc_plan_update"
    (* run management (keeper persona execution log) *)
  ; "masc_run_deliverable"
  ; "masc_run_get"
  ; "masc_run_init"
  ; "masc_run_list"
  ; "masc_run_log"
  ; "masc_run_plan"
    (* webrtc (experimental, not in user surface definition) *)
  ; "masc_webrtc_offer"
  ; "masc_webrtc_answer"
  ]

let keeper_internal_names () = keeper_internal_list

let classify ~name =
  if List.mem name keeper_internal_list then Keeper_internal else Surface

let scope_to_string = function
  | Surface -> "surface"
  | Keeper_internal -> "keeper_internal"

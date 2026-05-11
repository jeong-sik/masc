type scope =
  | Surface
  | Keeper_internal

(* keeper-internal: tools that keeper personas invoke during their own
   work but that the external MCP orchestrator surface should not
   expose. Wave 1 (PR-N1, #14627): code/web/worktree (8). Wave 2
   (PR-N2d, #14633): coord/inline admin observability audit verdict
   (5), plan_* (6), run_* (6), webrtc (2). Wave 3 (PR-N3, this PR):
   keeper_board_* duplicates (12). *)
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
    (* === Wave 2 (PR #14633) === *)
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
    (* === Wave 3 (this PR) — keeper_board_* duplicates === *)
    (* The board domain has parallel keeper_board_* / masc_board_*
       definitions. masc_board_* stays in the orchestrator surface
       (user-confirmed "board" category). keeper_board_* is the
       keeper-internal handle the keeper persona uses for its own
       board interactions. Cleanup/dedupe of the parallel handlers
       is a separate RFC; this PR only narrows the surface. *)
  ; "keeper_board_cleanup"
  ; "keeper_board_comment"
  ; "keeper_board_comment_vote"
  ; "keeper_board_curation_read"
  ; "keeper_board_curation_submit"
  ; "keeper_board_delete"
  ; "keeper_board_get"
  ; "keeper_board_list"
  ; "keeper_board_post"
  ; "keeper_board_search"
  ; "keeper_board_stats"
  ; "keeper_board_vote"
  ]

let keeper_internal_names () = keeper_internal_list

(* O(1) membership table built once at module load.  Previously
   [classify] scanned [keeper_internal_list] (~41 entries) via
   [List.mem] on every call; [classify] is invoked in [Config]'s
   visible_tool_schemas filter (length × |list|) and indirectly on
   surface-trim hot paths. *)
let keeper_internal_set : (string, unit) Hashtbl.t =
  let table = Hashtbl.create (List.length keeper_internal_list * 2) in
  List.iter
    (fun name -> Hashtbl.replace table name ())
    keeper_internal_list;
  table

let classify ~name =
  if Hashtbl.mem keeper_internal_set name then Keeper_internal else Surface

let scope_to_string = function
  | Surface -> "surface"
  | Keeper_internal -> "keeper_internal"

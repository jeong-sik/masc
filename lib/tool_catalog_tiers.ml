(** Tool_catalog_tiers — 3-tier tool filtering system.

    Essential (~20) < Standard (~50) < Full (all).
    Tier is an additive overlay on the existing mode/category system.

    This module is a leaf dependency — it depends only on string lists.
    Extracted from tool_catalog.ml to enable SCC cycle-breaking:
    keeper modules can depend on this leaf module (e.g. for standard_tools)
    instead of the full Tool_catalog.

    @since 2.188.0 — God file decomposition Phase 1 *)

(** Tool_catalog_tiers — 2-tier tool filtering system.

    Core (~25) < Extended (all).

    @since 2.223.0 — Simplified from 3-tier to 2-tier *)

type tier =
  | Core
  | Extended

let core_tools =
  [
    "masc_join"; "masc_leave"; "masc_status"; "masc_start";
    "masc_add_task"; "masc_claim_next"; "masc_transition"; "masc_tasks";
    "masc_broadcast"; "masc_heartbeat"; "masc_messages";
    "masc_worktree_create"; "masc_worktree_list"; "masc_worktree_remove";
    "masc_plan_init"; "masc_plan_get"; "masc_plan_set_task"; "masc_plan_update";
    "masc_who"; "masc_dashboard"; "masc_agent_timeline";
    "masc_agents"; "masc_keeper_msg"; "masc_web_search";
    "masc_bounded_run";
  ]

(** Pre-built Hashtbl set for O(1) tier lookup. *)
let core_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  List.iter (fun name -> Hashtbl.replace tbl name ()) core_tools;
  tbl

let tier_to_string = function
  | Core -> "core"
  | Extended -> "extended"

let tier_of_string = function
  | "core" -> Some Core
  | "extended" -> Some Extended
  (* Backward compat aliases *)
  | "essential" -> Some Core
  | "standard" | "full" -> Some Extended
  | _ -> None

let tool_tier name =
  if Hashtbl.mem core_set name then Core
  else Extended

let is_in_tier tier name =
  match tier with
  | Extended -> true
  | Core -> Hashtbl.mem core_set name

let tier_tool_count = function
  | Core -> List.length core_tools
  | Extended -> -1  (* unknown until schemas are enumerated *)

module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_access_role — Role-based tool access policy builder.

    Derived mechanically from Tool_permission_map.permission_for_tool, which
    already respects Tool_catalog-declared required_permission metadata before
    falling back to legacy auth mappings.

    Each tool's required permission determines which role tier it belongs to:
    - Worker tier: CanReadState, CanJoin, CanLeave, CanAddTask, CanClaimTask,
                   CanCompleteTask, CanBroadcast,
                   CanOpenPortal, CanSendPortal, CanCreateWorktree,
                   CanRemoveWorktree
    - Admin tier:  CanInit, CanReset, CanAdmin

    @since 2.204.0 *)

type required_role =
  | Worker_role
  | Admin_role

let all_surface_tools () =
  Tool_permission_map.known_tool_names
  |> List.sort_uniq String.compare

let required_role_of_permission = function
  | Masc_domain.CanInit | Masc_domain.CanReset | Masc_domain.CanAdmin -> Admin_role
  | Masc_domain.CanReadState | Masc_domain.CanJoin | Masc_domain.CanLeave
  | Masc_domain.CanAddTask
  | Masc_domain.CanClaimTask
  | Masc_domain.CanCompleteTask
  | Masc_domain.CanBroadcast
  | Masc_domain.CanOpenPortal
  | Masc_domain.CanSendPortal
  | Masc_domain.CanCreateWorktree
  | Masc_domain.CanRemoveWorktree
  | Masc_domain.CanVote ->
      Worker_role

let tools_for_required_role required_role =
  all_surface_tools ()
  |> List.filter (fun tool_name ->
         match Tool_permission_map.permission_for_tool tool_name with
         | None -> false
         | Some permission ->
             (=) (required_role_of_permission permission) required_role)

(* ── Memoization rationale ─────────────────────────────────────────
   [tools_for_required_role] sorts ~100 tool names via
   [List.sort_uniq] then filters each through a [permission_for_tool]
   Hashtbl lookup.  Inputs ([Tool_permission_map.known_tool_names],
   permission metadata, catalog surfaces) are module-init-frozen, so
   the result is constant for the program lifetime.

   [policy_for_role Worker] is called per-request from
   [Auth.authorize_tool_for_role]; rebuilding the same selector each
   call was pure waste.

   [lazy] (instead of eager [let]) defers evaluation until first call,
   so we read [Tool_permission_map.known_tool_names] *after* all module
   init side effects have populated the catalog. *)

let admin_only_tools_lazy = lazy (tools_for_required_role Admin_role)
let worker_only_tools_lazy = lazy (tools_for_required_role Worker_role)

(* ================================================================ *)
(* Admin-only tools (CanInit + CanReset + CanAdmin)                 *)
(* ================================================================ *)

let admin_only_tools () = Lazy.force admin_only_tools_lazy

(* ================================================================ *)
(* Worker-only tools (CanAddTask + CanClaimTask + CanCompleteTask + *)
(*                    CanBroadcast + CanOpenPortal + CanSendPortal +*)
(*                    CanCreateWorktree + CanRemoveWorktree + CanVote) *)
(* ================================================================ *)

let worker_only_tools () = Lazy.force worker_only_tools_lazy

(* ================================================================ *)
(* Role → Policy                                                     *)
(* ================================================================ *)

let admin_policy : Tool_access_policy.t =
  { Tool_access_policy.allow = All; deny = Empty }

let worker_policy_lazy : Tool_access_policy.t Lazy.t =
  lazy
    {
      Tool_access_policy.allow =
        Diff
          { base = All
          ; exclude = Names (Lazy.force admin_only_tools_lazy)
          };
      deny = Empty;
    }

let policy_for_role : Masc_domain.agent_role -> Tool_access_policy.t = function
  | Admin -> admin_policy
  | Worker -> Lazy.force worker_policy_lazy

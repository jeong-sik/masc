module List = Stdlib.List

(** Tool_catalog_inference — typed-tool-name -> effect_domain.

    Pure inference layer. Given a {!Tool_name.t} variant, returns the
    inferred {!effect_domain}. The facade [Tool_catalog] re-exports this via
    type aliasing so the public contract in [tool_catalog.mli] is unchanged.
    (The [tool_group] display classifier was deleted in the surface-cut
    refactor.)

    {b Why split}: this is the largest pure section of [tool_catalog]
    (~410 LoC of typed-name pattern matches with no side effects).
    Moving it out shrinks the facade and isolates churn when new
    [Tool_name] variants are added. *)

(* PR-S2 (tool⊥domain cut): [effect_domain] is defined in the zero-dep leaf
   [Tool_tag_types] so the domain side ([Tool_name.Domain_tool]) can produce it.
   Re-exported here by type-equality so the facade [Tool_catalog] and the public
   [tool_catalog.mli] / this module's [.mli] are unchanged. *)
type effect_domain = Tool_tag_types.effect_domain =
  | Read_only
  | Masc_workspace
  | Playground_write
  | Host_repo_write

let effect_domain_to_string = function
  | Read_only -> "read_only"
  | Masc_workspace -> "masc_workspace"
  | Playground_write -> "playground_write"
  | Host_repo_write -> "host_repo_write"

module TN = Tool_name
module TM = Tool_name.Masc

(* PR-S2: domain tool names are carried behind one neutral [TM.Domain] arm; the
   per-member effect classification (NON-uniform: Board splits Read_only vs
   Masc_workspace; Operator splits three ways) is owned domain-side by
   [Tool_name.Domain_tool.effect_domain]. The substrate no longer enumerates any
   domain constructor (Task/Board/Goal/Operator). The flat admin/lifecycle/misc
   names keep their explicit buckets here. *)
let inferred_effect_domain_of_typed_tool_name = function
  | TN.Masc (TM.Domain d) -> Some (Tool_name.Domain_tool.effect_domain d)
  | TN.Masc TM.Deliver
  | TN.Masc TM.Start ->
      Some Host_repo_write
  | TN.Masc TM.Agent_fitness
  | TN.Masc TM.Agent_card
  | TN.Masc TM.Agents
  | TN.Masc TM.Check
  | TN.Masc TM.Config
  | TN.Masc TM.Dashboard
  | TN.Masc TM.Get_metrics
  | TN.Masc TM.Mcp_session
  | TN.Masc TM.Messages
  | TN.Masc TM.Plan_get
  | TN.Masc TM.Plan_get_task
  | TN.Masc TM.Status
  | TN.Masc TM.Tool_admin_snapshot
  | TN.Masc TM.Tool_help
  | TN.Masc TM.Tool_list
  | TN.Masc TM.Tool_stats
  | TN.Masc TM.Web_fetch
  | TN.Masc TM.Web_search
  | TN.Masc TM.Approval_pending
  | TN.Masc TM.Approval_get ->
      Some Read_only
  | TN.Masc TM.Agent_update
  | TN.Masc TM.Broadcast
  | TN.Masc TM.Cleanup_zombies
  | TN.Masc TM.Gc
  | TN.Masc TM.Heartbeat
  | TN.Masc TM.Note_add
  | TN.Masc TM.Pause
  | TN.Masc TM.Plan_clear_task
  | TN.Masc TM.Plan_init
  | TN.Masc TM.Plan_set_task
  | TN.Masc TM.Plan_update
  | TN.Masc TM.Reset
  | TN.Masc TM.Resume
  | TN.Masc TM.Tool_admin_update
  | TN.Masc TM.Tool_grant
  | TN.Masc TM.Tool_revoke ->
      Some Masc_workspace
let inferred_effect_domain name =
  match Tool_name.of_string name with
  | Some typed_name -> inferred_effect_domain_of_typed_tool_name typed_name
  | None -> None

(** Folded approval verdicts for composition tools (keeper_compose_<skill>,
    keeper_plan_execute) whose materialized Agent-Core descriptors carry no
    Keeper descriptor.

    The composition surface knows each entry's validated plan at bundle build
    time, so the per-node verdicts are folded then and read here. Reading is
    pure (the approval hook has no switch and no result), lifetime is the
    bundle's (in-process, no durable state), and the fold is never more
    permissive than its nodes: an unresolvable node stays an Ask.

    Nothing here changes [Keeper_tool_approval_policy.verdict_for] for tools
    the descriptor registry knows. *)

val fold_entry : Keeper_tool_composition_catalog.entry -> Keeper_tool_approval_policy.verdict
(** The verdict a call to this composition would receive, computed from its
    validated plan: every node Run makes Run, any Ask makes Ask with the
    asking node's reason carried in [because]. Pure; does not register. *)

val register_entry : entry:Keeper_tool_composition_catalog.entry -> unit
(** Fold one validated composition entry and register it under its
    model-visible tool name. Registering again replaces the previous fold. *)

val lookup : string -> Keeper_tool_approval_policy.verdict option

val verdict_for_folded :
  tool_name:string -> input:Yojson.Safe.t -> Keeper_tool_approval_policy.verdict option
(** The verdict for a call to a registered folded tool, if the name is one.
    [None] means the name is not a folded tool and the caller should fall
    through to [Keeper_tool_approval_policy.verdict_for]. *)

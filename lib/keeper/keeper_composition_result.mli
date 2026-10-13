(** Model-facing export selection with a durable, complete execution document.
    This boundary never changes the executor's disposition or retries effects. *)

val project
  :  base_path:string
  -> plan:Keeper_tool_plan.t
  -> execution:(Keeper_tool_plan_executor.node_result list,
                Keeper_tool_plan_executor.failure) result
  -> Tool_result.result
  -> (Tool_result.result, Tool_bridge.externalization_error) result
(** With no exports, return the original result unchanged. Otherwise persist
    the full result and every settled node before returning selected fields,
    node dispositions, failure cause and a normalized artifact reference.
    The execution document uses the canonical artifact-manifest MIME/schema
    so its intermediate retained artifacts remain transitive retention roots.
    A storage failure returns [Error] without advertising an unpersisted
    reference. Cancellation propagates. *)

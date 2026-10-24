(** The host Memory consumers' package/tool/output contract. Resolving an
    export does not execute it, inspect a provider or authorize a later call. *)
type operation = Admission | Durable
val all : operation list
val package_id : string
val tool : operation -> string
val output : operation -> string
val reserved : unit -> string list

type unavailable =
  | Unattached
  | Unready of Lane_addon_unready.t * Lane_addon_unready.t list
  | Export_conflict of Lane_addon_tool_export.conflict
  | Wrong_package of { actual : string }
  | Manual_installation
val unavailable_to_string : unavailable -> string
val select : operation -> Lane_addon_runtime.tool_execution_snapshot ->
  (Lane_addon_runtime.tool_execution, unavailable) result
val resolve : config:Workspace.config -> reserved:string list -> operation ->
  (Lane_addon_runtime.tool_export, unavailable) result

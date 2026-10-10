(** Serial external execution. Worker annotations do not grant authority. *)
val create : Lane_addon_tool_export.t -> Keeper_tool_descriptor.t

val is_canonical : Keeper_tool_descriptor.t -> bool
(** Whether this exact descriptor object was produced by [create]. Copies with
    changed policy, schema or execution fields are not factory authority. *)

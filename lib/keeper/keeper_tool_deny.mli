(** Explicit selectors allow denying a dynamic export before it is attached.
    [addon:NAME] selects exactly NAME from Lane Add-ons, never a host tool. *)
type selector = Builtin of string | Lane_addon of string
val parse : string -> selector
val matches : lane_addon:bool -> name:string -> string -> bool

(** Shared warn-on-drift parser for [profile_defaults.tool_preset].

    Consolidates the duplicated helpers in
    [keeper_turn_up_create.preset_of_defaults] and the inline [match]
    in [keeper_exec_persona] (both introduced by the #8605 family of
    silent-default fixes, PRs #8916 and #8922). Having two copies is a
    drift risk — a future third preset-source path has no SSOT to
    follow. See #8923. *)

val preset_of_defaults_warn :
  call_site:string ->
  defaults_tool_preset:string option ->
  Keeper_types.tool_preset option
(** [preset_of_defaults_warn ~call_site ~defaults_tool_preset] parses the
    string from [profile_defaults.tool_preset]. Returns [None] when:
    - [defaults_tool_preset] is [None] (no config value supplied), or
    - the value is present but does not match a known preset (drift
      between producer config and consumer enum).

    In the drift case, emits a single [Log.Keeper.warn] tagged with
    [call_site] so operator logs show which path absorbed the unknown
    value. Callers apply their own [Option.value ~default:...] since
    the local default varies (Research vs None-propagation). *)

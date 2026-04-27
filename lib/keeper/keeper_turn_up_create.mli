(** Keeper_turn_up_create — create a new keeper from parsed arguments.

    Extracted from [keeper_turn_up.ml]'s [Ok None] branch. Handles
    initial keeper meta construction, checkpoint creation,
    keepalive start, and response JSON generation. *)

open Keeper_types

(** Resolve the tool_preset from [profile_defaults.tool_preset]
    via [Keeper_preset_defaults.preset_of_defaults_warn] with
    [call_site:"keeper_turn_up_create"]. Returns [None] when the
    defaults field is unset or names an unknown preset. *)
val preset_of_defaults :
  keeper_profile_defaults -> tool_preset option

(** Persist a freshly-built keeper_meta with field-merging CAS
    retry — preserves heartbeat-owned cursors when bootstrap races
    a supervisor write (#9749). *)
val write_initial_meta :
  Coord.config -> keeper_meta -> (unit, string) result

(** Create a new keeper from parsed args: build initial meta,
    write checkpoint, start keepalive, return the [keeper_up]
    response envelope. *)
val create_keeper :
  _ Keeper_types.context ->
  Keeper_turn_up_args.parsed_args ->
  tool_result

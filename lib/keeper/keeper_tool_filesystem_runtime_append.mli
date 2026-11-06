(** The append of a write in [Keeper_tool_filesystem_runtime] and the reports
    of its failures.

    [append_capability] appends content through a capability file and calls
    [on_cancelled] with the outcome when a cancellation arrives after the
    append. It returns [Content_write_append] unless the append and its sync
    succeeded on a verified target. [append_target_effect] classifies what an
    append outcome did to its target, and [append_target_effect_to_string]
    names the class.
    [capability_append_open_error_payload] and [append_write_outcome_payload]
    build the error payload of a failed open and of a failed append, and
    [observe_capability_append_open_error] and [observe_append_write_outcome]
    write their audit log lines.
    [Keeper_tool_filesystem_runtime] includes this module. *)
open Keeper_tool_filesystem_runtime_write_types

val append_capability :
  on_cancelled:(Fs_compat.capability_append_outcome -> 'a) ->
  Fs_compat.capability_append_file ->
  string ->
  (unit,
   content_write_error)
  result

val append_target_effect_to_string :
  append_target_effect ->
  string

val capability_append_open_error_payload :
  target:string -> Fs_compat.capability_append_open_error -> string

val observe_capability_append_open_error :
  keeper_name:string ->
  target:string -> Fs_compat.capability_append_open_error -> unit

val append_target_effect :
  Fs_compat.capability_append_outcome ->
  append_target_effect

val append_write_outcome_payload :
  target:string -> Fs_compat.capability_append_outcome -> string

val observe_append_write_outcome :
  keeper_name:string ->
  target:string -> Fs_compat.capability_append_outcome -> unit

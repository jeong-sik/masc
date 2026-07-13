(** Keeper_turn_up_create — create a new keeper from parsed arguments.

    Extracted from [keeper_turn_up.ml]'s [Ok None] branch. Handles
    initial keeper meta construction, checkpoint creation,
    keepalive start, and response JSON generation. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** Persist a freshly-built keeper_meta with field-merging CAS
    retry — preserves heartbeat-owned cursors when bootstrap races
    a supervisor write (#9749). *)
val write_initial_meta :
  Workspace.config -> keeper_meta -> (unit, string) result

(** Create a new keeper from parsed args: build initial meta,
    write checkpoint, start keepalive, return the [keeper_up]
    response envelope. *)
val create_keeper :
  _ Keeper_types_profile.context ->
  Keeper_turn_up_args.parsed_args ->
  tool_result

(** Configured-only create (create-without-boot). Materializes the
    list-visible keeper meta from the same derivation the boot path
    uses, with NO boot side effect: no session, no checkpoint, no
    registry/keepalive, no runtime assignment. [autoboot_enabled] is
    pinned false in the written meta; the caller owns the durable TOML
    write (also pinned false) so reconcile classifies the keeper
    [Declarative_autoboot_disabled] until an explicit masc_keeper_up.
    Gates (empty goal, unknown active_goal_ids, sandbox settings)
    mirror [create_keeper] with the same error strings. *)
val create_keeper_configured_only :
  Workspace.config ->
  Keeper_turn_up_args.parsed_args ->
  (keeper_meta, string) result

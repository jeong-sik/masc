(** Keeper_turn_up_create — create a new keeper from parsed arguments.

    Extracted from [keeper_turn_up.ml]'s [Ok None] branch. Handles
    initial keeper meta construction, checkpoint creation,
    keepalive start, and response JSON generation. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** Commit a freshly-built Keeper metadata snapshot through its Owner. *)
val write_initial_meta :
  Workspace.config -> keeper_meta -> (unit, string) result

(** Create a new keeper from parsed args: build initial meta,
    write checkpoint, start keepalive, return the [keeper_up]
    response envelope. *)
val create_keeper :
  _ Keeper_types_profile.context ->
  Keeper_turn_up_args.parsed_args ->
  tool_result

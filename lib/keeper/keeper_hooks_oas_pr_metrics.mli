(** Keeper_hooks_oas_pr_metrics — PR action metric helpers.

    Sibling module of [Keeper_hooks_oas]; see the .ml header for the
    decomposition history. The public surface mirrors what the parent
    module's [make_hooks] and [For_testing] consume; intermediate
    parsing helpers stay private. *)

open Keeper_hooks_oas_types

val pr_review_action_metric_event_of_tool_io :
  route_via_fallback:string option ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  transport_success:bool ->
  pr_review_action_metric_event option

val pr_work_action_metric_events_of_tool_io :
  route_via_fallback:string option ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  transport_success:bool ->
  pr_work_action_metric_event list

val append_pr_review_action_metric :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  generation:int ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  transport_success:bool ->
  duration_ms:float ->
  unit -> unit

val append_pr_work_action_metrics :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  generation:int ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_text:string ->
  transport_success:bool ->
  duration_ms:float ->
  unit -> unit

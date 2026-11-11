(** The cli lane-slot fallback (RFC cli-runtimes-as-lane-slots): after the HTTP
    candidates are exhausted, the official-client runtimes the lane declares
    are walked one by one under the same exact-attempt contract.
    [Hitl_summary_worker] includes this module. *)

open Keeper_approval_queue_rules_types
open Hitl_summary_flow_prepare
open Hitl_summary_exact_queue

type cli_walk_outcome =
  | Cli_no_slots
      (* Nothing declared — the caller keeps its pre-cli behaviour. *)
  | Cli_summary
      (* A cli slot answered; the summary is completed and delivered. *)
  | Cli_settled
      (* Every cli slot failed or waits for its provider, and the entry was
         settled here: under the last cli identity, under the caller's
         binding when no slot ran, or under a held slot's identity when
         nothing was bound. Nothing left for the caller to settle. *)
  | Cli_fell_back
      (* The walk could not take over (release/bind persistence refused);
         the pre-cli binding state is intact, so the caller settles exactly
         as it would have without cli slots. *)

val settle_held_slot :
  queue_ops:exact_queue_ops ->
  prepared_flow ->
  slot_id:string ->
  until:float ->
  unit
(** Settle an entry with nothing bound whose remaining slots all wait for a
    time their providers stated (RFC-exact-lane-waits-for-a-stated-reset R5).
    Nothing is called. Called, those slots would have been refused for their
    accounts and the entry quarantined as an execution failure, so
    [slot_id]'s identity is bound and quarantined that way. The identity's
    [held:] plan fingerprint and [held-hitl-] call id mark it as never
    dispatched. When the bind is refused, the entry settles as an unbound one
    does. [until] is logged, Unix epoch seconds. *)

val try_cli_slots :
  queue_ops:exact_queue_ops ->
  cli_runner:Keeper_lane_cli_oneshot.runner option ->
  bound:exact_identity option ->
  prepared_flow ->
  on_summary:(hitl_context_summary -> 'a) ->
  cli_walk_outcome

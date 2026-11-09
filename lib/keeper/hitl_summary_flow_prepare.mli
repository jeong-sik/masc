(** The immutable MASC request of the HITL judgment and the flow prepared from
    it: lane id, system prompt, output requirement, the candidate slots
    resolved from the runtime registry, and the readiness snapshot of that
    topology. [Hitl_summary_worker] includes this module. *)

open Keeper_approval_queue_rules_types

module Registry = Runtime_exact_output_registry

val lane_id : string

val system_prompt : unit -> (string, string) result

val output_requirement : Agent_core.Exact_output.output_requirement

type prepared_transport =
  | Http_attempt of Agent_core.Exact_output.flow_attempt * Registry.resolved_lane
  | Http_held of
      { slot_id : string
      ; until : float
      }
      (** The lane has no CLI slot and every HTTP slot waits for a time its
          provider stated (RFC-exact-lane-waits-for-a-stated-reset). [until]
          is the earliest such time, Unix epoch seconds, and [slot_id] the
          slot it belongs to. Nothing is called. *)
  | Cli_only

type prepared_flow =
  { entry : pending_approval
  ; generated_at : float
  ; transport : prepared_transport
  ; cli_slots : string list
        (* Official-client runtime ids the lane walks after every catalog
           slot is exhausted, carried from the resolved lane declaration
           (RFC cli-runtimes-as-lane-slots). *)
  ; system_prompt : string
  ; context_bundle : Yojson.Safe.t
        (* Kept beside the frozen HTTP attempt because a cli one-shot has no
           request body: its input is the rendered prompt, rebuilt from the
           same contract and bundle the HTTP messages carry. *)
  }

val prepare_flow :
  entry:pending_approval ->
  (prepared_flow, string) result

val snapshot_topology_readiness : unit -> (unit, string) result

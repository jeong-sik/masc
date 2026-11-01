(** Immutable request evidence retained by one materialized runtime attempt.

    Attribution and wire measurements are independent: official clients can
    report transmitted input without exposing a MASC-owned serialized body.
    The caller owns the publication cell, observation effects and turn-local
    input windows, response observations, comparison state and digest memo. *)

type attribution =
  { runtime_profile : string
    (** The lane attempt that assembled this request. A turn that failed over
        settles on a different runtime, and the record keeps both so a reader
        compares instead of assuming. *)
  ; schema_observation_scope : Agent_core.Base.Schema_observation.scope option
  ; prompt_blocks : Turn_record.prompt_block list
  ; provider_content :
      ( Agent_core.Types.message list
      , Keeper_agent_prompt_metrics.attribution_gap )
      result
    (** The transmitted messages with the typed prompt-context carrier
        removed, or the typed reason there are none to report. A [result]
        rather than an [option]: "the projection never ran", "it ran and its
        output could not be classified", and "this lane resumed a session it
        does not hold" are different facts and the record says which. *)
  ; tools : Agent_core.Tool.t list
    (** The surface this request carried. On the Agent Core lane this comes
        from {!Keeper_agent_tool_surface.on_the_wire} rather than the list the
        turn was built with, because that lane sends a listing in place of the
        attached-service schemas and widens its own set mid-turn. On an
        official-client lane it is the list handed to the client, which the
        Claude lane narrows to [[]] when the target declares no tool
        support. *)
  }

type wire_evidence =
  { wire_observation : Turn_record.request_wire_observation
  ; wire_schema_observation_scope : Agent_core.Base.Schema_observation.scope option
  ; serialized_observation :
      Llm_provider.Request_wire_observer.observation option
  ; wire_projected_messages : Agent_core.Types.message list option
  ; wire_system_prompt : string option
  ; wire_tools : Agent_core.Tool.t list
  }

type projection =
  | Unprojected
  | Projected of
      (Agent_core.Types.message list, Keeper_agent_prompt_metrics.provenance_failure) result

(** [Unprojected] means no retained provider-content projection. A source
    projection failure clears it too; it does not establish dispatch absence.
    [Projected (Error failure)] retains an observed provenance failure. *)

type t
(** An immutable product of projection, attribution and wire evidence. *)

val empty : t
(** No retained observations. Use at initialization and at the existing
    materialized-attempt reset boundary, without clearing turn-local evidence. *)

val projection : t -> projection
val attribution : t -> attribution option
(** [None] means no retained attribution in this attempt. [Some] returns the
    original object; reading or updating other fields preserves its identity. *)

val wire_evidence : t -> wire_evidence option
(** [None] means no retained wire observation in this attempt. Optional fields
    inside an observed wire record retain their independent availability. *)

val observe_projection : projection -> t -> t
(** Replace only the retained projection; preserve attribution and wire. *)

val observe_attribution : attribution -> t -> t
(** Retain the supplied attribution object and preserve the other fields. *)

val observe_wire : wire_evidence -> t -> t
(** Replace only wire evidence. A wire observation without a new attribution
    must preserve any earlier attribution from this same attempt. *)

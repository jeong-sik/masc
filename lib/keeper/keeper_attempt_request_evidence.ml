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

type t =
  { projection : projection
  ; attribution : attribution option
  ; wire_evidence : wire_evidence option
  }

let empty =
  { projection = Unprojected; attribution = None; wire_evidence = None }

let projection state = state.projection
let attribution state = state.attribution
let wire_evidence state = state.wire_evidence

let observe_projection projection state = { state with projection }
let observe_attribution attribution state =
  { state with attribution = Some attribution }
let observe_wire wire_evidence state =
  { state with wire_evidence = Some wire_evidence }

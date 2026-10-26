(** Checkpoint build/restore logic.

    Takes explicit parameters to avoid circular dependency with [Agent.t].
    The caller wraps results into [Agent.t].

    @stability Evolving
    @since 0.93.1 *)

(** {1 Resume} *)

type resume_error =
  | Invalid_checkpoint_version of { expected : int; got : int }
  | Invalid_checkpoint_binding of string
  | Replay_rejected of Llm_provider.Reasoning_history_projection.error

val resume_error_to_string : resume_error -> string

type binding_disposition =
  | Unconfigured_target
  | Unrecorded_producer
  | Identical_source
  | Declared_endpoint_rotation
  | Rebound_without_replay_loss
  | Replay_disabled_by_caller
  | Rebound_pending_dispatch of
      Llm_provider.Reasoning_history_projection.reasoning_replay_drop list

val binding_disposition_to_string : binding_disposition -> string

(** State recovered only after typed replay admission. *)
type resume_state =
  { state : Types.agent_state
  ; context : Context.t
  ; provider_config : Llm_provider.Provider_config.t option
  ; binding_disposition : binding_disposition
  }

(** Build restored state from a checkpoint.

    Messages, usage, turn count, and the default context always come from the
    checkpoint. When [config] is supplied it is the complete caller-owned
    runtime configuration; no checkpoint configuration field silently
    overrides it. Without [config], configuration fields represented by the
    checkpoint are restored over current defaults; non-persisted runtime fields
    use those defaults. Returns state + context; the caller wraps these into
    [Agent.t]. When an exact [provider_config] is supplied, its effective model
    and knobs are overlaid from the restored config and frozen once. Incompatible
    reasoning returns a typed error before context copying or Agent construction
    unless [source_change_policy = Exclude_unselected] explicitly permits
    provisional source-change admission; its disposition retains the pending
    indices/producers. Dispatch must validate the final query boundary before
    excluding any foreign artifact. Canonical messages remain identical.
    The admitted carrier is returned so dispatch keeps that snapshot. Without a
    provider target, restoration cannot dispatch and retains all canonical data. *)
val build_resume
  :  checkpoint:Checkpoint.t
  -> ?source_change_policy:Llm_provider.Reasoning_history_projection.source_change_policy
  -> ?eio_context:bool
  -> ?config:Types.agent_config
  -> ?provider_config:Llm_provider.Provider_config.t
  -> ?context:Context.t
  -> unit
  -> (resume_state, resume_error) result

(** {1 Checkpoint creation} *)

(** Build a checkpoint from explicit state parameters.
    The caller extracts fields from [Agent.t] before calling this. *)
val build_checkpoint
  :  ?session_id:string
  -> ?working_context:Yojson.Safe.t
  -> pending_input:Agent_input_request.pending option
  -> state:Types.agent_state
  -> tools:Tool_set.t
  -> context:Context.t
  -> mcp_clients:Mcp.managed list
  -> unit
  -> Checkpoint.t

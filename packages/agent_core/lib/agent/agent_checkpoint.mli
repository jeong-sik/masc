(** Checkpoint build/restore logic.

    Takes explicit parameters to avoid circular dependency with [Agent.t].
    The caller wraps results into [Agent.t].

    @stability Evolving
    @since 0.93.1 *)

(** {1 Resume} *)

(** State recovered from a checkpoint. *)
type resume_state =
  { state : Types.agent_state
  ; context : Context.t
  }

(** Build restored state from a checkpoint.

    Messages, usage, turn count, and the default context always come from the
    checkpoint. When [config] is supplied it is the complete caller-owned
    runtime configuration; no checkpoint configuration field silently
    overrides it. Without [config], configuration fields represented by the
    checkpoint are restored over current defaults; non-persisted runtime fields
    use those defaults. Returns state + context; the caller wraps these into
    [Agent.t]. *)
val build_resume
  :  checkpoint:Checkpoint.t
  -> ?eio_context:bool
  -> ?config:Types.agent_config
  -> ?context:Context.t
  -> unit
  -> resume_state

(** {1 Checkpoint creation} *)

(** Build a checkpoint from explicit state parameters.
    The caller extracts fields from [Agent.t] before calling this. *)
val build_checkpoint
  :  ?session_id:string
  -> ?working_context:Yojson.Safe.t
  -> state:Types.agent_state
  -> tools:Tool_set.t
  -> context:Context.t
  -> mcp_clients:Mcp.managed list
  -> unit
  -> Checkpoint.t

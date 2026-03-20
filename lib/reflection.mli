(** Reflection Engine — Higher-order insight generation for Generative Agents.

    Triggers when accumulated memory importance exceeds a threshold.
    Retrieves top memories, asks MODEL to find patterns/insights,
    and stores the reflection back into Memory Stream (importance 8-10).

    Based on Stanford Generative Agents (Park et al. 2023).

    @since 4.0.0 *)

(** {1 Configuration} *)

(** Default reflection threshold (sum of importance since last reflection). *)
val default_threshold : int

(** {1 State} *)

(** Check if an agent should reflect based on accumulated importance. *)
val should_reflect : agent_name:string -> bool

(** {1 Reflection} *)

(** Perform reflection: retrieve top memories, generate insight via MODEL,
    store result back into Memory Stream.
    Returns the reflection text.
    [identity] is the agent's description/personality.
    [call_model] invokes the MODEL cascade. *)
val reflect :
  agent_name:string ->
  identity:string ->
  call_model:(prompt:string -> string) ->
  string

(** {1 Tracking} *)

(** Record that a reflection was performed (updates last reflection timestamp). *)
val mark_reflected : agent_name:string -> unit

(** Get the timestamp of the last reflection for an agent.
    Returns 0.0 if no reflection has been performed. *)
val last_reflection_time : agent_name:string -> float

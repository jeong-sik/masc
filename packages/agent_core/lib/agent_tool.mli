(** Wrap an agent as a callable tool (agent-as-tool pattern).

    Creates a {!Tool.t} whose handler spawns a child agent, runs it
    with the tool input as the prompt, and returns the agent's text
    output as the tool result.

    Pattern: Ask-and-return — the child agent gets a prompt, returns text.
    For full conversation transfer, use {!Handoff} instead.

    The runner is a closure to avoid circular dependency with {!Agent.t}.

    @stability Evolving
    @since 0.102.0 *)

(** {1 Types} *)

(** A function that runs an agent with a prompt and returns the response.
    Captured in a closure at tool creation time. *)
type agent_runner = string -> (Types.api_response, Error.sdk_error) result

type child_output =
  { text : string
  ; response : Types.api_response
  }

type config =
  { name : string (** Tool name (shown to the parent agent). *)
  ; description : string (** Tool description (shown to the parent agent). *)
  ; runner : agent_runner (** Closure that captures the child agent and runs it. *)
  ; output_summarizer : (string -> string) option
    (** Optional post-processing of agent output before returning. *)
  }

(** {1 Construction} *)

(** Create a tool that wraps an agent runner.
    When invoked, extracts the "prompt" field from the tool input JSON,
    calls the runner, and returns the text output as a tool result. *)
val create : config -> Tool.t

(** Create a canonical tool for agent-as-tool child invocation. The typed
    constructor connects prompt parsing and {!child_output} encoding at compile
    time; the returned value registers directly in {!Tool_set}. *)
val create_typed : config -> Tool.t

(** Convenience: create from a runner function with minimal config. *)
val create_simple : name:string -> description:string -> agent_runner -> Tool.t

(** Encode typed child output into stable JSON for tool_result content. *)
val child_output_to_json : child_output -> Yojson.Safe.t

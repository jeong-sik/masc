(** Discord_tool_helpers — pure pieces of the [discord_send_message]
    tool surface (RFC-0203 Phase 3).

    Extracted out of {!Tool_discord_dispatch} so unit tests can link
    only against [masc_mcp.gate] (avoiding the parent
    [masc_mcp] library while a pre-existing module cycle in
    [lib/cascade/] keeps it from linking — see MEMORY.md "CI gate
    skip two-strikes 24h", 2026-05-28 #19340).

    {!Tool_discord_dispatch} is the [masc_mcp] glue that calls
    {!dispatch} with the real [Channel_gate_discord_state.send_message]
    and registers the resulting handler via [Tool_spec.register]. *)

(** {1 Typed input} *)

type input =
  { channel_id : string
  ; content : string
  }

val parse_input : Yojson.Safe.t -> (input, string) result

(** {1 Feature flag}

    Reads [MASC_DISCORD_BUILTIN] through {!Env_config_core.get_bool};
    default [false]. *)
val builtin_enabled : unit -> bool

(** {1 Failure classification}

    Closed match — adding a new {!Channel_gate_discord_state.send_error}
    variant forces this function to be updated. *)
val failure_class_of_send_error
  :  Channel_gate_discord_state.send_error
  -> Tool_result.tool_failure_class

(** {1 Dispatch core}

    [dispatch ~send ~tool_name ~name ~args] is the pure dispatcher.
    The caller supplies [send] (typically
    {!Channel_gate_discord_state.send_message}) so tests can inject a
    stub that never touches the network.

    Returns [None] iff [name <> tool_name] — the same contract as
    {!Tool_dispatch.handler}. *)
val dispatch
  :  send:(channel_id:string ->
          content:string ->
          (string, Channel_gate_discord_state.send_error) result)
  -> tool_name:string
  -> name:string
  -> args:Yojson.Safe.t
  -> Tool_result.result option

(** {1 Schema} *)

val input_schema : Yojson.Safe.t
(** JSON-Schema object describing [{channel_id, content}]. *)

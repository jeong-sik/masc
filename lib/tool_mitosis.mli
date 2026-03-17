(** Mitosis Tool Handlers.

    MCP tool handlers for the mitosis subsystem, extracted from
    [mcp_server_eio.ml] for testability. Provides 8 tools plus a dispatcher:

    - [masc_mitosis_status] -- current cell status and context pressure
    - [masc_mitosis_all] -- all cells and pool state
    - [masc_mitosis_pool] -- stem cell pool details
    - [masc_mitosis_divide] -- force immediate division
    - [masc_mitosis_check] -- 2-phase mitosis check (prepare/handoff)
    - [masc_mitosis_record] -- record generational metrics
    - [masc_mitosis_prepare] -- force Phase 1 DNA preparation
    - [masc_mitosis_handoff] -- 2-phase proactive context handoff

    Key tool: [masc_mitosis_handoff] implements the 2-phase approach:
    - 50% threshold: DNA preparation (context summary extracted).
    - 80% threshold: Handoff execution (spawn successor agent).

    Episode storage is integrated via the Agent Being Protocol:
    successful handoffs queue episodes to be flushed by [masc_episode_flush].

    @since 0.3.0 *)

(** {1 Context} *)

(** Existential wrapper for Eio clocks of any type.

    Hides the phantom type parameter of [Eio.Time.clock] so
    it can be stored in a record without universally quantifying. *)
type any_clock = Clock : _ Eio.Time.clock -> any_clock

(** Tool handler context.

    Carries configuration and optional Eio resources needed by the tool
    handlers. Construct with {!make_context}, {!make_context_with_logger},
    or {!make_context_with_eio}. *)
type context = {
  config : Room_utils.config;
      (** Room configuration including backend and cluster settings. *)
  logger : (string -> unit) option;
      (** Optional logging callback. When [None], log messages are silently dropped. *)
  sw : Eio.Switch.t option;
      (** Eio switch for non-blocking spawn. When [None], falls back to blocking spawn. *)
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
      (** Eio process manager for spawning agent subprocesses. *)
  clock : any_clock option;
      (** Eio clock for time-based operations (cooldown enforcement). *)
}

(** [make_context config] creates a minimal context with no logger
    and no Eio resources. Spawns use blocking [Spawn.spawn].

    Backward compatible with code that only needs [config]. *)
val make_context : Room_utils.config -> context

(** [make_context_with_logger config logger] creates a context with
    a logging callback but no Eio resources. *)
val make_context_with_logger : Room_utils.config -> (string -> unit) -> context

(** [make_context_with_eio ~config ~sw ~proc_mgr ~clock] creates a
    full-featured context with Eio resources for non-blocking spawn.

    @param config room configuration
    @param sw Eio switch scope for the spawn fiber
    @param proc_mgr process manager for subprocess creation
    @param clock Eio clock for time-based operations *)
val make_context_with_eio :
  config:Room_utils.config ->
  sw:Eio.Switch.t ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  clock:_ Eio.Time.clock ->
  context

(** [log ctx msg] writes [msg] via the context's logger callback.
    No-op if [ctx.logger] is [None]. Exposed for testing. *)
val log : context -> string -> unit

(** {1 Cooldown State} *)

(** Mutable reference holding the Unix timestamp of the last successful
    handoff. Used to enforce the cooldown period between handoffs
    (configurable via [MASC_MITOSIS_HANDOFF_COOLDOWN_SEC]). *)
val last_handoff_time : float ref

(** [reset_handoff_cooldown ()] resets {!last_handoff_time} to [0.0].
    Intended for use in tests to clear cooldown state between runs. *)
val reset_handoff_cooldown : unit -> unit

(** {1 Result Type} *)

(** Tool result: [(success, json_response)].
    [success] is [true] when the tool executed without errors. *)
type result = bool * string

(** {1 DNA Validation} *)

(** [validate_dna dna] checks DNA quality before handoff.

    Validation criteria:
    - Minimum length (non-trivial content)
    - Presence of goal/task markers
    - Acceptable whitespace ratio (not mostly blank)
    - Structural markers present

    @return [Ok dna] if validation passes, [Error reason] otherwise. *)
val validate_dna : string -> (string, string) Stdlib.result

(** {1 Individual Handlers} *)

(** [handle_mitosis_status ctx args] returns current cell status,
    generation, context pressure estimate, and phase information. *)
val handle_mitosis_status : context -> Yojson.Safe.t -> result

(** [handle_mitosis_all ctx args] returns all cells (active + pool)
    and complete mitosis configuration as JSON. *)
val handle_mitosis_all : context -> Yojson.Safe.t -> result

(** [handle_mitosis_pool ctx args] returns stem cell pool details:
    pool size, warm-up count, and individual cell states. *)
val handle_mitosis_pool : context -> Yojson.Safe.t -> result

(** [handle_mitosis_divide ctx args] forces immediate cell division
    regardless of threshold state. Useful for manual testing.

    Required arg: [agent_name] (string). *)
val handle_mitosis_divide : context -> Yojson.Safe.t -> result

(** [handle_mitosis_check ctx args] runs the 2-phase mitosis check
    and returns the result without executing handoff.

    Required args: [context_ratio] (float), [full_context] (string). *)
val handle_mitosis_check : context -> Yojson.Safe.t -> result

(** [handle_mitosis_record ctx args] records a generational metric
    (task completion, handoff, or retention test) into
    {!Generational_metrics}.

    Required args: [generation] (int), [task_id] (string),
    [completed] (bool), [duration_ms] (int). *)
val handle_mitosis_record : context -> Yojson.Safe.t -> result

(** [handle_mitosis_prepare ctx args] forces Phase 1 DNA preparation
    for the current cell, extracting DNA from the provided context.

    Required args: [full_context] (string). *)
val handle_mitosis_prepare : context -> Yojson.Safe.t -> result

(** [handle_mitosis_handoff ctx args] executes the full 2-phase
    proactive handoff. At 50% context, prepares DNA. At 80%, spawns
    a successor agent with the merged DNA.

    Respects cooldown period and validates DNA quality before handoff.

    Required args: [context_ratio] (float), [full_context] (string),
    [agent_name] (string). *)
val handle_mitosis_handoff : context -> Yojson.Safe.t -> result

(** {1 Dispatcher} *)

(** [dispatch ctx ~name ~args] routes a tool call to the appropriate
    mitosis handler based on [name].

    @return [Some result] if [name] matches a mitosis tool
      (e.g., ["masc_mitosis_status"]), [None] otherwise. *)
val dispatch : context -> name:string -> args:Yojson.Safe.t -> result option

val schemas : Types.tool_schema list

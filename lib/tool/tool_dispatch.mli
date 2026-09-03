
(** Central Tool Dispatch Registry.

    Production MCP tool names route through {!Tool_name} and the module-tag
    registry. Handlers, hook composition, and tag/schema routing are published
    as separate immutable atomic snapshots. *)

(** Registered handlers are total for their exact registry key. Missing
    handlers are represented by the registry lookup performed by
    {!guarded_dispatch}, not by the handler result. *)
type handler = name:string -> args:Yojson.Safe.t -> Tool_result.result

(** {1 Registration} *)

val register : tool_name:string -> handler:handler -> unit
(** Register a single tool name to handler mapping. *)

(** {1 Dispatch} *)

(** [guarded_dispatch] owns telemetry, pre-hooks, handler execution, result
    transformation, and dispatch observer fan-out. *)

val mint_token : name:string -> (Tool_token.t, string) Result.t
(** Mint a [Tool_token.t] whose name is present in the immutable tag snapshot.

    Note the asymmetry: this checks the tag snapshot while [guarded_dispatch]
    looks the handler up in the handler snapshot. A name registered in one and
    not the other mints a token that then dispatches to nothing. *)

(** {2 Dispatch Hooks And Observers}

    Pre-hooks run before the handler; dispatch observers run after the
    outcome is known.

    Pre-hooks return a {!pre_hook_action}:
    - [Pass]: this hook has no opinion — continue to next hook.
    - [Proceed coerced_args]: replace args and continue (e.g. type coercion).
    - [Reject result]: short-circuit with an error result. *)

type pre_hook_action =
  | Pass
  | Proceed of Yojson.Safe.t
  | Reject of Tool_result.result

type pre_hook = name:string -> args:Yojson.Safe.t -> pre_hook_action
(** Pre-hook: receives tool name and args before handler runs. *)

type dispatch_observer =
  Dispatch_outcome.t -> Tool_result.result option -> unit
(** Observer called after dispatch finalization.

    Receives the typed {!Dispatch_outcome.t} together with the
    handler-produced {!Tool_result.result} (when the [Handled] arm ran)
    once dispatch completes — regardless of which arm fired
    ([Handled] / [No_handler]).

    The optional [Tool_result.result] is [Some _] only on the [Handled]
    arm; other arms receive [None].  Observer-only ([unit] return) —
    cannot mutate the outcome. *)

val register_pre_hook : pre_hook -> unit

val register_dispatch_observer : dispatch_observer -> unit
(** Register a dispatch observer. See {!dispatch_observer} for the contract. *)

(** {2 Telemetry span wrapper (injected)} *)

type trace_id = string

type span_wrapper =
  ?force_new_trace_id:bool
  -> ?surface:string
  -> tool_name:string
  -> ((unit -> (trace_id * trace_id) option) -> Tool_result.result option * string)
  -> Tool_result.result option * string
(** Wrapper applied around the dispatch body in {!guarded_dispatch}. Mirrors the
    shape of [Tool_telemetry.with_span]: it opens a span, runs the body (which
    receives a trace-link thunk and returns [(result, outcome_label)]), and
    finalizes the metric with [outcome_label]. The default is the identity
    wrapper. *)

val set_span_wrapper : span_wrapper -> unit
(** Install the dispatch span wrapper. The composition root registers
    [Tool_telemetry.with_span] so this library (lib/tool/, [masc_tool_dispatch])
    does not code-depend on the Otel/Otel_metric_store telemetry stack — the compiler
    enforces "Tool is just Tool". See
    [Server_bootstrap_maintenance.start_background_maintenance]. *)

val clear_hooks : unit -> unit
(** Atomically reset pre-hooks, dispatch observers, and the span wrapper
    (back to identity). *)

val run_pre_hooks :
  name:string -> args:Yojson.Safe.t -> Tool_result.result option * Yojson.Safe.t
(** Execute registered pre-hooks in order, threading coerced args.
    Returns [(Some rejection, _)] on short-circuit,
    or [(None, final_args)] when all hooks pass. *)

val run_dispatch_observers :
  Dispatch_outcome.t -> Tool_result.result option -> unit
(** Execute registered observers against the typed outcome.
    Invoked from [guarded_dispatch] for every
    arm with the optional handler {!Tool_result.result} ([Some _] on the
    [Handled] arm, [None] otherwise). *)

val guarded_dispatch
  :  token:Tool_token.t
  -> args:Yojson.Safe.t
  -> unit
  -> Tool_result.result option
(** Single dispatch entry with typed telemetry.

    Owns the injected span wrapper ({!set_span_wrapper}, registered with
    [Tool_telemetry.with_span] at the composition root), the pre-hook chain,
    handler lookup, exception capture, result transformation, and observer
    fan-out. [None] means that the token has no directly registered handler. *)

(** {1 Introspection} *)

val registered_count : unit -> int
(** Number of registered tool names. *)

val is_registered : string -> bool
(** Check whether a tool name is registered. *)

(** {2 Module Tag Dispatch}

    Known tool names map to module tags through a compile-time match or the
    tag registry. Handler registration does not authorize tool names. *)

type module_tag =
  | Mod_plan | Mod_operator
  | Mod_local_runtime
  | Mod_run
  | Mod_agent | Mod_task | Mod_state
  | Mod_control | Mod_agent_timeline | Mod_schedule | Mod_spawn | Mod_code_query | Mod_misc
  | Mod_library
  (* [Mod_external]: dispatched by a server-boundary handler in the
     composition root, not by a peer [Tool_*] module. The tool layer
     stays agnostic to which subsystem (e.g. keeper) actually handles it. *)
  | Mod_external
  | Mod_inline
  | Mod_keeper_task

val register_module_tag : schemas:Masc_domain.tool_schema list -> tag:module_tag -> unit
(** Register tool names from a schema list with a module tag. *)

val lookup_tag : string -> module_tag option
(** Look up the module tag for a tool name. *)

val lookup_schema : string -> Yojson.Safe.t option
(** Look up the input_schema JSON for a tool name.
    Used by Tool_input_validation pre-hook for argument validation. *)

val tag_registry_count : unit -> int
(** Number of entries in the tag registry. *)

val mark_tag_registry_initialized : unit -> unit
val is_tag_registry_initialized : unit -> bool

(** {1 Registry Enumeration} *)

val all_registered_names : unit -> string list
(** Every tool name registered in the tag registry. Handler-only
    registrations have no tag entry, so they never appear here. Iteration
    order is unspecified. *)

val all_schema_names : unit -> string list
(** Every tool name registered in the schema registry. Iteration order is
    unspecified. *)

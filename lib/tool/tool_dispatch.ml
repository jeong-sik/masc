(** Central Tool Dispatch Registry.

    Production MCP tool names route through {!Tool_name} and the module-tag
    registry. Mutable handler registrations remain only for dispatch
    execution; they are not used for token validation or discovery. *)

(** Registered handlers are total for their exact registry key. Missing
    handlers are represented by the registry lookup, not by a second optional
    result returned from a matched handler. *)
type handler = name:string -> args:Yojson.Safe.t -> Tool_result.result

(** Central registry — populated once during server initialisation. *)
let registry : (string, handler) Hashtbl.t = Hashtbl.create 256

(** Mutex protecting all mutable state in this module.

    Registration and snapshot reads are short and never perform Eio effects,
    so a system mutex is the correct cross-domain boundary.  [Eio_guard]
    deliberately skips locking before the Eio runtime starts and rejects raw
    Domain callers after startup; either behavior is unsound for this
    process-global registry. *)
let dispatch_mu = Stdlib.Mutex.create ()
let with_dispatch_rw f = Stdlib.Mutex.protect dispatch_mu f
let with_dispatch_ro f = Stdlib.Mutex.protect dispatch_mu f

(** Register a single tool name → handler mapping. *)
let register ~tool_name ~(handler : handler) =
  with_dispatch_rw (fun () -> Hashtbl.replace registry tool_name handler)

(** {2 Dispatch Hooks And Observers}

    Pre-hooks run before the handler; observers run after the typed outcome is
    known.
    Multiple hooks are supported — they execute in registration order.

    - Pre-hook returning [Some result] short-circuits (handler is skipped).
      Use cases include permission checks and request logging.
    - Dispatch observers receive the final typed outcome for telemetry,
      metrics, and audit logging. *)

(** Pre-hook action: determines how dispatch proceeds after a hook runs. *)
type pre_hook_action =
  | Pass                            (** This hook has no opinion — continue *)
  | Proceed of Yojson.Safe.t       (** Replace args (e.g. type coercion) and continue *)
  | Reject of Tool_result.result   (** Short-circuit with error result *)

(** Pre-hook: receives tool name and args before handler runs. *)
type pre_hook = name:string -> args:Yojson.Safe.t -> pre_hook_action

(** Observer called after dispatch finalization.

    Receives the typed {!Dispatch_outcome.t} together with the
    handler-produced {!Tool_result.result} (when the [Handled] arm ran)
    once dispatch completes — for whichever arm fired
    ([Handled] / [No_handler]).

    The optional [Tool_result.result] is [Some _] only on the [Handled]
    arm; the [No_handler] arm receives [None] so observers can pattern-match
    on the typed outcome first and read [tool_name] / [success] /
    [duration_ms] from the result only when relevant.

    Returns [unit] because typed hooks are *observers* (metrics,
    spans, audit log) — they cannot mutate the dispatch outcome. *)
type dispatch_observer = Dispatch_outcome.t -> Tool_result.result option -> unit

let pre_hooks : pre_hook list ref = ref []
let dispatch_observers : dispatch_observer list ref = ref []

let register_pre_hook (hook : pre_hook) =
  with_dispatch_rw (fun () -> pre_hooks := !pre_hooks @ [hook])

let register_dispatch_observer (hook : dispatch_observer) =
  with_dispatch_rw (fun () -> dispatch_observers := !dispatch_observers @ [hook])

(** Dispatch span wrapper surface.

    The OTel/Otel_metric_store 4-tuple emission ([Tool_telemetry.with_span]) is
    {e injected} rather than referenced inline, so this library does not
    code-depend on [Tool_telemetry] / [Otel_spans] / [Otel_metric_store]. That keeps
    the Tool dispatch substrate (lib/tool/, [masc_tool_dispatch]) free of the
    telemetry stack — the compiler enforces "Tool is just Tool".

    The wrapper has the shape of [Tool_telemetry.with_span]: it receives a
    trace-id thunk and the dispatch body returning [(result, outcome_label)],
    and returns the same pair. The default is the identity wrapper (no span,
    no metric) so [guarded_dispatch] is correct even before the composition
    root registers the real telemetry — it just emits nothing.

    Registered once at server startup via [set_span_wrapper Tool_telemetry.with_span]
    (see [Server_bootstrap_maintenance.start_background_maintenance]). Monomorphic
    in [Tool_result.result option] because [guarded_dispatch] is the only caller. *)
type trace_id = string

type span_wrapper =
  ?force_new_trace_id:bool
  -> ?surface:string
  -> tool_name:string
  -> ((unit -> (trace_id * trace_id) option) -> Tool_result.result option * string)
  -> Tool_result.result option * string

let identity_span_wrapper : span_wrapper =
  fun ?force_new_trace_id:_ ?surface:_ ~tool_name:_ body -> body (fun () -> None)
;;

let surface_of_tool_name name =
  let name = String.lowercase_ascii (String.trim name) in
  if String.starts_with ~prefix:"masc_" name
     || Tool_transport_prefix.has name
  then "mcp"
  else if String.starts_with ~prefix:"keeper_" name
  then "keeper"
  else "internal"
;;

let span_wrapper_ref : span_wrapper ref = ref identity_span_wrapper

let set_span_wrapper (w : span_wrapper) =
  with_dispatch_rw (fun () -> span_wrapper_ref := w)
;;

let clear_hooks () =
  with_dispatch_rw (fun () ->
    pre_hooks := [];
    dispatch_observers := [];
    span_wrapper_ref := identity_span_wrapper)

(** Run pre-hooks in order, threading coerced args through the chain.
    First [Reject] wins (short-circuit). [Proceed] replaces args for
    subsequent hooks and the final handler. *)
let run_pre_hooks ~name ~args =
  let hooks = with_dispatch_ro (fun () -> !pre_hooks) in
  let rec go current_args = function
    | [] -> (None, current_args)
    | hook :: rest ->
      (match hook ~name ~args:current_args with
       | Reject result -> (Some result, current_args)
       | Proceed new_args -> go new_args rest
       | Pass -> go current_args rest)
  in
  go args hooks

(** Run observers in order against the typed dispatch outcome.
    Each hook is invoked for its side-effects; mutation of the
    outcome is not permitted (see [dispatch_observer] above).

    [result] is [Some r] only on the [Handled] arm; other arms
    pass [None] so observers can branch on the typed outcome first. *)
let run_dispatch_observers
    (outcome : Dispatch_outcome.t)
    (result : Tool_result.result option) : unit =
  let observers = with_dispatch_ro (fun () -> !dispatch_observers) in
  List.iter (fun hook -> hook outcome result) observers

(** Single dispatch entry. The lifecycle is:

      1. injected span wrapper         (4-tuple emission; identity by default,
                                         [Tool_telemetry.with_span] at runtime)
      2. pre-hook chain                (reject / coerce-args)
      3. registry lookup + handler     (handler exception capture)
      4. observer fan-out              ([run_dispatch_observers]) *)
let guarded_dispatch ~(token : Tool_token.t) ~args () : Tool_result.result option =
  let span_wrapper = with_dispatch_ro (fun () -> !span_wrapper_ref) in
  let result, _outcome =
    (* Injected telemetry span wrapper (default identity). The composition
       root registers [Tool_telemetry.with_span] so this lib stays free of
       the Otel/Otel_metric_store stack. *)
    span_wrapper
      ~tool_name:token.name
      ~surface:(surface_of_tool_name token.name)
      (fun _trace_id_thunk ->
      let name = token.name in
      let r =
        match run_pre_hooks ~name ~args with
        | (Some _ as blocked, _) -> blocked
        | (None, coerced_args) ->
          (match with_dispatch_ro (fun () -> Hashtbl.find_opt registry name) with
           | Some handler ->
             let start_time = Time_compat.now () in
             (try Some (handler ~name ~args:coerced_args)
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn -> Some (Tool_result.make_err_of_exn ~tool_name:name ~start_time exn))
           | None -> None)
      in
      (* Finalization is done inline because [Tool_dispatch] cannot depend on
         [Tool_dispatch_emit] without creating a dependency cycle.  Observers
         receive the exact handler result and cannot mutate it. *)
      let typed_outcome = Dispatch_outcome.of_result_option r in
      run_dispatch_observers typed_outcome r;
      r, Dispatch_outcome.to_string typed_outcome)
  in
  result
;;

(** Number of registered tool names. *)
let registered_count () = with_dispatch_ro (fun () -> Hashtbl.length registry)

(** Check whether a tool name is registered. *)
let is_registered name =
  with_dispatch_ro (fun () -> Hashtbl.mem registry name)

(** {2 Module Tag Dispatch}

    Known tool names map to module tags through a compile-time match or the
    tag registry. Handler registration does not authorize tool names. *)

(* [module_tag] is defined in the zero-dep leaf [Tool_tag_types] and
   re-exported here by type-equality, so external [Tool_dispatch.Mod_*] call
   sites and [tool_dispatch.mli] are unchanged. *)
type module_tag = Tool_tag_types.module_tag =
  | Mod_plan | Mod_operator
  | Mod_local_runtime
  | Mod_run
  | Mod_compact
  | Mod_agent | Mod_task | Mod_state
  | Mod_control | Mod_agent_timeline | Mod_schedule | Mod_spawn | Mod_code_query | Mod_misc
  | Mod_library | Mod_external
  | Mod_inline
  | Mod_keeper_task

let tag_registry : (string, module_tag) Hashtbl.t = Hashtbl.create 512
let tag_registry_initialized = Atomic.make false

(** Schema registry — maps tool name → input_schema JSON.
    Populated alongside tag_registry during server initialization.
    Used by Tool_input_validation pre-hook to validate arguments
    before dispatch (C-4 precondition validation). *)
let schema_registry : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 512

let register_module_tag ~(schemas : Masc_domain.tool_schema list) ~tag =
  with_dispatch_rw (fun () ->
    List.iter (fun (s : Masc_domain.tool_schema) ->
      Hashtbl.replace tag_registry s.name tag;
      Hashtbl.replace schema_registry s.name s.input_schema) schemas)

let lookup_tag name = with_dispatch_ro (fun () -> Hashtbl.find_opt tag_registry name)

let lookup_schema name = with_dispatch_ro (fun () -> Hashtbl.find_opt schema_registry name)

let tag_registry_count () = with_dispatch_ro (fun () -> Hashtbl.length tag_registry)

let mark_tag_registry_initialized () = with_dispatch_rw (fun () -> Atomic.set tag_registry_initialized true)
let is_tag_registry_initialized () = with_dispatch_ro (fun () -> Atomic.get tag_registry_initialized)

(** Mint a [Tool_token.t] validated against the tag registry.
    Protected by dispatch_mu for thread safety (Copilot review).
    Handler-only registrations are executable only after a caller already
    holds a token minted through the canonical route registry. *)
let mint_token ~name =
  with_dispatch_ro (fun () ->
    Tool_token.mint_with
      ~validate:(fun n -> Hashtbl.mem tag_registry n)
      ~name)

(** Enumerate every tool name registered in the tag registry. Handler-only
    registrations have no tag entry, so they never appear here. *)
let all_registered_names () =
  with_dispatch_ro (fun () -> Hashtbl.fold (fun n _ a -> n :: a) tag_registry [])

let all_schema_names () =
  with_dispatch_ro (fun () -> Hashtbl.fold (fun n _ a -> n :: a) schema_registry [])

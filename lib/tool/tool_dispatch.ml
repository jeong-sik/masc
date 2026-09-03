(** Central Tool Dispatch Registry.

    Production MCP tool names route through {!Tool_name} and the module-tag
    registry. Each process-wide authority is published as an immutable atomic
    snapshot: handlers, hook composition, and tag/schema routing. *)

(** Registered handlers are total for their exact registry key. Missing
    handlers are represented by the registry lookup, not by a second optional
    result returned from a matched handler. *)
type handler = name:string -> args:Yojson.Safe.t -> Tool_result.result

module By_name = Set_util.StringMap

(** Central handler registry — populated during server initialisation. *)
let handler_registry : handler By_name.t Atomic.t = Atomic.make By_name.empty

(** Register a single tool name → handler mapping. *)
let register ~tool_name ~(handler : handler) =
  Atomic_util.update handler_registry (fun current ->
    By_name.add tool_name handler current)

(** {2 Dispatch Hooks And Observers}

    Pre-hooks run before the handler; observers run after the typed outcome is
    known.
    Multiple hooks are supported — they execute in registration order.

    - Pre-hook returning [Reject result] short-circuits (handler is skipped).
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

type hook_snapshot = {
  pre_hooks : pre_hook list;
  dispatch_observers : dispatch_observer list;
  span_wrapper : span_wrapper;
}

let hook_snapshot =
  Atomic.make
    {
      pre_hooks = [];
      dispatch_observers = [];
      span_wrapper = identity_span_wrapper;
    }

let register_pre_hook (hook : pre_hook) =
  Atomic_util.update hook_snapshot (fun current ->
    { current with pre_hooks = current.pre_hooks @ [ hook ] })

let register_dispatch_observer (hook : dispatch_observer) =
  Atomic_util.update hook_snapshot (fun current ->
    {
      current with
      dispatch_observers = current.dispatch_observers @ [ hook ];
    })

let set_span_wrapper (span_wrapper : span_wrapper) =
  Atomic_util.update hook_snapshot (fun current ->
    { current with span_wrapper })

let clear_hooks () =
  Atomic.set
    hook_snapshot
    {
      pre_hooks = [];
      dispatch_observers = [];
      span_wrapper = identity_span_wrapper;
    }

let surface_of_tool_name name =
  let name = String.lowercase_ascii (String.trim name) in
  if String.starts_with ~prefix:"masc_" name
     || Tool_transport_prefix.has name
  then "mcp"
  else if String.starts_with ~prefix:"keeper_" name
  then "keeper"
  else "internal"
;;

(** Run pre-hooks in order, threading coerced args through the chain.
    First [Reject] wins (short-circuit). [Proceed] replaces args for
    subsequent hooks and the final handler. *)
let run_pre_hook_chain hooks ~name ~args =
  let rec go current_args = function
    | [] -> (None, current_args)
    | hook :: rest ->
      (match hook ~name ~args:current_args with
       | Reject result -> (Some result, current_args)
       | Proceed new_args -> go new_args rest
       | Pass -> go current_args rest)
  in
  go args hooks

let run_pre_hooks ~name ~args =
  run_pre_hook_chain (Atomic.get hook_snapshot).pre_hooks ~name ~args

(** Run observers in order against the typed dispatch outcome.
    Each hook is invoked for its side-effects; mutation of the
    outcome is not permitted (see [dispatch_observer] above).

    [result] is [Some r] only on the [Handled] arm; other arms
    pass [None] so observers can branch on the typed outcome first. *)
let notify_dispatch_observers observers
    (outcome : Dispatch_outcome.t)
    (result : Tool_result.result option) : unit =
  List.iter (fun hook -> hook outcome result) observers

let run_dispatch_observers outcome result =
  notify_dispatch_observers
    (Atomic.get hook_snapshot).dispatch_observers
    outcome
    result

(** Single dispatch entry. The lifecycle is:

      1. injected span wrapper         (4-tuple emission; identity by default,
                                         [Tool_telemetry.with_span] at runtime)
      2. pre-hook chain                (reject / coerce-args)
      3. registry lookup + handler     (handler exception capture)
      4. observer fan-out              ([run_dispatch_observers]) *)
let guarded_dispatch ~(token : Tool_token.t) ~args () : Tool_result.result option =
  let hooks = Atomic.get hook_snapshot in
  let handlers = Atomic.get handler_registry in
  let result, _outcome =
    (* Injected telemetry span wrapper (default identity). The composition
       root registers [Tool_telemetry.with_span] so this lib stays free of
       the Otel/Otel_metric_store stack. *)
    hooks.span_wrapper
      ~tool_name:token.name
      ~surface:(surface_of_tool_name token.name)
      (fun _trace_id_thunk ->
      let name = token.name in
      let r =
        match run_pre_hook_chain hooks.pre_hooks ~name ~args with
        | (Some _ as blocked, _) -> blocked
        | (None, coerced_args) ->
          (match By_name.find_opt name handlers with
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
      notify_dispatch_observers hooks.dispatch_observers typed_outcome r;
      r, Dispatch_outcome.to_string typed_outcome)
  in
  result
;;

(** Number of registered tool names. *)
let registered_count () = By_name.cardinal (Atomic.get handler_registry)

(** Check whether a tool name is registered. *)
let is_registered name =
  By_name.mem name (Atomic.get handler_registry)

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
  | Mod_agent | Mod_task | Mod_state
  | Mod_control | Mod_agent_timeline | Mod_schedule | Mod_spawn | Mod_code_query | Mod_misc
  | Mod_library | Mod_external
  | Mod_inline
  | Mod_keeper_task

(** Schema registry — maps tool name → input_schema JSON.
    Populated alongside tag_registry during server initialization.
    Used by Tool_input_validation pre-hook to validate arguments
    before dispatch (C-4 precondition validation). *)

type routing_snapshot = {
  tags : module_tag By_name.t;
  schemas : Yojson.Safe.t By_name.t;
  initialized : bool;
}

let routing_snapshot =
  Atomic.make
    { tags = By_name.empty; schemas = By_name.empty; initialized = false }

let register_module_tag ~(schemas : Masc_domain.tool_schema list) ~tag =
  Atomic_util.update routing_snapshot (fun current ->
    let tags, schemas =
      List.fold_left
        (fun (tags, schemas) (schema : Masc_domain.tool_schema) ->
          ( By_name.add schema.name tag tags,
            By_name.add schema.name schema.input_schema schemas ))
        (current.tags, current.schemas)
        schemas
    in
    { current with tags; schemas })

let lookup_tag name =
  By_name.find_opt name (Atomic.get routing_snapshot).tags

let lookup_schema name =
  By_name.find_opt name (Atomic.get routing_snapshot).schemas

let tag_registry_count () =
  By_name.cardinal (Atomic.get routing_snapshot).tags

let mark_tag_registry_initialized () =
  Atomic_util.update routing_snapshot (fun current ->
    { current with initialized = true })

let is_tag_registry_initialized () =
  (Atomic.get routing_snapshot).initialized

(** Mint a [Tool_token.t] validated against the tag registry.
    Handler-only registrations are executable only after a caller already
    holds a token minted through the canonical route registry. *)
let mint_token ~name =
  let routing = Atomic.get routing_snapshot in
  Tool_token.mint_with ~validate:(fun n -> By_name.mem n routing.tags) ~name

(** Enumerate every tool name registered in the tag registry. Handler-only
    registrations have no tag entry, so they never appear here. *)
let all_registered_names () =
  By_name.bindings (Atomic.get routing_snapshot).tags
  |> List.map fst

let all_schema_names () =
  By_name.bindings (Atomic.get routing_snapshot).schemas
  |> List.map fst

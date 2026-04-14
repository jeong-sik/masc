(** Central Tool Dispatch Registry — O(1) Hashtbl-based dispatch.

    Replaces the 40+ sequential match chain in mcp_server_eio.ml with
    a single Hashtbl lookup.  Each Tool_X module registers a closure
    that captures its own context, so the dispatch layer does not need
    to know about heterogeneous context types.

    Activated by MASC_DISPATCH_V2=1; the legacy match chain is the
    default fallback. *)

(** Unified handler type: every tool call is [name * args -> result option].
    [None] means "this handler does not know this tool" (should not happen
    when lookups go through the registry, but kept for compatibility). *)
type handler = name:string -> args:Yojson.Safe.t -> (bool * string) option

(** Central registry — populated once during server initialisation. *)
let registry : (string, handler) Hashtbl.t = Hashtbl.create 256

(** Mutex protecting all mutable state in this module.
    Uses Eio_guard for dual-mode (pre/post Eio runtime) locking. *)
let dispatch_mu = Eio.Mutex.create ()
let with_dispatch_rw f = Eio_guard.with_mutex dispatch_mu f
let with_dispatch_ro f = Eio_guard.with_mutex_ro dispatch_mu f

(** Register a single tool name → handler mapping. *)
let register ~tool_name ~(handler : handler) =
  with_dispatch_rw (fun () -> Hashtbl.replace registry tool_name handler)

(** Bulk-register every tool name from a schema list to the same handler.
    This is the primary registration path — it extracts names from the
    module's published schemas, ensuring the registry is always in sync
    with the advertised tool list. *)
let register_module ~(schemas : Types.tool_schema list) ~(handler : handler) =
  with_dispatch_rw (fun () ->
    List.iter
      (fun (schema : Types.tool_schema) ->
        Hashtbl.replace registry schema.name handler)
      schemas)

(** {2 Dispatch Hooks}

    Pre-hooks run before the handler; post-hooks run after.
    Multiple hooks are supported — they execute in registration order.

    - Pre-hook returning [Some result] short-circuits (handler is skipped).
      Use case: permission checks (Sprint 3), request logging.
    - Post-hook transforms the result.  Identity function when observing only.
      Use case: tracing spans (Sprint 2), metrics collection. *)

(** Pre-hook action: determines how dispatch proceeds after a hook runs. *)
type pre_hook_action =
  | Pass                        (** This hook has no opinion — continue *)
  | Proceed of Yojson.Safe.t   (** Replace args (e.g. type coercion) and continue *)
  | Reject of Tool_result.t    (** Short-circuit with error result *)

(** Pre-hook: receives tool name and args before handler runs. *)
type pre_hook = name:string -> args:Yojson.Safe.t -> pre_hook_action

(** Post-hook: receives result after handler completes.
    Return the (possibly transformed) result. *)
type post_hook = Tool_result.t -> Tool_result.t

let pre_hooks : pre_hook list ref = ref []
let post_hooks : post_hook list ref = ref []

let register_pre_hook (hook : pre_hook) =
  with_dispatch_rw (fun () -> pre_hooks := !pre_hooks @ [hook])

let register_post_hook (hook : post_hook) =
  with_dispatch_rw (fun () -> post_hooks := !post_hooks @ [hook])

let clear_hooks () =
  with_dispatch_rw (fun () -> pre_hooks := []; post_hooks := [])

(** Run pre-hooks in order, threading coerced args through the chain.
    First [Reject] wins (short-circuit). [Proceed] replaces args for
    subsequent hooks and the final handler. *)
let run_pre_hooks ~name ~args =
  let rec go current_args = function
    | [] -> (None, current_args)
    | hook :: rest ->
      (match hook ~name ~args:current_args with
       | Reject result -> (Some result, current_args)
       | Proceed new_args -> go new_args rest
       | Pass -> go current_args rest)
  in
  go args !pre_hooks

(** Run post-hooks in order, threading the result through. *)
let run_post_hooks result =
  List.fold_left (fun r hook -> hook r) result !post_hooks

(** O(1) dispatch.  Returns [Some (success, message)] when a handler is
    found, [None] when the tool name is unknown to the registry.
    Handler exceptions are caught and returned as error tuples so the
    caller gets a consistent result shape.

    Post-hooks fire as a side-effect after the handler completes,
    enabling tool metrics and usage logging for all dispatch paths
    (keeper, MCP, tag-dispatch). *)
let dispatch ~(token : Tool_token.t) ~args : (bool * string) option =
  let name = token.name in
  match Hashtbl.find_opt registry name with
  | Some handler ->
    let start_time = Time_compat.now () in
    let result =
      try handler ~name ~args
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Some
          ( false,
            Printf.sprintf "dispatch_v2 handler error for %s: %s" name
              (Printexc.to_string exn) )
    in
    (match result with
     | Some (success, message) ->
       let tr = Tool_result.wrap ~tool_name:name ~start_time (success, message) in
       let tr' = run_post_hooks tr in
       Some (Tool_result.to_legacy tr')
     | None -> None)
  | None -> None

(** Structured dispatch with hook support.

    Execution order: pre-hooks → handler (with post-hooks) → result wrapping.

    Post-hooks are already fired inside [dispatch], so this function only
    adds pre-hook gating and [Tool_result.t] wrapping.

    Returns [None] when the tool is unknown to the registry. *)
let dispatch_structured ~(token : Tool_token.t) ~args : Tool_result.t option =
  let name = token.name in
  match run_pre_hooks ~name ~args with
  | (Some _ as blocked, _) -> blocked
  | (None, coerced_args) ->
    let start_time = Time_compat.now () in
    (match dispatch ~token ~args:coerced_args with
     | Some (success, message) ->
       Some (Tool_result.wrap ~tool_name:name ~start_time (success, message))
     | None -> None)

(** Feature flag: use the new dispatch path.
    Default ON since v2.102 — use MASC_DISPATCH_V2=0 to disable. *)
let v2_enabled = Env_config.Tools.dispatch_v2_enabled

(** Number of registered tool names. *)
let registered_count () = Hashtbl.length registry

(** Check whether a tool name is registered. *)
let is_registered name = Hashtbl.mem registry name

(** --- Hashtbl sets for dispatch capability checks --- *)

let read_only_set : (string, unit) Hashtbl.t = Hashtbl.create 32
let requires_join_set : (string, unit) Hashtbl.t = Hashtbl.create 64
let mcp_context_required_set : (string, unit) Hashtbl.t = Hashtbl.create 64
let destructive_set : (string, unit) Hashtbl.t = Hashtbl.create 16
let idempotent_set : (string, unit) Hashtbl.t = Hashtbl.create 32

let init_read_only_set (names : string list) =
  with_dispatch_rw (fun () ->
    List.iter (fun name -> Hashtbl.replace read_only_set name ()) names)

let init_requires_join_set (names : string list) =
  with_dispatch_rw (fun () ->
    List.iter (fun name -> Hashtbl.replace requires_join_set name ()) names)

let init_mcp_context_required_set (names : string list) =
  with_dispatch_rw (fun () ->
    List.iter (fun name -> Hashtbl.replace mcp_context_required_set name ()) names)

let init_destructive_set (names : string list) =
  with_dispatch_rw (fun () ->
    List.iter (fun name -> Hashtbl.replace destructive_set name ()) names)

let init_idempotent_set (names : string list) =
  with_dispatch_rw (fun () ->
    List.iter (fun name -> Hashtbl.replace idempotent_set name ()) names)

let is_read_only name = with_dispatch_ro (fun () -> Hashtbl.mem read_only_set name)
let is_join_required name = with_dispatch_ro (fun () -> Hashtbl.mem requires_join_set name)
let is_mcp_context_required name =
  with_dispatch_ro (fun () -> Hashtbl.mem mcp_context_required_set name)
let is_destructive name = with_dispatch_ro (fun () -> Hashtbl.mem destructive_set name)
let is_idempotent name = with_dispatch_ro (fun () -> Hashtbl.mem idempotent_set name)

(** {2 Module Tag Dispatch — O(1) two-level dispatch}

    Maps tool names to module tags at startup (once).
    At call time, O(1) tag lookup determines which module's context
    to create lazily. Eliminates per-call 40+ context creation and
    ~210 Hashtbl.replace ops. *)

type module_tag =
  | Mod_plan | Mod_operator | Mod_command_plane
  | Mod_local_runtime
  | Mod_worktree
  | Mod_code | Mod_code_write
  | Mod_a2a
  | Mod_run
  | Mod_compact
  | Mod_agent | Mod_task | Mod_room
  | Mod_control | Mod_agent_timeline | Mod_misc | Mod_suspend
  | Mod_library | Mod_keeper
  | Mod_inline
  | Mod_autoresearch
  | Mod_shard

let tag_registry : (string, module_tag) Hashtbl.t = Hashtbl.create 512
let tag_registry_initialized = ref false

(** Schema registry — maps tool name → input_schema JSON.
    Populated alongside tag_registry during server initialization.
    Used by Tool_input_validation pre-hook to validate arguments
    before dispatch (C-4 precondition validation). *)
let schema_registry : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 512

let register_module_tag ~(schemas : Types.tool_schema list) ~tag =
  with_dispatch_rw (fun () ->
    List.iter (fun (s : Types.tool_schema) ->
      Hashtbl.replace tag_registry s.name tag;
      Hashtbl.replace schema_registry s.name s.input_schema) schemas)

(** Register a single tool name with a tag (for modules without schema exports). *)
let register_name_tag ~tool_name ~tag =
  with_dispatch_rw (fun () -> Hashtbl.replace tag_registry tool_name tag)

let lookup_tag name = with_dispatch_ro (fun () -> Hashtbl.find_opt tag_registry name)
let lookup_schema name = with_dispatch_ro (fun () -> Hashtbl.find_opt schema_registry name)

let tag_registry_count () = with_dispatch_ro (fun () -> Hashtbl.length tag_registry)

let mark_tag_registry_initialized () = with_dispatch_rw (fun () -> tag_registry_initialized := true)
let is_tag_registry_initialized () = with_dispatch_ro (fun () -> !tag_registry_initialized)

(** Mint a [Tool_token.t] validated against both registries.
    Protected by dispatch_mu for thread safety (Copilot review).
    Checks tag_registry (primary) then handler registry (fallback).
    In production both are populated at startup; in test binaries
    only the handler registry may be populated. *)
let mint_token ~name =
  with_dispatch_ro (fun () ->
    Tool_token.mint_with
      ~validate:(fun n -> Hashtbl.mem tag_registry n || Hashtbl.mem registry n)
      ~name)

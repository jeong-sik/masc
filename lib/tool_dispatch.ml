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

(** Register a single tool name → handler mapping. *)
let register ~tool_name ~(handler : handler) =
  Hashtbl.replace registry tool_name handler

(** Bulk-register every tool name from a schema list to the same handler.
    This is the primary registration path — it extracts names from the
    module's published schemas, ensuring the registry is always in sync
    with the advertised tool list. *)
let register_module ~(schemas : Types.tool_schema list) ~(handler : handler) =
  List.iter
    (fun (schema : Types.tool_schema) ->
      Hashtbl.replace registry schema.name handler)
    schemas

(** O(1) dispatch.  Returns [Some (success, message)] when a handler is
    found, [None] when the tool name is unknown to the registry.
    Handler exceptions are caught and returned as error tuples so the
    caller gets a consistent result shape. *)
let dispatch ~name ~args : (bool * string) option =
  match Hashtbl.find_opt registry name with
  | Some handler -> (
      try handler ~name ~args
      with exn ->
        Some
          ( false,
            Printf.sprintf "dispatch_v2 handler error for %s: %s" name
              (Printexc.to_string exn) ))
  | None -> None

(** {2 Dispatch Hooks}

    Pre-hooks run before the handler; post-hooks run after.
    Multiple hooks are supported — they execute in registration order.

    - Pre-hook returning [Some result] short-circuits (handler is skipped).
      Use case: permission checks (Sprint 3), request logging.
    - Post-hook transforms the result.  Identity function when observing only.
      Use case: tracing spans (Sprint 2), metrics collection. *)

(** Pre-hook: receives tool name and args before handler runs.
    Return [None] to proceed, [Some result] to short-circuit. *)
type pre_hook = name:string -> args:Yojson.Safe.t -> Tool_result.t option

(** Post-hook: receives result after handler completes.
    Return the (possibly transformed) result. *)
type post_hook = Tool_result.t -> Tool_result.t

let pre_hooks : pre_hook list ref = ref []
let post_hooks : post_hook list ref = ref []

let register_pre_hook (hook : pre_hook) =
  pre_hooks := !pre_hooks @ [hook]

let register_post_hook (hook : post_hook) =
  post_hooks := !post_hooks @ [hook]

let clear_hooks () =
  pre_hooks := [];
  post_hooks := []

(** Run pre-hooks in order.  First [Some] wins (short-circuit). *)
let run_pre_hooks ~name ~args =
  let rec go = function
    | [] -> None
    | hook :: rest ->
      (match hook ~name ~args with
       | Some _ as result -> result
       | None -> go rest)
  in
  go !pre_hooks

(** Run post-hooks in order, threading the result through. *)
let run_post_hooks result =
  List.fold_left (fun r hook -> hook r) result !post_hooks

(** Structured dispatch with hook support.

    Execution order: pre-hooks → handler → post-hooks.

    If a pre-hook short-circuits, the handler and post-hooks are skipped
    and the pre-hook's result is returned directly.

    Returns [None] when the tool is unknown to the registry. *)
let dispatch_structured ~name ~args : Tool_result.t option =
  (* Pre-hooks: may short-circuit *)
  match run_pre_hooks ~name ~args with
  | Some _ as blocked -> blocked
  | None ->
    let start_time = Time_compat.now () in
    (match dispatch ~name ~args with
     | Some (success, message) ->
       let result = Tool_result.wrap ~tool_name:name ~start_time (success, message) in
       Some (run_post_hooks result)
     | None -> None)

(** Feature flag: use the new dispatch path. *)
let v2_enabled =
  match Sys.getenv_opt "MASC_DISPATCH_V2" with
  | Some "1" | Some "true" | Some "TRUE" -> true
  | _ -> false

(** Number of registered tool names. *)
let registered_count () = Hashtbl.length registry

(** Check whether a tool name is registered. *)
let is_registered name = Hashtbl.mem registry name

(** --- Hashtbl sets for read_only and requires_join checks --- *)

let read_only_set : (string, unit) Hashtbl.t = Hashtbl.create 32
let requires_join_set : (string, unit) Hashtbl.t = Hashtbl.create 64

let init_read_only_set (names : string list) =
  List.iter (fun name -> Hashtbl.replace read_only_set name ()) names

let init_requires_join_set (names : string list) =
  List.iter (fun name -> Hashtbl.replace requires_join_set name ()) names

let is_read_only name = Hashtbl.mem read_only_set name
let is_join_required name = Hashtbl.mem requires_join_set name

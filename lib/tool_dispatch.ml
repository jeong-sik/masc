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

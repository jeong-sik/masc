(** Tool_misc_introspection — config and tool inventory handlers.

    Extracted from {!Tool_misc} to reduce god-file size.  Contains
    read-only helper handlers for the dashboard:

    - {!handle_config} (auth config snapshot for the operator UI)
    - {!tool_inventory_json} (catalog-driven schema list)

    @since 2.187.0 — God file decomposition Phase 1.

    Internal: \[U\] (Yojson.Safe.Util alias), \[Json_util.string_opt_to_json\],
    \[bool_arg_opt\], \[int_arg_opt\] (3 local args helpers
    duplicated from Tool_misc to avoid circular deps). *)

(** {1 Types} *)

(** RFC-0189: [tool_result] aliases the typed [Tool_result.result]
    variant. *)
type tool_result = Tool_result.result

(** {1 Read-only inventory} *)

val tool_inventory_json :
  _ ->
  include_hidden:bool ->
  Yojson.Safe.t
(** [tool_inventory_json _ctx ~include_hidden]
    returns the tool catalog snapshot.

    [enabled_in_current_mode] is reported as [false] because this
    is the dashboard context (no keeper) — pinned at the contract
    seam to prevent operator dashboards from incorrectly showing
    keeper-only tools as active. *)

(** {1 Tool handlers}

    Handlers take [args : Yojson.Safe.t] (the JSON-RPC [params] object)
    and return {!tool_result}. *)

val handle_config : tool_name:string -> start_time:float -> Yojson.Safe.t -> tool_result
(** [handle_config ~tool_name ~start_time args] returns the auth-config
    snapshot filtered by [args.category] (optional string).  Read-only. *)

(** Central Tool Dispatch Registry - O(1) Hashtbl-based dispatch.

    Replaces the 40+ sequential match chain in mcp_server_eio.ml with
    a single Hashtbl lookup. Each Tool_X module registers a closure
    that captures its own context, so the dispatch layer does not need
    to know about heterogeneous context types. *)

(** Unified handler type: every tool call is [name * args -> result option].
    [None] means "this handler does not know this tool". *)
type handler = name:string -> args:Yojson.Safe.t -> (bool * string) option

(** {1 Registration} *)

val register : tool_name:string -> handler:handler -> unit
(** Register a single tool name to handler mapping. *)

val register_module : schemas:Types.tool_schema list -> handler:handler -> unit
(** Bulk-register every tool name from a schema list to the same handler. *)

(** {1 Dispatch} *)

val dispatch : name:string -> args:Yojson.Safe.t -> (bool * string) option
(** O(1) dispatch. Returns [Some (success, message)] when a handler is
    found, [None] when the tool name is unknown to the registry. *)

(** {2 Dispatch Hooks}

    Pre-hooks run before the handler; post-hooks run after. *)

type pre_hook = name:string -> args:Yojson.Safe.t -> Tool_result.t option
(** Pre-hook: receives tool name and args before handler runs.
    Return [None] to proceed, [Some result] to short-circuit. *)

type post_hook = Tool_result.t -> Tool_result.t
(** Post-hook: receives result after handler completes.
    Return the (possibly transformed) result. *)

val pre_hooks : pre_hook list ref
(** Mutable list of registered pre-hooks. *)

val post_hooks : post_hook list ref
(** Mutable list of registered post-hooks. *)

val register_pre_hook : pre_hook -> unit
val register_post_hook : post_hook -> unit
val clear_hooks : unit -> unit

val dispatch_structured : name:string -> args:Yojson.Safe.t -> Tool_result.t option
(** Structured dispatch with hook support.
    Execution order: pre-hooks -> handler -> post-hooks. *)

(** {1 Feature Flag and Introspection} *)

val v2_enabled : bool
(** Feature flag: use the new dispatch path (default ON since v2.102). *)

val registered_count : unit -> int
(** Number of registered tool names. *)

val is_registered : string -> bool
(** Check whether a tool name is registered. *)

(** {1 Read-only and Join-required Sets} *)

val init_read_only_set : string list -> unit
val init_requires_join_set : string list -> unit
val is_read_only : string -> bool
val is_join_required : string -> bool

(** {2 Module Tag Dispatch - O(1) two-level dispatch}

    Maps tool names to module tags at startup (once).
    At call time, O(1) tag lookup determines which module's context
    to create lazily. *)

type module_tag =
  | Mod_plan | Mod_run | Mod_operator | Mod_command_plane
  | Mod_local_runtime | Mod_team_session | Mod_voice | Mod_cache
  | Mod_tempo | Mod_mitosis | Mod_portal | Mod_worktree
  | Mod_code_swarm | Mod_code | Mod_code_write | Mod_vote | Mod_social
  | Mod_council | Mod_a2a | Mod_handover
  | Mod_relay | Mod_goals | Mod_heartbeat | Mod_encryption
  | Mod_auth | Mod_hat | Mod_audit | Mod_rate_limit
  | Mod_cost | Mod_walph | Mod_agent | Mod_task | Mod_room
  | Mod_control | Mod_agent_timeline | Mod_misc | Mod_suspend
  | Mod_library | Mod_keeper | Mod_compact | Mod_mdal
  | Mod_notifications | Mod_inline
  | Mod_autoresearch
  | Mod_model_catalog
  | Mod_shard

val register_module_tag : schemas:Types.tool_schema list -> tag:module_tag -> unit
(** Register tool names from a schema list with a module tag. *)

val register_name_tag : tool_name:string -> tag:module_tag -> unit
(** Register a single tool name with a tag. *)

val lookup_tag : string -> module_tag option
(** Look up the module tag for a tool name. *)

val tag_registry_count : unit -> int
(** Number of entries in the tag registry. *)

val mark_tag_registry_initialized : unit -> unit
val is_tag_registry_initialized : unit -> bool

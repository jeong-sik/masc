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

val dispatch : token:Tool_token.t -> args:Yojson.Safe.t -> (bool * string) option
(** O(1) dispatch using a validated token. Returns [Some (success, message)]
    when a handler is found, [None] when the tool name is unknown.
    The token guarantees the name was validated at the I/O boundary. *)

val mint_token : name:string -> (Tool_token.t, string) result
(** Mint a [Tool_token.t] validated against both tag and handler registries.
    Thread-safe (protected by dispatch_mu). *)

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

val run_pre_hooks : name:string -> args:Yojson.Safe.t -> Tool_result.t option
(** Execute registered pre-hooks in order.
    Returns the first short-circuit result, if any. *)

val dispatch_structured : token:Tool_token.t -> args:Yojson.Safe.t -> Tool_result.t option
(** Structured dispatch with hook support.
    Execution order: pre-hooks -> handler -> post-hooks.
    Requires a validated [Tool_token.t]. *)

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
val init_mcp_context_required_set : string list -> unit
val is_read_only : string -> bool
val is_join_required : string -> bool
val is_mcp_context_required : string -> bool

(** {2 Module Tag Dispatch - O(1) two-level dispatch}

    Maps tool names to module tags at startup (once).
    At call time, O(1) tag lookup determines which module's context
    to create lazily. *)

type module_tag =
  | Mod_plan | Mod_operator | Mod_command_plane
  | Mod_local_runtime | Mod_team_session | Mod_voice
  | Mod_portal | Mod_worktree
  | Mod_code | Mod_code_write
  | Mod_a2a | Mod_handover
  | Mod_relay | Mod_heartbeat
  | Mod_auth | Mod_audit | Mod_cost | Mod_encryption | Mod_fire_task
  | Mod_hat | Mod_cache | Mod_model_catalog | Mod_rate_limit | Mod_run
  | Mod_tempo | Mod_goals | Mod_compact
  | Mod_agent | Mod_task | Mod_room
  | Mod_control | Mod_agent_timeline | Mod_misc | Mod_suspend
  | Mod_library | Mod_keeper | Mod_repair_loop
  | Mod_inline
  | Mod_improve_loop
  | Mod_autoresearch
  | Mod_research
  | Mod_shard

val register_module_tag : schemas:Types.tool_schema list -> tag:module_tag -> unit
(** Register tool names from a schema list with a module tag. *)

val register_name_tag : tool_name:string -> tag:module_tag -> unit
(** Register a single tool name with a tag. *)

val lookup_tag : string -> module_tag option
(** Look up the module tag for a tool name. *)

val lookup_schema : string -> Yojson.Safe.t option
(** Look up the input_schema JSON for a tool name.
    Used by Tool_input_validation pre-hook for argument validation. *)

val tag_registry_count : unit -> int
(** Number of entries in the tag registry. *)

val mark_tag_registry_initialized : unit -> unit
val is_tag_registry_initialized : unit -> bool

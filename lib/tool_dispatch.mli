
(** Central Tool Dispatch Registry.

    Production MCP tool names route through {!Tool_name} and an exhaustive
    module-tag match. Mutable registries remain for direct-handler
    compatibility, schemas, and test/dynamic tools. *)

(** Unified handler type: every tool call is [name * args -> tool_result option].
    [None] means "this handler does not know this tool". *)
type handler = name:string -> args:Yojson.Safe.t -> Tool_result.t option

(** {1 Registration} *)

val register : tool_name:string -> handler:handler -> unit
(** Register a single tool name to handler mapping. *)

val register_module : schemas:Masc_domain.tool_schema list -> handler:handler -> unit
(** Bulk-register every tool name from a schema list to the same handler. *)

(** {1 Dispatch} *)

(* RFC-0084 PR-11 — [val dispatch] removed from the public mli surface.
   External callers MUST use [guarded_dispatch] (see below) which wraps
   the same handler-registry path with [Tool_telemetry.with_span] and
   the pre-hook chain. [dispatch] remains in [tool_dispatch.ml] as a
   private implementation detail used by [guarded_dispatch] internally;
   PR-14 lint asserts the public surface has zero callers of [dispatch]
   in [lib/] and [bin/]. *)

val mint_token : name:string -> (Tool_token.t, string) Result.t
(** Mint a [Tool_token.t] validated against both tag and handler registries.
    Thread-safe (protected by dispatch_mu). *)

(** {2 Dispatch Hooks}

    Pre-hooks run before the handler; post-hooks run after.

    Pre-hooks return a {!pre_hook_action}:
    - [Pass]: this hook has no opinion — continue to next hook.
    - [Proceed coerced_args]: replace args and continue (e.g. type coercion).
    - [Reject result]: short-circuit with an error result. *)

type pre_hook_action =
  | Pass
  | Proceed of Yojson.Safe.t
  | Reject of Tool_result.t

type pre_hook = name:string -> args:Yojson.Safe.t -> pre_hook_action
(** Pre-hook: receives tool name and args before handler runs. *)

type post_hook = Tool_result.t -> Tool_result.t
(** Post-hook: receives result after handler completes.
    Return the (possibly transformed) tool result. *)

val pre_hooks : pre_hook list ref
(** Mutable list of registered pre-hooks. *)

val post_hooks : post_hook list ref
(** Mutable list of registered post-hooks. *)

val register_pre_hook : pre_hook -> unit
val register_post_hook : post_hook -> unit
val clear_hooks : unit -> unit

val run_pre_hooks :
  name:string -> args:Yojson.Safe.t -> Tool_result.t option * Yojson.Safe.t
(** Execute registered pre-hooks in order, threading coerced args.
    Returns [(Some rejection, _)] on short-circuit,
    or [(None, final_args)] when all hooks pass. *)

val run_post_hooks : Tool_result.t -> Tool_result.t
(** Execute registered post-hooks in order, threading the result.
    Used by keeper dispatch to feed metrics/usage hooks for tools
    that bypass [dispatch]. *)

(* RFC-0084 PR-11 — [val dispatch_structured] removed from the public mli
   surface. PR-7~9 migration verified external callers = 0 (rg in lib/ +
   bin/). [dispatch_structured] remains in [tool_dispatch.ml] as a
   private implementation detail invoked exclusively by
   [guarded_dispatch] to run the pre-hook chain. *)

val guarded_dispatch
  :  token:Tool_token.t
  -> args:Yojson.Safe.t
  -> unit
  -> Tool_result.t option
(** RFC-0084 §2.2 — Single dispatch entry with 4-tuple telemetry.

    Wraps [dispatch] with [Tool_telemetry.with_span], so every
    invocation emits an OTel span, a Prometheus counter increment, and a
    [trace_id] thunk available to the handler. The audit emission slot is
    filled by callers based on the returned [Tool_result.t option]; PR-10
    will unify audit emission via a typed [Dispatch_outcome.t].

    PR-3 introduces this entry. No callers migrate in this PR. Migration
    plan: PR-7 keeper turn, PR-8 MCP server, PR-9 tag-dispatch fallback.
    PR-11 removes [dispatch] and [dispatch_structured] in favour of this
    single path. *)

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
val init_destructive_set : string list -> unit
val init_idempotent_set : string list -> unit
val is_read_only : string -> bool
val is_join_required : string -> bool
val is_mcp_context_required : string -> bool
val is_destructive : string -> bool
val is_idempotent : string -> bool

(** {2 Module Tag Dispatch}

    Known tool names map to module tags through a compile-time match.
    Runtime registrations remain as a fallback for test/dynamic tools. *)

type module_tag =
  | Mod_plan | Mod_operator
  | Mod_local_runtime
  | Mod_worktree
  | Mod_code | Mod_code_write
  | Mod_run
  | Mod_compact
  | Mod_agent | Mod_task | Mod_room
  | Mod_control | Mod_agent_timeline | Mod_misc | Mod_suspend
  | Mod_library | Mod_keeper
  | Mod_inline
  | Mod_autoresearch
  | Mod_shard

val register_module_tag : schemas:Masc_domain.tool_schema list -> tag:module_tag -> unit
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

(** {1 Did-you-mean Suggestions (#9784)} *)

val all_registered_names : unit -> string list
(** Every tool name registered in either the tag_registry or the
    handler registry, deduplicated. Iteration order is unspecified. *)

val find_similar_names :
  ?limit:int -> ?min_score:float -> query:string -> unit -> string list
(** Return up to [limit] (default 3) tool names from the registries with
    [Text_similarity.jaccard_similarity] to [query] >= [min_score]
    (default 0.4), sorted by similarity descending. Used to enrich
    Unknown tool errors with self-correction hints for LLM clients. *)


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

(* RFC-0084 PR-11/14 — [dispatch] and [dispatch_structured] were removed from
   the public surface and the file-private chain. External callers MUST use
   [guarded_dispatch], which owns telemetry, pre-hooks, handler execution,
   result transformation, and typed post-hook fan-out. *)

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

(* RFC-0084 PR-I-3 — [type post_hook] removed.  All 5 in-tree
   register_post_hook callers migrated to [register_typed_post_hook]
   (observer) or [set_result_transformer] (transformer) by
   PR-I-2.a..e. *)

type post_hook_typed =
  Dispatch_outcome.t -> Tool_result.t option -> unit
(** Typed post-hook (RFC-0084 PR-I-1).

    Receives the typed {!Dispatch_outcome.t} together with the
    handler-produced {!Tool_result.t} (when the [Handled] arm ran)
    once dispatch completes — regardless of which arm fired
    ([Handled] / [Rejected_by_capability] / [Rejected_by_pre_hook] /
    [No_handler] / [Handler_error]).

    The optional [Tool_result.t] is [Some _] only on the [Handled]
    arm; other arms receive [None].  Observer-only ([unit] return) —
    cannot mutate the outcome.

    PR-I-1 introduces the surface with zero in-tree registrations;
    PR-I-2.* migrates the existing 5 [register_post_hook] call-sites
    one at a time, each preserving its current observation semantics. *)

val pre_hooks : pre_hook list ref
(** Mutable list of registered pre-hooks. *)

(* RFC-0084 PR-I-3 — the legacy post-hooks ref and registration
   entry are gone alongside [type post_hook]. *)

val typed_post_hooks : post_hook_typed list ref
(** Mutable list of registered typed post-hooks (RFC-0084 PR-I-1). *)

val register_pre_hook : pre_hook -> unit

val register_typed_post_hook : post_hook_typed -> unit
(** Register a typed post-hook (RFC-0084 PR-I-1).  See
    {!post_hook_typed} for the contract. *)

(** {2 Result transformer (RFC-0084 PR-I-2.d)} *)

type result_transformer = Tool_result.t -> Tool_result.t
(** Single-step transformer applied to the handler's
    {!Tool_result.t} on the [Handled] arm, before legacy post-hooks
    fire.  Carries the *transformation* responsibility (e.g. output
    capping) that the legacy [post_hook] surface used to mix with
    observation. *)

val set_result_transformer : result_transformer -> unit
(** Install the single result transformer.  Today's only in-tree
    caller is {!Tool_output_validation.install}; PR-I-2.d wires it
    through this surface so PR-I-3 can remove [post_hook] without
    losing the cap. *)

val apply_result_transformer : Tool_result.t -> Tool_result.t
(** Apply the registered transformer (identity when none registered). *)

val clear_hooks : unit -> unit
(** Reset pre/post/typed hooks and the result transformer. *)

val run_pre_hooks :
  name:string -> args:Yojson.Safe.t -> Tool_result.t option * Yojson.Safe.t
(** Execute registered pre-hooks in order, threading coerced args.
    Returns [(Some rejection, _)] on short-circuit,
    or [(None, final_args)] when all hooks pass. *)

(* RFC-0084 PR-I-3 — [val run_post_hooks] removed.  Dispatch loop
   now applies [apply_result_transformer] (transformation) inside
   [dispatch], and [run_typed_post_hooks] (observation) from
   [guarded_dispatch] for every outcome arm. *)

val run_typed_post_hooks :
  Dispatch_outcome.t -> Tool_result.t option -> unit
(** Execute registered typed post-hooks against the typed outcome
    (RFC-0084 PR-I-1).  Invoked from [guarded_dispatch] for every
    arm with the optional handler {!Tool_result.t} ([Some _] on the
    [Handled] arm, [None] otherwise).  Sole observer-side dispatch
    seam after PR-I-3 retired the legacy [run_post_hooks]. *)

val guarded_dispatch
  :  token:Tool_token.t
  -> args:Yojson.Safe.t
  -> unit
  -> Tool_result.t option
(** RFC-0084 §2.2 — Single dispatch entry with 4-label telemetry.

    Owns [Tool_telemetry.with_span], the pre-hook chain, handler lookup,
    exception capture, result transformation, and typed post-hook fan-out.
    The dispatch return is typed [Tool_result.t option]; the old
    [dispatch]/[dispatch_structured] entry points are gone. *)

(** {1 Introspection} *)

(* RFC-0084 host-config-cleanup-J — [val v2_enabled] removed.
   The [MASC_DISPATCH_V2] feature flag (default ON since v2.102)
   and the legacy match chain it gated are gone; the Hashtbl
   dispatch path is the only path. *)

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

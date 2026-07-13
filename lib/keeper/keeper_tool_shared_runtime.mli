(** Agent tool shared runtime — error envelopes, sandbox path projection,
    and dispatch hooks shared by agent tool runtime modules. *)

module StringMap : Map.S with type key = string

(** Total token count of a working context, delegating to
    [Keeper_context_runtime.token_count]. *)
val count_context_tokens : Keeper_types.working_context -> int

(** Render an error JSON envelope: [{"error": <message>; ...fields}]. *)
val error_json : ?fields:(string * Yojson.Safe.t) list -> string -> string

(** Render a failed [Tool_result.result] as [error_json], preserving
    [failure_class] for keeper-facing routing and diagnostics. *)
val tool_result_error_json : Tool_result.result -> string

(** [Tool_result.result] passes [msg] through on success; wraps it
    in [error_json] on failure. *)
val tool_result_or_error : Tool_result.result -> string

val file_not_found_prefix : string

(** Render a missing-file JSON envelope with the error, path, and
    path-resolution guidance.
    #10349: directory entries are intentionally excluded to prevent
    sandbox oracle leaks when keeper identity drifts. *)
val missing_file_error_json
  :  raw_path:string option
  -> cwd:string option
  -> target:string
  -> error:string
  -> string

(** Replace the [`Assoc] field [key] with [`String value], moving
    it to the front. Non-assoc values pass through unchanged. *)
val assoc_override_string : string -> string -> Yojson.Safe.t -> Yojson.Safe.t

(** Re-export of [Keeper_alerting_path.effective_allowed_paths]. *)
val keeper_effective_allowed_paths : meta:Keeper_meta_contract.keeper_meta -> string list

(** Re-export of [Keeper_alerting_path.effective_write_allowed_paths]. *)
val keeper_effective_write_allowed_paths : meta:Keeper_meta_contract.keeper_meta -> string list

(** Sandbox playground root for [meta]; ensures the bundle dirs
    exist as a side effect. *)
val keeper_playground_root
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> string

val keeper_default_write_root
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> string

val keeper_default_read_root
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> string

(** [keeper_observation_sandbox_root ~config ~meta] is the keeper's
    playground sandbox root anchored at the normalised project root.
    Pure path computation for the observation write path — unlike
    {!keeper_default_read_root} it never creates the sandbox bundle. *)
val keeper_observation_sandbox_root
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> string

(** [keeper_observation_host_path_of_visible_path ~config ~meta path] maps a
    Docker keeper's sandbox-visible absolute path to the corresponding host
    playground path without creating the sandbox bundle. Local keepers, relative
    paths, and unrelated absolute paths are returned unchanged. *)
val keeper_observation_host_path_of_visible_path
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> string
  -> string

val safe_file_exists : string -> bool
val safe_is_dir : string -> bool

(** Resolve a write target without path rewriting, using objective allowed-root
    containment via [Keeper_alerting_path.resolve_keeper_target_path]. *)
val resolve_keeper_path
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> raw_path:string
  -> (string, string) result

(** Resolve a read target without path rewriting or existence inference. *)
val resolve_keeper_read_path
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> raw_path:string
  -> (string, string) result

(** Resolve an already projected host path that came from a
    Keeper-visible [cwd] + relative [file_path] composition. [raw_for_error]
    is the model-facing path to keep diagnostics in the visible namespace. *)
val resolve_projected_keeper_read_path
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> raw_for_error:string
  -> projected_path:string
  -> (string, string) result

val keeper_agent_sender : meta:Keeper_meta_contract.keeper_meta -> string

(** Clamp [args.limit] to [1..200] (default 40) for read-only
    shell commands. *)
val shell_readonly_limit : Yojson.Safe.t -> int

(** Clamp [args.max_bytes] to [256..100000] (default 4000) for
    the structured [cat] read operation. *)
val shell_readonly_cat_max_bytes : Yojson.Safe.t -> int

(** Project [text] to a JSON array of lines, capped by [limit]
    lines and [max_bytes] total payload. The omitted-tail line
    surfaces a hint for the LLM to narrow its search. *)
val lines_to_json : ?limit:int -> ?max_bytes:int -> string -> Yojson.Safe.t

(** Build the [text_fallback] response for a voice agent that
    chose to emit text instead of audio. *)
val keeper_text_fallback_json : agent_id:string -> message:string -> Yojson.Safe.t

(** Hook used by the tool dispatcher to dispatch into module-tagged
    sub-handlers. Default is a no-op fallback. *)
val tag_dispatch_fn
  : (config:Workspace.config
     -> agent_name:string
     -> tag:Tool_dispatch.module_tag
     -> name:string
     -> args:Yojson.Safe.t
     -> Tool_result.result option)
      ref

(** Issue #10349 Phase 2: registry-canonical meta lookup.
    [find_registry_meta] does the lookup + drift-counter increment and
    returns [None] on missing entry.  Callers that need to return a
    different type on error (e.g. [string option]) use this directly.
    [with_registry_meta] is the convenience wrapper for the common
    [string]-returning case; its [None] branch calls [error_json].
    [source_layer] is the Otel_metric_store label value (e.g. ["fs_resolver"],
    ["masc_path_resolver"], ["tool_dispatcher"]). *)
val find_registry_meta
  :  keeper_name:string
  -> source_layer:string
  -> Keeper_meta_contract.keeper_meta option

val with_registry_meta
  :  keeper_name:string
  -> source_layer:string
  -> (Keeper_meta_contract.keeper_meta -> string)
  -> string

(** Render the keeper-tools-list JSON envelope: tool names grouped
    by category plus descriptor_surface metadata for executor/policy/schema
    discovery. *)
val keeper_tools_list_json : meta:Keeper_meta_contract.keeper_meta -> string

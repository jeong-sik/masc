(** Keeper exec shared — error envelopes, sandbox path projection,
    and tool dispatch hooks shared by every keeper exec module. *)

module StringMap : Map.S with type key = string

(** Total token count of a working context, delegating to
    [Keeper_exec_context.token_count]. *)
val count_context_tokens : Keeper_types.working_context -> int

(** Render an error JSON envelope: [{"error": <message>; ...fields}]. *)
val error_json :
  ?fields:(string * Yojson.Safe.t) list -> string -> string

(** [Tool_result.t] passes [msg] through on success; wraps it
    in [error_json] on failure. *)
val tool_result_or_error : Tool_result.t -> string

(** Phase B PR-5 precursor: typed dispatch from the path error
    class to a concrete remediation hint. *)
val actionable_path_action_for_class :
  playground:string ->
  raw_path:string ->
  Keeper_failure_circuit_breaker.error_class ->
  string

(** Render the canonical path-rejection JSON envelope: classifies
    [error] via [Keeper_failure_circuit_breaker.classify_error]
    and routes to [actionable_path_action_for_class]. *)
val actionable_path_error :
  op:string ->
  meta:Keeper_types.keeper_meta ->
  raw_path:string ->
  error:string ->
  string

val max_suggested_entries : int
val file_not_found_prefix : string

(** Render a missing-file JSON envelope with up-to-12 sibling
    suggestions sourced from the closest existing parent. *)
val missing_file_error_json :
  config:Coord.config ->
  target:string ->
  fallback_dir:string ->
  error:string ->
  string

(** Lowercase + collapse whitespace + split on space + drop blanks. *)
val lowercase_shell_words : string -> string list

(** Replace the [`Assoc] field [key] with [`String value], moving
    it to the front. Non-assoc values pass through unchanged. *)
val assoc_override_string :
  string -> string -> Yojson.Safe.t -> Yojson.Safe.t

(** Re-export of [Keeper_alerting_path.effective_allowed_paths]. *)
val keeper_effective_allowed_paths :
  meta:Keeper_types.keeper_meta -> string list

(** Re-export of [Keeper_alerting_path.effective_write_allowed_paths]. *)
val keeper_effective_write_allowed_paths :
  meta:Keeper_types.keeper_meta -> string list

(** Sandbox playground root for [meta]; ensures the bundle dirs
    exist as a side effect. *)
val keeper_playground_root :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> string

val keeper_default_write_root :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> string

val keeper_default_read_root :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> string

val safe_file_exists : string -> bool
val safe_is_dir : string -> bool

(** Names of git-clone subdirectories under the keeper sandbox
    [repos/] lane. *)
val keeper_sandbox_repo_names :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> string list

(** [true] iff [raw] is a relative path that lies under one of the
    keeper's relative allowed_paths roots. *)
val relative_path_targets_allowed_root :
  meta:Keeper_types.keeper_meta -> string -> bool

(** [true] iff [raw] starts with [mind] or [repos] (the canonical
    sandbox lanes for keeper-relative paths). *)
val is_playground_lane_relative_path : string -> bool

(** Strip the keeper's legacy / sandbox playground prefix from
    [raw] when present, returning the rest (or ["."] for an empty
    rest). [None] otherwise. *)
val strip_keeper_playground_prefix :
  meta:Keeper_types.keeper_meta -> string -> string option

(** [true] iff [raw] is a relative path whose first segment looks
    like a repo name (not a sandbox lane / project root marker). *)
val repo_relative_path_candidate :
  meta:Keeper_types.keeper_meta -> string -> bool

(** Rewrite a repo-relative path to its sandbox-clone absolute
    form. Returns [Ok None] when no rewrite applies, [Ok (Some _)]
    on a successful rewrite, [Error _] on ambiguity. *)
val rewrite_single_repo_relative_path :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  string ->
  (string option, string) result

(** Default-route a relative path under the keeper's playground
    unless it already targets an explicit allowed_paths root.
    Strips legacy/doubled playground prefixes, applies single-repo
    rewrite, then resolves. *)
val playground_relative_unless_allowed_root :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  string ->
  (string, string) result

(** Resolve a write target path: playground default + sandbox
    boundary check via [Keeper_alerting_path.resolve_keeper_target_path]. *)
val resolve_keeper_path :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  raw_path:string ->
  (string, string) result

(** Resolve a read target path: playground default + sandbox
    boundary check via [Keeper_alerting_path.resolve_keeper_read_path]
    (with missing-leaf fallback search). *)
val resolve_keeper_read_path :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  raw_path:string ->
  (string, string) result

val keeper_agent_sender : meta:Keeper_types.keeper_meta -> string

(** Clamp [args.limit] to [1..200] (default 40) for read-only
    shell commands. *)
val shell_readonly_limit : Yojson.Safe.t -> int

(** Clamp [args.max_bytes] to [256..100000] (default 4000) for
    [keeper_shell op=cat]. *)
val shell_readonly_cat_max_bytes : Yojson.Safe.t -> int

(** Project [text] to a JSON array of lines, capped by [limit]
    lines and [max_bytes] total payload. The omitted-tail line
    surfaces a hint for the LLM to narrow its search. *)
val lines_to_json :
  ?limit:int -> ?max_bytes:int -> string -> Yojson.Safe.t

(** Build the [text_fallback] response for a voice agent that
    chose to emit text instead of audio. *)
val keeper_text_fallback_json :
  agent_id:string -> message:string -> Yojson.Safe.t

(** Hook used by [Keeper_exec_tools] to dispatch into module-tagged
    sub-handlers. Default is a no-op fallback. *)
val tag_dispatch_fn :
  (config:Coord.config ->
   agent_name:string ->
   tag:Tool_dispatch.module_tag ->
   name:string ->
   args:Yojson.Safe.t ->
   (bool * string) option)
  ref

(** Render the keeper-tools-list JSON envelope: tool names grouped
    by category (board / voice / coordination / shell / fs / memory
    / core). *)
val keeper_tools_list_json :
  meta:Keeper_types.keeper_meta -> string

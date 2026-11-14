(** Agent tool shared runtime — error envelopes, sandbox path projection,
    and dispatch hooks shared by agent tool runtime modules. *)

module StringMap : Map.S with type key = string

(** Render an error JSON envelope: [{"error": <message>; ...fields}]. *)
val error_json : ?fields:(string * Yojson.Safe.t) list -> string -> string

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

(** [keeper_observation_sandbox_root ~config ~meta] is the keeper's
    playground sandbox root anchored at the normalised project root.
    Pure path computation for the observation write path — unlike
    [keeper_playground_root] it never creates the sandbox bundle. *)
val keeper_observation_sandbox_root
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> string

(** [keeper_observation_host_path_of_visible_path ~config ~meta path] maps a
    Docker keeper's sandbox-visible absolute path to the corresponding host
    playground path without creating the sandbox bundle. Keepers whose profile
    is not Docker, relative paths, and unrelated absolute paths are returned
    unchanged. *)
val keeper_observation_host_path_of_visible_path
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> string
  -> string

val safe_file_exists : string -> bool
val safe_is_dir : string -> bool

(** Whether a resolved cwd exists, asked of the filesystem that holds the
    Keeper's tree (RFC-0427 A-1). [Endpoint_decides] for a tree the endpoint
    owns: the host path is bookkeeping, so the host is not asked and the
    endpoint reports a missing directory when the tool runs there. The other
    three are the host's answer for a shared-mount tree. The Keeper cwd
    resolvers of Execute, Read and the search tools ask here; the verifier's
    owned-root Read checks its own host root. *)
type cwd_existence =
  | Endpoint_decides
  | Host_directory
  | Host_missing
  | Host_file

val cwd_existence : meta:Keeper_meta_contract.keeper_meta -> string -> cwd_existence

(** HIGH-RISK-UNREVIEWED: sandbox path boundary, needs human review.

    [host_path_of_keeper_visible_path ~config ~meta ?host_cwd path] is the
    single owner of turning a path a Keeper names into a host path (#29964).
    Every Keeper tool that takes a path or a cwd resolves it here, so one
    spelling names one host location whichever tool receives it.

    - A Docker Keeper's container-visible absolute path maps to its host
      mount; any other absolute path keeps its identity.
    - A relative path joins [host_cwd] (a host directory this function
      already returned) when given, and the Keeper's playground root
      otherwise.
    - [None] when [path] is blank: the caller named nothing.

    The result is not confined. Pass it to a resolver below, or to
    {!resolve_keeper_execute_cwd_typed}, before any use. Nothing is created on
    disk. *)
val host_path_of_keeper_visible_path
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> ?host_cwd:string
  -> string
  -> string option

(** Resolve a Keeper-visible write path through
    {!host_path_of_keeper_visible_path} and return the opaque allowed-root
    capability locator, or the typed refusal of the allowed-root check. *)
val resolve_keeper_confined_write_path
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> endpoint:Keeper_alerting_path.confined_path_endpoint
  -> raw_path:string
  -> (Keeper_alerting_path.confined_path, Keeper_alerting_path.path_refusal) result

(** Resolve a read target, or a read/search [cwd], using the same namespace as
    {!resolve_keeper_confined_write_path}, without existence inference. *)
val resolve_keeper_read_path
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> raw_path:string
  -> (string, Keeper_alerting_path.path_refusal) result

(** {!resolve_keeper_read_path} for a path given together with a cwd.
    [host_cwd] is the host directory {!resolve_keeper_read_path} returned for
    that cwd; a relative [raw_path] reads against it and an absolute one
    ignores it. A refusal names [raw_path], the path the model asked for. *)
val resolve_keeper_read_path_in_cwd
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> host_cwd:string
  -> raw_path:string
  -> (string, Keeper_alerting_path.path_refusal) result

(** Confine a concrete host cwd for the execute/write boundary. The caller has
    already mapped the Keeper's cwd with {!host_path_of_keeper_visible_path}.
    The successful result retains the resolver's opaque root-capability
    witness until the caller verifies it against an Eio directory handle. *)
val resolve_keeper_execute_cwd_typed
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> raw_path:string
  -> (Keeper_alerting_path.confined_path, Keeper_path_rejection.keeper_path_rejection) result

val verify_keeper_confined_root :
  Keeper_alerting_path.confined_path -> (unit, string) result
(** Verify the immutable root identity captured by the path resolver against
    the Eio directory capability that will be used by the caller. *)

val keeper_agent_sender : meta:Keeper_meta_contract.keeper_meta -> string

(** Clamp [args.limit] to [1..200] (default 40) for read-only
    shell commands. *)
val shell_readonly_limit : Yojson.Safe.t -> int

(** Total payload [lines_to_json] keeps by default, and the size an
    [rg] error text is cut to. *)
val search_result_max_bytes : int

(** [cut_to_bytes ~max_bytes text] is [text] when it fits. Otherwise it is
    the longest prefix of at most [max_bytes] bytes that ends on a UTF-8
    boundary, followed by [...[cut: K of N bytes kept]] with the kept and
    original sizes. *)
val cut_to_bytes : max_bytes:int -> string -> string

(** Project [text] to a JSON array of lines, capped by [limit]
    lines and [max_bytes] total payload. The omitted-tail line
    surfaces a hint for the LLM to narrow its search.

    A line longer than [max_line_bytes] (default 2,000, never above
    [max_bytes]) goes through {!cut_to_bytes}. One line therefore adds at
    most [max_line_bytes] plus the cut note, instead of its whole length. *)
val lines_to_json
  :  ?limit:int
  -> ?max_bytes:int
  -> ?max_line_bytes:int
  -> string
  -> Yojson.Safe.t

(** Build the [text_fallback] response for a voice agent that
    chose to emit text instead of audio. *)
val keeper_text_fallback_json : agent_id:string -> message:string -> Yojson.Safe.t

(** Hook used by the tool dispatcher to dispatch into module-tagged
    sub-handlers. Default is a no-op fallback. *)
val tag_dispatch_fn
  : (config:Workspace.config
     -> keeper_name:string
     -> agent_name:string
     -> tag:Tool_dispatch.module_tag
     -> name:string
     -> args:Yojson.Safe.t
     -> Tool_result.result option)
      ref

(** Issue #10349 Phase 2: registry-canonical meta lookup.
    [find_registry_meta] does the lookup + drift-counter increment and
    returns [None] on missing entry.
    [source_layer] is the Otel_metric_store label value (e.g. ["fs_resolver"],
    ["masc_path_resolver"], ["tool_dispatcher"]). *)
val find_registry_meta
  :  keeper_name:string
  -> source_layer:string
  -> Keeper_meta_contract.keeper_meta option

(** Render the keeper-tools-list JSON envelope: tool names grouped
    by category plus descriptor_surface metadata for executor/policy/schema
    discovery. *)
val keeper_tools_list_json : meta:Keeper_meta_contract.keeper_meta -> string

val keeper_tools_list_json_for_surface
  :  capability_surface:Keeper_capability_surface.t
  -> string
(** Render the complete Tool and Skill inventory frozen for one real Keeper
    turn. Unlike the compatibility projection above, this function never
    reads Keeper metadata or either catalog again. *)

val keeper_capability_search_json_for_surface
  :  capability_surface:Keeper_capability_surface.t
  -> query:Keeper_capability_search.query
  -> (Yojson.Safe.t, Keeper_capability_search.error) result
(** Search the complete typed Tool and Skill inventory frozen for one turn.
    Literal phrases and explicit FTS5 expressions share the same SQLite
    tokenizer and ranking. Search does not load or invoke candidates. *)

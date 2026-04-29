(** Tool_code — Code navigation MCP tools (search, symbols, read).

    Phase-1 surface: ripgrep-backed search + ctags-style symbol
    listing + size-and-binary-gated file reads.  Used by
    [masc_code_search] / [masc_code_symbols] / [masc_code_read].

    Security model (pinned at module level):

    - {b Git root validation}: every operation must resolve a
      canonical path inside the repository's git root via
      {!validate_path}.
    - {b File size limit}: reads reject files above
      {!max_file_size} (= 500 KiB).
    - {b Binary detection}: reads reject files whose extension
      matches {!is_binary_file} (.so, .wasm, .jpg, etc.).
    - {b Path traversal prevention}: [normalize_path] +
      [Unix.realpath] block .. traversal AND symlinks pointing
      outside the agent's playground bundle.

    Internal: 5 helpers stay private — \[binary_extensions]
    (the canonical block list backing {!is_binary_file}),
    \[handle_code_search] / \[handle_code_symbols] /
    \[handle_code_read] (dispatch handlers reachable only via
    {!dispatch}), and the side-effect [Tool_spec.register]
    block at module load. *)

(** {1 Tool result + context} *)

type context = {
  config : Coord.config;
  agent_name : string;
}
(** Per-call context.  Concrete record because callers
    construct it field-by-field at the dispatch site. *)

type tool_result = bool * string

(** {1 Security primitives} *)

val is_binary_file : string -> bool
(** [is_binary_file path] is [true] iff [path] ends with one of
    the pinned binary extensions (.so, .a, .lib, .dll, .dylib,
    .wasm, .o, .obj, .jpg, .jpeg, .png, .gif, .bmp, .ico, .webp,
    .mp3, .mp4, .avi, .mov, .wav, .flac, .zip, .tar, .gz, .bz2,
    .xz, .7z, .pdf, .doc, .docx, .xls, .xlsx, .ppt, .pptx).  Drift
    in this list = silent regression in the binary block — pinned
    in the implementation, mirror in this docstring. *)

val max_file_size : int
(** [max_file_size = 500 * 1024] (= 500 KiB).  Read operations
    reject files above this cap.  Pinned literal — drift would
    silently change tooling memory behaviour and break the
    "tooling is bounded" contract for keepers. *)

(** {1 Path normalization + validation} *)

val normalize_path : string -> string
(** [normalize_path path] resolves [.] / [..] segments via
    string-level traversal.  Does NOT follow symlinks — for
    symlink-aware containment checks use {!validate_read_path}.
    Returns an absolute path when [path] starts with [/],
    otherwise relative. *)

val normalize_agent_relative_path :
  config:Coord.config ->
  agent_name:string ->
  string ->
  string
(** [normalize_agent_relative_path ~config ~agent_name raw_path]
    translates between three path forms:

    + Container-side absolute paths
      ([/home/keeper/playground/<keeper>/<rest>]) are rewritten
      to host-side ([<base_path>/.masc/playground/docker/<keeper>/<rest>]).
    + Bundle-relative paths ([.masc/playground/.../<rest>]) are
      stripped to [<rest>] when redundant.
    + Doubled-prefix paths (host bundle absolute + own_bundle_rel
      again) are collapsed.
    + Playground-lane relative paths ([mind/...] / [repos/...])
      are anchored under the agent's own bundle.

    Pure transformation — does NOT validate accessibility. *)

val validate_path :
  Coord.config -> string -> (string, Masc_error.t) result
(** [validate_path config path] returns the canonical path on
    success, or an error variant (typically [IoError]) on:

    - null bytes in [path]
    - not in a git repository
    - path traversal outside the git root

    Symlinks are realpath-resolved when they exist; missing
    targets fall back to string-level [normalize_path]
    comparison.  Used by both {!validate_read_path} (read gate)
    and the writable-sandbox checks in [Tool_code_write]. *)

val validate_read_path :
  agent_name:string ->
  Coord.config ->
  string ->
  (string, Masc_error.t) result
(** [validate_read_path ~agent_name config path] is the
    read-side gate: applies {!normalize_agent_relative_path}
    then {!validate_path}, then realpath-resolves the canonical
    target and re-checks playground containment so a symlink
    pointing into another agent's bundle is rejected.

    The realpath check is mandatory and fail-closed — drift
    would re-open the symlink-bypass that GLM-5.1 caught on
    PR #6664 (issue #2).  Targets outside the playground tree
    pass through (shared codebase reads are allowed). *)

(** {1 Dispatch + schemas} *)

val dispatch :
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  tool_result option
(** [dispatch ctx ~name ~args] routes by tool name to the
    private handlers ([handle_code_search],
    [handle_code_symbols], [handle_code_read]).  Returns [None]
    when [name] is not a code-tool — caller treats that as
    "not my tool". *)

val schemas : Types.tool_schema list
(** [schemas] is the [Types.tool_schema list] consumed by
    [Tools.schemas] / [Config.visible_tool_schemas].  Used by
    the side-effect [Tool_spec.register] block at module load. *)

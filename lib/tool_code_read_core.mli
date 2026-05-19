(** Tool_code_read_core — SSOT for [masc_code_read] file pagination.

    Both the agent-side handler ([Tool_code.handle_code_read]) and the
    keeper-side handler ([Keeper_exec_masc.handle_keeper_masc_code_read])
    share the same read-with-pagination pipeline. Previously each
    handler open-coded the same six-step sequence
    (file_exists → binary check → size check → load → split → slice)
    and flattened every failure into the same opaque string
    ["Failed to read file: <exn>"]. The most common runtime failure —
    calling [masc_code_read] with a directory path — surfaced as
    [Sys_error("...: Is a directory")] with no structured signal to
    let the LLM switch tools.

    This module replaces both clones with a single pipeline that
    returns a typed [read_error] variant. Callers render that to JSON
    via {!read_error_to_json}, which emits an [error_kind]
    discriminator plus an optional [hint]. *)

(** {1 Read primitives (SSOT)} *)

val is_binary_file : string -> bool
(** [is_binary_file path] is [true] iff [path] ends with one of the
    pinned binary extensions (.so, .png, .pdf, …). Re-exported by
    [Tool_code.is_binary_file] for wire compatibility. *)

val max_file_size : int
(** [max_file_size = 500 * 1024]. Re-exported by
    [Tool_code.max_file_size]. *)

(** {1 Typed errors} *)

(** Typed failure variants from a file-read attempt.

    Drift in this list = silent regression in the error envelope —
    every variant must round-trip through {!read_error_to_json} with
    a stable [error_kind] discriminator string. *)
type read_error =
  | Path_is_directory of { path : string }
    (** Caller passed a directory path. Distinct from [File_not_found]
        because the recovery action differs: switch to
        [masc_code_search] or [shell "ls -la"]. *)
  | File_not_found of { path : string }
    (** Path does not exist on disk. *)
  | Binary_file of { path : string }
    (** Path matches [Tool_code.is_binary_file] (.so, .png, …). *)
  | Too_large of { path : string; size : int; max : int }
    (** File exceeds [Tool_code.max_file_size]. *)
  | Io_error of { path : string; detail : string }
    (** Captured [Sys_error] or [Unix.Unix_error] during open/read. *)
  | Internal_error of { path : string; detail : string }
    (** Catch-all for any other exception. Surfaced (not absorbed) so
        unexpected failures are visible. *)

(** {1 Successful read} *)

type ok =
  { display_path : string  (** Path as the caller passed it (echoed back). *)
  ; total_lines : int
  ; safe_offset : int
  ; safe_limit : int
  ; lines : string list
  }
(** Result of a successful pagination. *)

(** {1 Pipeline} *)

val read_with_pagination :
  display_path:string ->
  validated_path:string ->
  offset:int ->
  limit:int ->
  (ok, read_error) result
(** [read_with_pagination ~display_path ~validated_path ~offset ~limit]
    runs the full read pipeline on the already-resolved
    [validated_path] (the caller is expected to have run path
    validation first — see [Tool_code.validate_read_path] /
    [Keeper_exec_shared.resolve_keeper_read_path]).

    Order of checks:
    + [Sys.file_exists validated_path] → otherwise [File_not_found]
    + [Sys.is_directory validated_path] → otherwise [Path_is_directory]
    + [Tool_code.is_binary_file validated_path] → otherwise [Binary_file]
    + [Unix.stat … .st_size > Tool_code.max_file_size] → otherwise [Too_large]
    + open / read / split / slice — failure becomes [Io_error] (for
      [Sys_error]/[Unix.Unix_error]) or [Internal_error] (other exn).

    [Eio.Cancel.Cancelled] is re-raised unchanged so cooperative
    cancellation is not flattened to an [Io_error]. *)

val read_error_to_json : read_error -> Yojson.Safe.t
(** [read_error_to_json e] renders [e] as a JSON object with shape

    {v
      { "error": "<human-readable message>",
        "error_kind": "<discriminator>",
        "path": "<display path>",
        ["hint": "<actionable next-step>"] }
    v}

    [error_kind] values are pinned: ["path_is_directory"],
    ["file_not_found"], ["binary_file"], ["file_too_large"],
    ["io_error"], ["internal_error"]. *)

val ok_to_json : display_path:string -> ok -> Yojson.Safe.t
(** [ok_to_json ~display_path o] renders [o] as the legacy
    [masc_code_read] success envelope:

    {v
      { "path": "<display path>",
        "offset": <int>,
        "limit": <int>,
        "total_lines": <int>,
        "lines": [ "..." ] }
    v}

    Kept stable for wire compatibility with existing keepers. *)

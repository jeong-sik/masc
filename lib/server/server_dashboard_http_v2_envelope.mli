(** Shared response envelope, error contract, and non-breaking SSE push helper
    for the MASC TUI v2 server APIs (Contracts 1–4). *)

val schema_version : int
(** Current v2 API response envelope schema version ([1]). *)

val ok : ?now:float -> ?instance_id:string -> Yojson.Safe.t -> Yojson.Safe.t
(** Wrap [data] in the deterministic server-authoritative envelope:
    [{"schema_version": 1, "instance_id": ..., "generated_at_unix": ..., "data": ...}]. *)

type error_code =
  | Invalid_param
  | Unauthorized
  | Not_found
  | Conflict_cas
  | Workspace_mismatch
  | Validation_failed
  | Store_unavailable

val error_code_to_string : error_code -> string
val error_status : error_code -> Httpun.Status.t

val error_json :
  ?field:string ->
  ?extra:(string * Yojson.Safe.t) list ->
  code:error_code ->
  string ->
  Yojson.Safe.t
(** Structured error response with closed [code], human [message], optional
    [field], and optional extra diagnostic members (e.g. [current_sha256]). *)

val sha256_hex : string -> string
(** Lowercase 64-character SHA-256 hex digest of raw bytes. *)

val announce_v2_dataset :
  base_path:string ->
  dataset:string ->
  ?extra:(string * Yojson.Safe.t) list ->
  unit ->
  unit
(** Broadcast a lightweight zero-row invalidation token over the workspace's
    runtime observer SSE channel without raising or yielding. Uses
    [tui_v2_dataset_changed] so existing [workspace_dataset_changed] readers
    remain unaffected while v2 clients revalidate incrementally. *)

(** Referenced collaboration sources for a standalone reviewer. The Task
    principal is the actual producer, including non-Keeper producers. Goal
    authority covers shared records in the active workspace, not private Direct
    discussions. Direct target readership cannot be reconstructed from mutable
    post text; only the author can expose a Direct post through Task review. *)
type authority = Task_producer of string | Goal_workspace

type error =
  | Invalid_request of string
  | Access_denied of string
  | Source_unavailable of string
  | Storage_failed of string

val error_to_string : error -> string
(** Large responses are bounded JSON-text pages. The caller follows next_cursor
    with unchanged source arguments and concatenates content to recover the exact
    structured source. Each cursor pins SHA-256 and UTF-8 byte offset; every page
    uses only the immutable submitted bytes and refuses mismatched cursors. *)
val capture : config:Workspace.config -> authority:authority -> references:string list ->
  (Workspace_verification_store.submitted_evidence_item list, error) result
(** Capture explicit collaboration references before the submission commits.
    All Task references in one capture use the same strict primary backlog
    observation. Captured items carry all source bytes and ownership; reads
    never consult live Board or Task state. *)
val read_board : submitted_evidence:Workspace_verification_store.submitted_evidence_item list -> args:Yojson.Safe.t ->
  (Yojson.Safe.t, error) result
val read_fusion : submitted_evidence:Workspace_verification_store.submitted_evidence_item list -> args:Yojson.Safe.t ->
  (Yojson.Safe.t, error) result
val read_task : submitted_evidence:Workspace_verification_store.submitted_evidence_item list -> args:Yojson.Safe.t ->
  (Yojson.Safe.t, error) result
(** [task_ids] must name exactly one explicitly submitted [task:<id>]. Capture
    uses the strict primary backlog and retains its revision, last update and
    full canonical Task row. Read never consults the current backlog. The row
    describes committed state, including completion time and notes; it is not
    a complete approval history or evidence of external acceptance. A Done row
    does not have typed verifier/verification-id fields; its notes remain
    attributed Task content, not a reconstructed approval certificate. Shared
    Task records are available to both Task and Goal review authority. *)

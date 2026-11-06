(** Workspace init / reset.

    Boot-time workspace state initialisation and a destructive [reset]
    helper for tests and explicit internal maintenance. *)


type initialization_error =
  | Cold_memory_has_local_document of string
  | Document_presence_unavailable of { path : string; detail : string }
  | State_present_without_backend_initialization of string
  | Backlog_seed_failed of string
  | Backlog_seed_committed_with_mirror_error of string
  | Backlog_seed_lease_refused of Workspace_utils_ops.lease_commit_refusal
  | State_seed_failed of string
  | State_seed_lease_refused of Workspace_utils_ops.lease_commit_refusal
  | Mirror_unverified of { path : string; detail : string }

exception Initialization_failed of initialization_error

(** Initialise workspace state. A missing backlog is seeded only when state
    and recovery documents are also absent. A cold Memory backend refuses to
    replace existing local workspace documents. *)
val init :
  Workspace_utils_backend_setup.config -> agent_name:'a option -> string

(** Destructive reset of workspace state for tests and explicit internal
    maintenance. Symlinks inside the workspace are unlinked without deleting
    their targets. Removed directories can be recreated by memoized writers. *)
val reset : Workspace_utils_backend_setup.config -> string

val traces_dirname : string
(** The trace directory init creates below [<base>/.masc]. *)

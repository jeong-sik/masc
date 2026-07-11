(** Schema-owned recovery for descriptor-writer temporary entries.

    The scanner never treats a filename pattern as filesystem ownership. It
    derives a closed catalog from the resolved workspace configuration and
    visits only those roots. Playground, repository, connector, and user
    workspace trees are absent from the catalog. *)

type root_kind =
  | Workspace_root
  | Activity_events
  | Agents
  | Config
  | Delegation_requests
  | Draft_skills
  | Exec_artifacts
  | Keepers
  | Media
  | Messages
  | Operator
  | Procedures
  | Schedules
  | Secrets
  | Tasks
  | Tool_blobs
  | Traces
  | Trajectories
  | Verifications

type traversal =
  | Entries_only
  | Recursive

type catalog_entry = private
  { root_kind : root_kind
  ; path : string
  ; traversal : traversal
  }

type provenance =
  { root_kind : root_kind
  ; catalog_root : string
  ; relative_path : string
  ; source_path : string
  }

type pending_reason =
  | Symlink
  | Non_regular_file
  | Catalog_root_is_not_directory

type failure_stage =
  | Open_directory
  | Close_directory
  | Read_directory
  | Inspect_entry
  | Create_recovery_directory
  | Inspect_recovery_target
  | Link_recovery_target
  | Confirm_recovery_directory
  | Delete_source
  | Confirm_source_directory
  | Recovery_name_exhausted

type mutation_effect =
  | Source_unchanged
  | Recovery_link_created of string
  | Source_unlinked

type outcome =
  | Deleted of
      { provenance : provenance
      ; diagnostics : Fs_compat.Durable_mutation.diagnostic list
      }
  | Preserved of
      { provenance : provenance
      ; recovered_path : string
      ; diagnostics : Fs_compat.Durable_mutation.diagnostic list
      }
  | Pending of
      { provenance : provenance
      ; reason : pending_reason
      }
  | Failed of
      { provenance : provenance
      ; stage : failure_stage
      ; mutation_effect : mutation_effect
      ; cause : exn
      ; backtrace : Printexc.raw_backtrace
      ; diagnostics : Fs_compat.Durable_mutation.diagnostic list
      }

type summary =
  { deleted : int
  ; preserved : int
  ; pending : int
  ; failed : int
  }

val catalog : Workspace_utils.config -> catalog_entry list
(** The complete recovery ownership catalog for the resolved cluster root. *)

val recover_blocking : config:Workspace_utils.config -> outcome list
(** Scan and recover catalog-owned roots on the calling system thread. *)

val recover_eio : config:Workspace_utils.config -> outcome list
(** Cancellation-protected Eio boundary for {!recover_blocking}. *)

val summarize : outcome list -> summary
val root_kind_to_string : root_kind -> string
val outcome_to_string : outcome -> string

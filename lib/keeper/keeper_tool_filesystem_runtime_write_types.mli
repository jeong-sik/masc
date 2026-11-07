(** The types that describe the outcome of a write of
    [Keeper_tool_filesystem_runtime].

    [created_directory_commit] records one directory that a write created: its
    target effect, the failure that stopped it, and the sync outcome of the
    child and of the parent directory. [append_target_effect] and
    [append_write_outcome] say what an append did to its target.
    [content_write_error] is the error of a content write: a capability error
    or a failed directory creation, each with the directories created before
    it, or an append outcome. [content_publication] is a publication of the
    content that either recovers independently or is guarded by a
    [Fs_compat.Publication_recovery.t].
    [file_write_attempt] is the result of one attempt to write: the target
    stayed unchanged, the write succeeded with its change evidence, the Gate
    authorized the attempt that follows, the Gate deferred it, or it failed.
    [Keeper_tool_filesystem_runtime] includes this module. *)

type created_directory_commit = {
  component : string;
  target_effect : created_directory_target_effect;
  primary_failure : created_directory_failure option;
  child_sync : created_directory_sync_outcome;
  parent_sync : created_directory_sync_outcome;
}
and created_directory_target_effect =
    Directory_unchanged
  | Directory_created_validated
  | Directory_created_requested_mode
  | Directory_state_unknown
and created_directory_stage =
    Create_directory
  | Inspect_created_directory
  | Acquire_directory_capability
  | Validate_directory_capability
  | Apply_directory_permissions
and created_directory_operation_failure = {
  exception_ : exn;
  backtrace : Printexc.raw_backtrace;
}
and created_directory_failure_cause =
    Directory_posix_descriptor_unavailable
  | Directory_unexpected_resource_kind of Eio.File.Stat.kind
  | Directory_resource_identity_changed
  | Directory_operation_failed of created_directory_operation_failure
and created_directory_failure = {
  stage : created_directory_stage;
  cause : created_directory_failure_cause;
}
and created_directory_sync_outcome =
    Directory_sync_not_attempted
  | Directory_sync_succeeded
  | Directory_sync_failed of Fs_compat.capability_directory_sync_error

type append_target_effect =
  | Append_target_unchanged
  | Append_target_extended_complete
  | Append_target_extended_partial
  | Append_target_extended_detached
  | Append_target_state_unknown

type append_write_outcome = Fs_compat.capability_append_outcome =
  { requested_bytes : int
  ; bytes_written : int
  ; write_failure : Fs_compat.capability_append_failure option
  ; sync_failure : Fs_compat.capability_append_operation_failure option
  ; target_binding : Fs_compat.capability_append_target_binding
  }

type content_write_error =
  | Content_write_capability of
      { error : Fs_compat.capability_write_error
      ; created_parents : created_directory_commit list
      }
  | Content_write_directory of
      { failed_commit : created_directory_commit
      ; created_parents : created_directory_commit list
      }
  | Content_write_append of append_write_outcome

type content_publication =
  | Recovery_independent of (unit -> (unit, content_write_error) result)
  | Recovery_guarded of
      (Fs_compat.Publication_recovery.t
       -> (unit, content_write_error) result)

type file_write_attempt =
  | Write_unchanged of Yojson.Safe.t
  | Write_succeeded of
      { payload : Yojson.Safe.t
      ; file_change_evidence : Keeper_file_change_evidence.t option
      }
  | Write_authorized of Keeper_gate.authorization * file_write_attempt
  | Write_deferred of Keeper_gate_deferred_payload.t
  | Write_failed of
      { payload : string
      ; class_ : Tool_result.tool_failure_class
      }
  | Write_failed_data of
      { message : string
      ; data : Yojson.Safe.t
      ; class_ : Tool_result.tool_failure_class
      }

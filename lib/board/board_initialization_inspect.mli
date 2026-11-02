(** Private, noncreating observation owner. No cursor or write authority. *)
type raised = exn * Printexc.raw_backtrace
type file_io = {
  posts : Fs_compat.private_jsonl_transaction_io_for_testing;
  guard : Fs_compat.private_jsonl_transaction_io_for_testing;
}
type decision = Bootstrap_required | Adoption_required | Ready_observed | Refused
type root
type root_failure =
  | Empty_base_path
  | Base_path_not_directory of string
  | Root_binding_changed of string
  | Workspace_boundary_refused of Fs_compat.owned_directory_chain_rejection
  | Dependent_entry_present of { path : string; kind : Unix.file_kind }
  | Root_operation_failed of raised
type posts_intent = Missing_posts | Present_posts of { sha256 : string }
type t

val read : ?io:file_io -> base_path:string -> unit -> t
val decision : t -> decision
val intent_sha256 : t -> string option
val posts_source_sha256 : t -> string option
val posts_intent : t -> posts_intent option
val root : t -> root option
val workspace_masc_dir : root -> string
val check_boundary : root -> (unit, root_failure) result
(** Revalidate original absolute spelling, physical root and no-follow lexical
    .masc chain. All syscall exceptions retain the original exception/rawbt. *)
val check_bootstrap_dependents : root -> (unit, root_failure) result
(** Recheck the same bootstrap-only no-follow inventory immediately before
    writing posts. Every comments, reactions, sub-boards and votes leaf must
    still be genuinely absent. Other actions must not call this function. *)
val retained_reserved : t -> raised option
val root_failure_reserved : root_failure -> raised option
val root_failure_to_yojson : root_failure -> Yojson.Safe.t
val to_yojson : t -> Yojson.Safe.t
val finish : t -> unit

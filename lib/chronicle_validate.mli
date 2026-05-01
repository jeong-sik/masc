(** Chronicle_validate — cross-validate chronicle epochs against git history.
    @since Project Chronicle Phase 4 *)

(** Git capture hook for test isolation. *)
type git_capture_hook =
  workdir:string -> string list -> (Unix.process_status * string) option

val set_git_capture_hook_for_tests : git_capture_hook -> unit
val clear_git_capture_hook_for_tests : unit -> unit

(** Result of validating a chronicle epoch. *)
type validation_result =
  { epoch_id : string
  ; is_valid : bool
  ; sha_check : bool
  ; file_range_check : bool
  ; rfc_refs_valid : bool list
  ; verification_score : float  (** 0.0 ~ 1.0 *)
  ; warnings : string list
  }
[@@deriving show]

(** Validate a chronicle epoch against git history.

    Checks:
    - Referenced SHAs exist ([sha_check])
    - Key files are covered by the commit range ([file_range_check])
    - RFC files exist on disk ([rfc_refs_valid])

    [verification_score] is weighted: SHA 0.3, files 0.3, RFCs 0.4.
    [is_valid] requires [sha_check] and [file_range_check] both [true]. *)
val validate_epoch :
  workdir:string ->
  Chronicle_types.chronicle_epoch ->
  validation_result

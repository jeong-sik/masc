(** The Edit tool's replace step, pure: the same patch is applied whether the
    bytes were read from a host file or brought back over the remote lane. *)

type patch_application =
  { updated : string
  ; occurrence_count : int
  ; line_occurrences : Keeper_file_change_evidence.edit_occurrence list option
        (** [None] when more occurrences were replaced than the evidence
            records per edit. *)
  }

val apply_patch
  :  old_string:string
  -> new_string:string
  -> replace_all:bool
  -> string
  -> (patch_application, string) result
(** Replace [old_string] with [new_string]. Without [replace_all], exactly one
    occurrence is required; zero occurrences and an empty [old_string] are
    errors. The messages are the model-facing text. *)

val file_change_evidence : patch_application -> Keeper_file_change_evidence.t

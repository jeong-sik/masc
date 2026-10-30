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

(** What a patch does to the bytes. [Replace] is the Edit tool's step;
    [Insert_before_line] puts one line above an existing line, indented like
    it, and is how a memo tool places a comment without naming the text it
    goes above. *)
type operation =
  | Replace of
      { old_string : string
      ; new_string : string
      ; replace_all : bool
      }
  | Insert_before_line of
      { line : int  (** 1-based; the line the new one goes above *)
      ; text : string  (** one line, without its line break *)
      }

val operation_label : operation -> string
(** ["replace"] or ["insert_before_line"], for the audit line. *)

val apply : operation -> string -> (patch_application, string) result
(** [Replace] is {!apply_patch}. [Insert_before_line] requires the line to
    exist (an empty file has none) and the text to be one non-empty line;
    the evidence is one occurrence whose old range is that line and whose
    new range covers the inserted line and it. *)

val file_change_evidence : patch_application -> Keeper_file_change_evidence.t

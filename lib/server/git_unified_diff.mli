(** Rows of one file's [git diff] / [git show] output, as the
    [/api/v1/git/diff] route sends them. *)

type hunk = {
  old_start : int;
  old_count : int;
  new_start : int;
  new_count : int;
  section : string option;
      (** The function context git prints after the closing [@@]. *)
}

type row =
  | Hunk of hunk
  | Context of { old_line : int; new_line : int; text : string }
  | Added of { new_line : int; text : string }
  | Deleted of { old_line : int; text : string }

val parse : string list -> (row list, string) result
(** [parse lines] reads the lines of one unified diff. Each hunk body is read
    by its header's line counts, so a deleted line whose text starts with
    [--] is a deletion and not a file header. A malformed hunk header or a
    body line without a diff marker is an [Error]. The error never quotes
    file content. *)

val row_to_json : row -> Yojson.Safe.t

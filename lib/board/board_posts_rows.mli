(** Pure framing-independent decoding of one persisted posts row.
    Blank rows retain their line number at the caller. No diagnostics are
    emitted here, including when a rejected outer row carries nested errors. *)
type row =
  | Blank
  | Accepted of {
      post : Board_types.post;
      diagnostics : Board_content_json.diagnostic list;
    }
  | Rejected of {
      error : Board_types.posts_row_error;
      diagnostics : Board_content_json.diagnostic list;
    }

val decode : line:int -> string -> row

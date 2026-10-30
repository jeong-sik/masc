(** A retained item's text, split into the parts a reader actually reads.

    Message rows arrive as wire JSON whose typed [content_blocks] carry the
    prose; prompt rows arrive as text. Re-wrapping either one as flat text
    folded the blocks into each other and the pane read as noise. This module
    walks the typed blocks and says what each part is; it holds no terminal
    vocabulary, so the caller decides how a text, a JSON payload, and a
    structural label are styled. *)

type section =
  | Text of string  (** Prose. Markdown, rendered by the caller. *)
  | Json of string  (** A structured payload. Already indented; one row per line is the caller's. *)
  | Marker of string  (** A structural label: a tool name, a block kind. *)

val sections : text:string -> section list
(** Split one retained item. Text that parses as JSON with typed content
    blocks becomes those blocks; JSON without them stays one [Json] section;
    text that is not JSON stays one [Text] section. *)

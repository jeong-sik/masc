(** Retrieval_projection — Normalise heterogeneous search tool output
    into a uniform [source/location: content] line format reminiscent
    of [grep].

    Accepts search output as either labelled chunks separated by
    ["\n---\n"] or a raw JSON document, and renders a compact line
    per result. Values that exceed the per-line cap are truncated
    byte-safely. *)

(** [grep_like_line ~source ~location ~content] renders a single line:
    ["<source>/<location>: <content>"]. Empty fields fall back to
    ["search"] / ["result"] / ["(no content)"]. [location] collapses
    whitespace and truncates to 120 bytes; [content] collapses
    whitespace and truncates to 300 bytes. *)
val grep_like_line :
  source:string -> location:string -> content:string -> string

(** [lines_of_search_output ?max_lines input] splits [input] on
    ["\n---\n"], parses each chunk as either a labelled payload
    ([\[label\]: ...]) or raw JSON, and emits one
    {!grep_like_line} per result. [max_lines] defaults to [20]. *)
val lines_of_search_output : ?max_lines:int -> string -> string list

(** [format_search_output] is {!lines_of_search_output} joined by
    ["\n"]. *)
val format_search_output : ?max_lines:int -> string -> string

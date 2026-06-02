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


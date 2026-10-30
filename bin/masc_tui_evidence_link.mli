(** The links an evidence item carries, parsed once so the renderer matches on
    a closed variant instead of searching text.

    Two kinds exist in the data. A submitted source ([board:<id>],
    [fusion:<id>], [task:<id>]) names a MASC object the TUI can open with its
    [masc://] reference. Navigation opens the current object; the submitted
    evidence body remains the immutable snapshot. A URL written in a note, in a source's text or in an artifact's
    text is an http(s) address. A file artifact's path is the item's own
    reference line, so it is not repeated as a link: it is a path in the
    producer's sandbox, not an address the operator can open.

    The TUI writes none of these as terminal hyperlinks. Its width, wrap and
    truncation code counts only CSI sequences as zero-width, so an OSC 8
    sequence would be measured as printable text and could be cut open. The
    link is printed as text. *)

type t =
  | Web_url of string  (** http or https, with a host *)
  | Masc_reference of { kind : Masc_tui_link.kind; id : string }

val of_item : Masc.Tui_decode.verification_evidence_item -> t list
(** In the order the links appear, without repeats. *)

val web_urls : string -> t list
(** The http(s) URLs in plain text. A URL ends where
    {!Masc_tui_message_layout.bare_urls} ends it, minus sentence punctuation
    that follows it: a trailing [.], [,], [;], [:], [!] or [?] is the
    sentence's, not the address's. *)

val text : t -> string
(** What the pane prints: the URL itself, or the [masc://] reference
    ({!Masc_tui_link.reference}). *)

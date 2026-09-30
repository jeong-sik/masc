(** Pure projections of external text for terminal display.
    This boundary owns escaping and timestamp presentation, independently of
    JSON decoding. The caller supplies the timezone conversion. *)

val escape_invisible : string -> string
(** Draw bidi controls, zero-width characters and tag characters (U+061C,
    U+200B-U+200F, U+202A-U+202E, U+2066-U+2069, U+FEFF, U+E0000-U+E007F) as
    their own escape text: [\uXXXX] inside the basic plane and [\UXXXXXXXX]
    above it, since the tag block needs five digits. A terminal draws them as
    nothing, so without this the glyphs an operator reads can differ from the
    bytes an approval hash covers (Trojan Source, CVE-2021-42574; spelling
    ASCII in tag characters is the same trick without the bidi). Two
    exceptions are characters a reader can see the effect of, and each is
    admitted by its neighbours rather than by a list: a zero-width joiner
    between two pictographs (UAX #29 GB11), and a subdivision flag -- U+1F3F4,
    three to seven tag characters in the lowercase-and-digit shape UTS #51
    gives a subdivision code, then the terminator U+E007F -- which is kept
    whole or escaped whole. Tag characters outside that shape are drawn even
    behind a flag: the wider grammar spells sentences, and a flag is all a
    reader would see of them. {!sanitize_terminal_text} and the Keeper chat
    boundary both route through here, so the rule lives in one place. *)

val sanitize_terminal_text : string -> string
(** Escape C0, DEL, raw C1 bytes, UTF-8 encoded C1 code points, malformed
    UTF-8 bytes, and the invisible code points {!escape_invisible} names, so
    external values form one printable terminal row. Call at the terminal
    rendering boundary; decoded records intentionally retain their raw typed
    value for non-terminal consumers. *)

val sanitize_terminal_lines : string -> string
(** [sanitize_terminal_lines text] keeps each LF of [text] as a line break and
    puts every line between them through {!sanitize_terminal_text}, so each
    other control byte -- a tab, a carriage return, an ESC -- is drawn as its
    visible escape rather than sent to the terminal or folded into a space.
    For a text read whole, where a reader must see what the bytes are. *)

val preview_line : string -> string
(** One row of a multi-line text for a list cell: each line break (LF, CR LF,
    or a lone CR) becomes the one-cell return mark U+23CE, a tab becomes a
    space, and everything else goes through {!sanitize_terminal_text}. Where
    that function is the boundary for values that must not carry control
    bytes, this one is for text whose breaks are content: a file's edit, a
    tool call's arguments. *)

val short_timestamp_of_unix_for_terminal :
  localtime:(float -> Unix.tm) -> float -> string
(** [YYYY-MM-DD HH:MM:SS] of a Unix time in the zone [localtime] converts to.
    The same shape {!short_timestamp_for_terminal} draws, for a time the wire
    carries as a number. *)

val short_timestamp_for_terminal :
  localtime:(float -> Unix.tm) -> string -> string
(** [YYYY-MM-DD HH:MM:SS] of an RFC 3339 timestamp in the zone [localtime]
    converts to, then sanitized. A timestamp the codec cannot read keeps at most
    its first 19 source bytes; slicing before the terminal boundary ensures a
    split UTF-8 scalar cannot recreate a raw C1 byte. Empty timestamps render as
    [(never)]. *)

val clock_timestamp_of_unix_for_terminal :
  localtime:(float -> Unix.tm) -> float -> string
(** [HH:MM:SS] of a Unix time in the zone [localtime] converts to. The same
    shape {!clock_timestamp_for_terminal} draws, for a time the wire carries
    as a number rather than an RFC 3339 string -- the pairing
    {!short_timestamp_of_unix_for_terminal} already is for
    {!short_timestamp_for_terminal}. Always digits and colons, so unlike its
    string-input sibling this need not sanitize its own output. *)

val clock_timestamp_for_terminal :
  localtime:(float -> Unix.tm) -> string -> string
(** The [HH:MM:SS] clock of an RFC 3339 timestamp in the zone [localtime]
    converts to - [Unix.localtime] on a screen, [Unix.gmtime] or a fixed
    offset in a test - then sanitized. A timestamp the codec cannot read
    keeps the conventional eight-byte slice, so the result is still one
    clock-shaped row fragment; the final sanitizer makes arbitrary external
    bytes safe even when the slice splits UTF-8. *)

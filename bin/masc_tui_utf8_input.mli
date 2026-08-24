(** Assembling one character from a byte stream that may not have all of it
    yet.

    A terminal delivers keystrokes as bytes, and a character outside ASCII is
    several of them. The leading byte states how many follow, and a terminal
    that sent it will send the rest — but not necessarily in the same read. A
    character straddles the buffer boundary, or the emulator re-sends a
    syllable while an input method composes it, and the wait for the next byte
    expires with the character half read.

    Discarding the head there loses the character twice over: the character
    itself, and then its tail, which stays in the stream and is read as
    continuation bytes that begin nothing. One dropped Hangul syllable arrives
    as three unrecognised keys.

    So a run that ends early answers {!Incomplete} with what it has, and the
    caller resumes from there when more bytes arrive. Only a byte that cannot
    belong to the character is a decoding failure.

    Pure: the caller supplies the bytes. Nothing here touches a terminal. *)

type outcome =
  | Complete of string
      (** Every byte arrived and the result is well-formed UTF-8. *)
  | Incomplete of string
      (** The stream had no more bytes to give. Carries what was read so far,
          which is the [prefix] a later call resumes from — never empty, since
          it always holds at least the leading byte. *)
  | Malformed of { pushback : char option }
      (** The character cannot be assembled. [pushback] is a byte that was
          read and does not belong to it, which the caller returns to the
          stream so it is read as whatever it actually is; [None] when the
          bytes arrived but did not form a valid scalar. *)

val is_continuation : char -> bool
(** Whether a byte can appear after the leading byte of a character
    (0x80-0xBF). *)

val read_scalar :
  prefix:string ->
  expected_length:int ->
  next_byte:(unit -> char option) ->
  outcome
(** Assemble a character that starts with [prefix] and is [expected_length]
    bytes long.

    [prefix] is one leading byte on a first attempt, or the {!Incomplete}
    value from an attempt that ran out. [next_byte] returning [None] means no
    byte is available now, which is {!Incomplete} rather than a failure. *)

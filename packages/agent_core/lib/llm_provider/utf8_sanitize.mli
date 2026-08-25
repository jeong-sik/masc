(** Replace invalid UTF-8 bytes with U+FFFD and disallowed control
    characters with spaces.

    OCaml strings are byte sequences with no UTF-8 guarantee.
    When tool results or LLM responses contain truncated multi-byte
    sequences or raw bytes from file reads, Yojson passes them
    through without validation.  Some providers (Glm/BigModel)
    reject the resulting JSON with parse errors.  Control characters
    (0x00-0x1F except LF/CR/TAB, plus DEL) break prompt formatting.

    Validity follows the Unicode standard via the OCaml Stdlib UTF-8
    decoder, so overlong encodings, UTF-16 surrogates, and code points
    above U+10FFFF are rejected (a byte-length check alone cannot).

    Valid UTF-8 with no control chars is passed through unchanged.
    The function runs in O(n) with a fast-path that avoids allocation
    when the input is already clean.

    @stability Internal
    @since 0.93.1
    @since 0.138.0 — control character sanitization
    @since 0.139.0 — UTF-8 validation delegated to the Stdlib decoder *)

val sanitize : string -> string

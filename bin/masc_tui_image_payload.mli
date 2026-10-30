(** Encoded image identity and pure decoding. No byte sniffing, fetching,
    filesystem access or rendering. The declared format chooses the decoder. *)
type format = Svg | General_image
type t

val format_of_mime : string -> format
val of_base64 : mime_type:string -> string -> t
val of_data_uri : string -> (t, string) result
(** Requires a declared image data URI. Bodies may use percent encoding or a
    base64 marker; MIME parameters and the complete original URI are retained.
    Does not decode the body. *)
val format : t -> format
val encoded : t -> string
(** Original encoded input, including a data URI's complete header. *)
val decode : t -> (string, string) result
val decode_wire : string -> (string, string) result
(** Decode raw base64 or a data URI, including non-image media used by audio
    callers. Data URI bodies are percent-decoded once before optional base64
    decoding; literal [+] stays [+] and a URI fragment is excluded from bytes.
    This codec does not validate the decoded media. *)

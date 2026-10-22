(** Encoded image identity and pure decoding. No byte sniffing, fetching,
    filesystem access or rendering. The declared format chooses the decoder. *)
type format = Svg | General_image
type t

val format_of_mime : string -> format
val of_base64 : mime_type:string -> string -> t
val of_data_uri : string -> (t, string) result
(** Requires an image data URI with a base64 marker; MIME parameters are retained.
    Does not decode the body. *)
val format : t -> format
val encoded : t -> string
(** Original encoded input, including a data URI's complete header. *)
val decode : t -> (string, string) result
val decode_wire : string -> (string, string) result
(** Decode raw base64 or a base64 data URI, including non-image media used by
    audio callers. This codec does not validate the decoded media. *)

(** Gzip codec — the fallback half of HTTP content negotiation.

    {!Compression_codec} owns zstd. Until this module existed the encoding
    vocabulary had exactly one member, so "client does not speak zstd" and
    "send it uncompressed" were the same branch: a dashboard telemetry response
    measured 7,540 bytes to a zstd client and 1,095,519 bytes to every other
    one, a factor of 145. zstd is sent only by Chrome 123+ and Firefox 126+ in
    secure contexts; Safari, curl, and every programmatic client fall through.

    This module is deliberately separate from {!Compression_codec} rather than a
    third constructor in its [encoding] type: that type is also what
    {!Compression_codec.decompress} dispatches on for stored payloads, and a
    stored zstd blob has nothing to do with what an HTTP client will accept.
    Negotiation is a transport concern and lives in [http_response_payload]. *)

type compress_result =
  | Unchanged of string
      (** Payload below {!Compression_codec.min_size}, or encoding did not
          shrink it, or the encoder raised. Callers send the original body with
          no [Content-Encoding]. *)
  | Compressed of string  (** gzip-encoded payload. *)

val compress : ?level:int -> string -> compress_result
(** [compress ?level data] gzip-encodes [data] (default level 4).

    The gzip header carries no mtime, filename, or comment, so identical input
    always yields identical bytes. Encoder failures are logged and surfaced as
    [Unchanged] rather than raised: a response that cannot be compressed is
    still a response. *)

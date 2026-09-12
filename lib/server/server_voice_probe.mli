(** Server_voice_probe — what a voice probe reads and reports, without a
    transport.

    Two route tables answer [/api/v1/voice/probe/{tts,stt}]: the HTTP/1 router
    in {!Server_routes_http_routes_voice} and the HTTP/2 gateway in
    {!Server_h2_gateway}. Reading the request and shaping the report live here
    so the two cannot come to answer differently; each table only gates the
    request and writes the result.

    [masc voice-verify] runs the same {!Masc.Voice_bridge} probes from a
    shell. *)

val audio_suffix_of_content_type : string option -> string
(** The file extension a transcription probe should give its temporary copy of
    the request body, read from the request's [content-type]. Unknown and
    absent types fall to [".webm"], which is what a browser records. *)

val tts_report : body:string -> (Yojson.Safe.t, string) result
(** [tts_report ~body] synthesizes the body's ["message"] on every configured
    speech-out endpoint and reports each attempt. Unlike the chain behind
    agent_speak this does not stop at the first endpoint that answers: a chain
    that works says nothing about the endpoints behind it. [Error] carries a
    reason for the caller to return as a bad request. *)

val stt_report :
  content_type:string option -> body:string -> (Yojson.Safe.t, string) result
(** [stt_report ~content_type ~body] transcribes the raw audio in [body] on
    every configured speech-in endpoint and reports each attempt. The bytes
    are the body itself, not a multipart part. *)

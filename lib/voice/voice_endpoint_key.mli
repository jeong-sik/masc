(** The key a voice endpoint sends (multi-account plan D4d).

    An endpoint whose adapter names a key variable, such as ElevenLabs, sends
    the value the operator set for the host, an account of the host. A
    multi-account process shares no account of its host, so {!resolve}
    refuses there before it reads the variable. An endpoint that names no key
    sends the empty key in every process. {!Voice_bridge_transport} reads no
    credential: its HTTP calls take what {!resolve} returns. *)

val resolve : Voice_config.endpoint -> (string, string) result
(** The trimmed value of the variable the endpoint names, or the empty key
    for an endpoint that names none. [Error] names the variable when it is
    unset or blank, or is the refusal of the access. *)

(** Server_voice_setup_actions — the wire shape of voice setup.

    JSON lives here rather than in {!Voice_setup}: that module is the domain,
    this is the transport, and a change that arrives over HTTP has to be parsed
    into the closed sum type before it means anything. Unknown input is refused
    by name rather than folded into a default -- a request naming an endpoint
    kind this build does not have is a request for something that will not work,
    and answering it with a guess writes that guess to runtime.toml.

    Call only after CanAdmin: every route here reads or rewrites the
    workspace's runtime.toml. *)

type error =
  | Invalid_request of string
      (** The body is not a request this route understands. The message names
          which field, so a caller is not left guessing. *)
  | Setup_failed of Voice_setup.error

val error_message : error -> string

val observe : base_path:string -> (Yojson.Safe.t, error) result
(** The current revision and the voice configuration in full: each endpoint's
    id, kind, address and credential variable, the section defaults, and the
    per-agent voice map.

    [GET /api/v1/voice/config] deliberately answers less than this -- three
    booleans, no endpoint identity -- because it is a public read. This one is
    admin-gated and exists so a wizard can show what is actually configured
    before changing it.

    Credential variable NAMES are included; no value of one is read. *)

val preview : base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t, error) result
(** The runtime.toml text these changes would commit, without committing it, so
    an operator can see what is about to change before agreeing to it. *)

val apply : base_path:string -> Yojson.Safe.t -> (Yojson.Safe.t, error) result
(** Apply the changes in one commit under the config write lock, all of them or
    none, and answer with the revision that results.

    The request must carry the revision it was written against. A caller that
    read, thought, and then wrote is told its read went stale rather than
    quietly overwriting whoever wrote in between. *)

val catalogue_endpoint_of_json
  :  Yojson.Safe.t
  -> (Voice_config.endpoint, error) result
(** The endpoint a catalogue read is taken against, built from [{"kind": ...}]
    and an optional ["api_key_env"]. Not an endpoint anyone configured: it is
    made for one request and thrown away, so it carries no address and no
    command path -- a destination this route cannot check is not one to take
    from a caller. *)

(** Canonical split for a ["provider:model_id"] runtime model spec.

    This is the single home for the ["provider:model"] split used inside the
    {!Runtime} boundary (OAS-facing). It is a zero-dependency leaf so that both
    {!Runtime_model_string} and {!Provider_kind_resolver} can depend on it
    without forming a module cycle (the previous duplicate copy in
    {!Provider_kind_resolver} existed only to dodge that cycle).

    This split lives strictly inside the OAS/runtime boundary. masc-core
    consumers (auth, keeper dispatch) must not call it: per RFC-0211 a runtime id
    is opaque to the masc core, and only OAS / the runtime adapter parses an id
    into a provider/model. *)

(** [split_provider_model s] splits [s] at the first colon into
    [(provider_name, model_id)]. Returns [None] when the colon is missing,
    leading, or trailing (an empty half). [provider_name] is trimmed and
    lower-cased; [model_id] is trimmed. *)
val split_provider_model : string -> (string * string) option

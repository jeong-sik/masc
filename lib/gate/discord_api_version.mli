(** The Discord API version this client speaks.

    Discord carries one version number across both surfaces we use.
    The REST API takes it in the request path — "You should specify
    which version to use by including it in the request path like
    [https://discord.com/api/v{version_number}]" — and the gateway
    takes it in the [v] query parameter, which the gateway docs
    define as "API Version to use" over that same version list.

    So it lives here once, and both callers build their URLs from
    it rather than spelling the number again. *)

val current : int

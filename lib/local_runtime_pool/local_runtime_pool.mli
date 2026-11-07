(** Local_runtime_pool — names for the local OpenAI-compatible runtimes that
    [masc_runtime_verify] checks. *)

val default_pool_label : string
(** ["local64"] — a pool selector that [masc_runtime_verify] treats like
    ["default"]: every discovered endpoint is checked. *)

val runtime_id_of_base_url : string -> string
(** Derives a stable runtime id from a [base_url]. A URL with a port maps to
    ["local-<port>"] (["http://127.0.0.1:8081"] → ["local-8081"]); a URL
    without one maps to ["local-"] followed by the first 8 hex digits of the
    MD5 of the URL. Identical URLs always map to the same id.
    [masc_runtime_verify] reports it as [runtime_id] in each row and accepts
    it as a pool selector. *)

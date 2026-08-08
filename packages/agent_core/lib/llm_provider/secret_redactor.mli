(** Best-effort secret redaction for strings and JSON values.

    @since 0.207.0 *)

(** [redact_string s] scans [s] for generic credential contexts such as
    authorization and API-key headers, URL userinfo, and PEM private key
    blocks, replacing their values with [[REDACTED]]. Base64 media data URLs
    are collapsed before token scanning so image/document payloads do not
    dominate trace/log CPU or storage. Bare strings are not classified from
    provider-specific token formats; callers should use typed secret fields for
    values they already know are credentials. Ordinary text is returned
    unchanged. *)
val redact_string : string -> string

(** [redact_json j] recursively redacts string values inside a JSON tree.
    The tree structure and key names are preserved. *)
val redact_json : Yojson.Safe.t -> Yojson.Safe.t

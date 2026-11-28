(** The public base URL of a workspace, as a link is built on it. *)

val is_http_origin : string -> bool
(** Whether [base] is a plain [http://] or [https://] origin of printable
    ASCII with a host, an optional valid port, and no userinfo, path, query,
    or fragment. A trailing slash is a path: callers that accept one strip it
    first, as {!Env_config_core.masc_http_base_url_opt} does. *)

(** Auth config persistence helpers. *)

open Masc_domain

val load_auth_config : string -> auth_config
(** [load_auth_config config] reads [.masc/auth/config.json] under [config].
    Returns [default_auth_config] on missing / parse errors. *)

val save_auth_config : string -> auth_config -> unit
(** [save_auth_config config cfg] persists the auth config. *)

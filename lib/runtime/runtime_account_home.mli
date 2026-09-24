val of_string : string -> (string, string) result
(** Accept a non-empty absolute path without surrounding whitespace. Preserve
    its exact spelling: an official client's credential store may use the home
    path text as part of its Keychain identity. *)

val of_inherited : string -> (string, string) result
(** Resolve a relative inherited CLI home against this process's cwd. Unlike
    configured [account-home], CLI environment variables may be relative. No
    lexical or symlink canonicalization changes the selected path spelling. *)

val is_valid : string -> bool
(** The same rule for direct client configurations and TOML declarations. *)

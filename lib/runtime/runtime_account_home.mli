val of_string : string -> (string, string) result
(** Accept a non-empty absolute path without surrounding whitespace. *)

val is_valid : string -> bool
(** The same rule for direct client configurations and TOML declarations. *)

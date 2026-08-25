(** Boot-resolved HTTP authorization policy.

    Environment reads belong to the server composition root. Request handlers
    receive this closed, parsed policy through {!Server_auth.configure} and do
    not re-read or re-parse ambient process state. *)

type raw =
  { allow_anonymous_mutations : string option
  ; loopback_dev_mutation_origins : string option
  }

type resolve_error =
  | Malformed_boolean of
      { name : string
      ; raw : string
      }
  | Malformed_origin of
      { name : string
      ; raw : string
      }

type t

val read_env : unit -> raw
(** Read the two HTTP authorization environment inputs once. *)

val resolve : raw -> (t, resolve_error) result
(** Parse the complete policy. Missing and blank boolean values use the current
    defaults; other present malformed values are errors. *)

val fail_closed : t
(** Policy used before the composition root installs configuration: anonymous
    mutations are denied and no development origin is allowlisted. *)

val allow_anonymous_mutations : t -> bool
val loopback_dev_mutation_origins : t -> Server_request_authority.serialized_origin list
val equal : t -> t -> bool
val resolve_error_to_string : resolve_error -> string

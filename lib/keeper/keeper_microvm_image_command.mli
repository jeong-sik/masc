(** Pure Apple image metadata observation. A guest's reported executable is
    never used to infer a permitted image entrypoint. *)
type platform = { architecture : string; os : string; variant : string option }
type identity = { descriptor_digest : string; platform : platform }
type t
type error =
  | Invalid_inspect of string
  | Reference_mismatch
  | Descriptor_mismatch
  | Platform_absent
  | Platform_ambiguous

val of_apple_inspect : reference:string -> identity:identity -> string -> (t, error) result
(** The caller must capture an actual CLI inspection of [reference]. Requires
    exactly one image row with the guest's observed descriptor and exactly one
    variant for its exact platform. The CLI's canonical stored name may differ
    from the requested alias; image content, not string normalization, binds it.
    Optional OCI execution config or Entrypoint absent/null means no prefix,
    as does an empty Entrypoint array. Malformed values refuse.
    OCI Cmd is not appended because Keeper passes an explicit command. *)
val command : t -> arguments:string list -> string list
val validate_binding : t -> reference:string -> identity:identity -> (unit, error) result
(** Prevents reusing a metadata observation for another request or guest image. *)
val error_message : error -> string

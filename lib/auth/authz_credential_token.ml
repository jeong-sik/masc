(* HIGH-RISK-UNREVIEWED: see the interface. *)

module type DIGEST = sig
  type t

  val of_hex : string -> t option
  val to_hex : t -> string
  val equal : t -> t -> bool
end

module type S = sig
  type id

  module Digest : DIGEST

  type t

  val prefix : string
  val digest_label : string
  val id : t -> id
  val secret_digest : t -> Digest.t
  val draw : id -> t
  val to_string : t -> string
end

let secret_bytes = 32
let secret_length = 2 * secret_bytes

let is_lower_hex = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false
;;

module type KIND = sig
  module Id : Authz_id.S

  val prefix : string
  val digest_label : string
end

(* [of_string] is outside [S]: [read] is the one way in, so a text is read
   against both prefixes and the same rules. *)
module Make (K : KIND) : sig
  include S with type id = K.Id.t

  val of_string : string -> t option
end = struct
  type id = K.Id.t

  module Digest = struct
    type t = string

    let hex_length = Agent_core_sha256.digest_size * 2

    let of_hex s =
      if String.length s = hex_length && String.for_all is_lower_hex s then Some s else None
    ;;

    let to_hex t = t
    let equal = Eqaf.equal
  end

  type t =
    { id : id
    ; secret : string
    }

  let prefix = K.prefix
  let digest_label = K.digest_label
  let id t = t.id

  let secret_digest t =
    Agent_core_sha256.to_hex (Agent_core_sha256.digest_string (digest_label ^ t.secret))
  ;;

  let draw id = { id; secret = Random_id.hex ~bytes:secret_bytes }
  let to_string t = prefix ^ K.Id.to_string t.id ^ "." ^ t.secret

  (* [text] is what follows the prefix. *)
  let of_string text =
    let length = String.length text in
    (* At least one byte of id, the dot, and the secret. *)
    if length < secret_length + 2 || not (Char.equal text.[length - secret_length - 1] '.')
    then None
    else (
      let secret = String.sub text (length - secret_length) secret_length in
      if not (String.for_all is_lower_hex secret)
      then None
      else (
        match K.Id.of_string (String.sub text 0 (length - secret_length - 1)) with
        | Ok id -> Some { id; secret }
        | Error (_ : Authz_id.error) -> None))
  ;;
end

module Pat = Make (struct
    module Id = Authz_types.Pat_id

    let prefix = "mpat_"
    let digest_label = "masc-authz-pat-secret-v1\n"
  end)

module Service_credential = Make (struct
    module Id = Authz_types.Service_credential_id

    let prefix = "msvc_"
    let digest_label = "masc-authz-service-credential-secret-v1\n"
  end)

type reading =
  | Pat_token of Pat.t
  | Service_credential_token of Service_credential.t
  | Pat_malformed
  | Service_credential_malformed
  | No_prefix

let after ~prefix text =
  String.sub text (String.length prefix) (String.length text - String.length prefix)
;;

let read text =
  if String.starts_with ~prefix:Pat.prefix text
  then (
    match Pat.of_string (after ~prefix:Pat.prefix text) with
    | Some token -> Pat_token token
    | None -> Pat_malformed)
  else if String.starts_with ~prefix:Service_credential.prefix text
  then (
    match Service_credential.of_string (after ~prefix:Service_credential.prefix text) with
    | Some token -> Service_credential_token token
    | None -> Service_credential_malformed)
  else No_prefix
;;

(* RFC-0070 Phase 3b-i — Hash algorithm variant impl. See .mli. *)

type t =
  | SHA_256
  | SHA_512
[@@deriving show, eq]

let all = [ SHA_256; SHA_512 ]

let to_string = function
  | SHA_256 -> "sha256"
  | SHA_512 -> "sha512"

let of_string s =
  match String.lowercase_ascii s with
  | "sha256" | "sha-256" | "sha_256" -> Some SHA_256
  | "sha512" | "sha-512" | "sha_512" -> Some SHA_512
  | _ -> None

let digest_hex algo s =
  match algo with
  | SHA_256 -> Digestif.SHA256.(digest_string s |> to_hex)
  | SHA_512 -> Digestif.SHA512.(digest_string s |> to_hex)

let digest_bytes algo s =
  match algo with
  | SHA_256 -> Digestif.SHA256.(digest_string s |> to_raw_string)
  | SHA_512 -> Digestif.SHA512.(digest_string s |> to_raw_string)

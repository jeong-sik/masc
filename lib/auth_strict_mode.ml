(** See [auth_strict_mode.mli] for the contract. *)

type t = Off | Dry_run | Strict

let to_label = function
  | Off -> "off"
  | Dry_run -> "dry_run"
  | Strict -> "strict"

let of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "off" | "0" | "false" -> Off
  | "strict" | "1" | "true" -> Strict
  | "dry_run" | "dry-run" | "" -> Dry_run
  | _ -> Dry_run

let current () =
  match Sys.getenv_opt "MASC_AUTH_STRICT" with
  | None -> Dry_run
  | Some raw -> of_string raw

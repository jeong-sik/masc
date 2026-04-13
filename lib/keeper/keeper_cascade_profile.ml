(** See {!Keeper_cascade_profile} interface for rationale. *)

let default_name = "keeper_unified"

let canonicalize (raw : string) : string =
  let trimmed = String.trim raw in
  match String.lowercase_ascii trimmed with
  | "" -> default_name
  | "keeper_unified"
  | "oas-keeper_unified"
  | "coding_first"
  | "oas-coding_first" -> default_name
  | _ -> trimmed

let models_key name = canonicalize name ^ "_models"
let temperature_key name = canonicalize name ^ "_temperature"
let max_tokens_key name = canonicalize name ^ "_max_tokens"

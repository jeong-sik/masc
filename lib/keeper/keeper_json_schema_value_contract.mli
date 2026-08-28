(** Pure, opt-in validation of known JSON values against the JSON Schema
    vocabulary used by Keeper tool input descriptors. This module does not
    change runtime or handler validation ownership. *)

type detail =
  { path : string list
  ; keyword : string
  ; expected : Yojson.Safe.t
  ; actual : Yojson.Safe.t
  }

type error =
  | Unsupported_schema of detail
  | Invalid_schema of detail
  | Value_mismatch of detail

val validate_schema : Yojson.Safe.t -> (unit, error) result

val validate
  :  schema:Yojson.Safe.t
  -> Yojson.Safe.t
  -> (unit, error) result

val error_to_json : error -> Yojson.Safe.t

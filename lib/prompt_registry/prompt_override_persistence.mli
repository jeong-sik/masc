(** Versioned persistence for prompt overrides.

    An entry records what the operator wrote and what they wrote it against:
    the digest of the default body at the time ([authored_against]) and the
    template-variable contract the prompt declared then
    ([template_variables]). Neither is a gate. The registry applies a saved
    override whenever it still renders under the prompt's current contract,
    and uses these two fields only to say that the default moved underneath
    it since it was written. A release that rewrites a default body leaves
    the operator's prompt in force. *)

type entry = {
  key : string;
  value : string;
  authored_against : string;
      (** {!default_revision} of the default body the override replaced when
          it was saved. *)
  template_variables : string list;
      (** The prompt's declared template variables when the override was
          saved, sorted. *)
}

type error =
  | Invalid_json of string
  | Read_failed of string
  | Write_failed of string
  | Expected_object of string
  | Expected_list of string
  | Expected_integer of string
  | Expected_string of string
  | Duplicate_field of {
      location : string;
      field : string;
    }
  | Missing_field of {
      location : string;
      field : string;
    }
  | Unexpected_field of {
      location : string;
      field : string;
    }
  | Unsupported_schema_version of {
      expected : int;
      actual : int;
    }
      (** The file's envelope is in a schema version this build does not
          read. A caller that knows how the operator gets the data back in
          the current format says so with this case. *)
  | Duplicate_override_key of string

val default_revision : body:string -> string
(** SHA256 hex of the default body. Stored as [authored_against] and
    compared against the current body to report that the default moved. *)

val load : path:string -> (entry list, error) result
(** Decode the versioned persistence envelope at [path]. Bare maps, other
    schema versions, malformed field types, duplicate JSON fields, and
    duplicate override keys are rejected as typed errors. *)

val save : path:string -> entry list -> (unit, error) result
(** Atomically replace [path] with the canonical versioned envelope. *)

val error_to_string : error -> string

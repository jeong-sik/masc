(** Typed resolution of TOML fields. [Field_resolution.t] keeps absence and
    malformed values structurally distinct:

    {ul
    {- [Present v] — the key exists and parsed cleanly with the
       requested accessor.}
    {- [Missing] — the key is not present in the TOML object.}
    {- [Type_mismatch { path; expected; message }] — the key exists
       but its TOML value is not the requested type.}}
    Callers decide whether absence is valid for their schema. *)

(** Outcome of resolving an optional TOML field at a given path. *)
type 'a t =
  | Present of 'a
  | Missing
  | Type_mismatch of {
      path : string list;
      expected : string;
      message : string;
    }

(** [resolve_string toml path] reads [path] from [toml] and requires
    the value to be a TOML string. *)
val resolve_string : Otoml.t -> string list -> string t

(** [resolve_bool toml path] reads [path] and requires a boolean. *)
val resolve_bool : Otoml.t -> string list -> bool t

(** [resolve_int toml path] reads [path] and requires a TOML integer.
    The value is returned as a native OCaml [int]; values too wide for
    the host architecture surface as [Type_mismatch]. *)
val resolve_int : Otoml.t -> string list -> int t

(** [resolve_strings toml path] reads [path] and requires the value
    to be a TOML array of strings (i.e. [["a"; "b"]]). A non-array
    or an array containing a non-string entry surfaces as
    [Type_mismatch]. *)
val resolve_strings : Otoml.t -> string list -> string list t

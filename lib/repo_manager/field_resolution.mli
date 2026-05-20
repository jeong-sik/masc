(** Typed resolution of optional TOML fields.

    Closes the silent-failure shape

    {[
      match Otoml.find_result toml accessor (path field) with
      | Ok value -> Ok value
      | Error _  -> Ok default
    ]}

    that appears at ten call sites in [lib/repo_manager/] (audit
    2026-05-20, RFC-0141). The legacy shape collapses two unrelated
    Otoml errors into one branch:

    - the field is not present in the table (caller wants the default), and
    - the field is present but carries a wrong type (the [repositories.toml]
      or [credentials.toml] is malformed, caller should propagate).

    [Field_resolution.t] keeps the two cases structurally distinct:

    {ul
    {- [Present v] — the key exists and parsed cleanly with the
       requested accessor.}
    {- [Missing] — the key is not present in the TOML object (a
       legitimate "no value" outcome, expected for optional fields).}
    {- [Type_mismatch { path; expected; message }] — the key exists
       but its TOML value is not the requested type. Today this is
       silenced into [Ok default]; here it is preserved so the
       caller can choose to propagate the schema violation as an
       error instead of substituting a (possibly inconsistent) default.}}

    Two caller-side helpers cover the common shapes used by
    [repo_store.ml] and [credential_store.ml]:

    {ul
    {- [or_default ~default] substitutes [default] for [Missing]
       only and propagates [Type_mismatch] as [Error]. Use when
       the field is optional but a wrong type means the config
       file is corrupt and must not load with a synthetic value.}
    {- [require] turns both [Missing] and [Type_mismatch] into
       [Error]. Use for required fields where any non-[Present]
       outcome is a programmer error.}}

    See RFC-0141 §3 for the migration plan and RFC-0088 §3 for the
    silent-failure anti-pattern this module closes. *)

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

(** [or_default ~default r] substitutes [default] for [Missing] and
    propagates [Type_mismatch] as [Error]. The error message names
    the path so the operator can locate the offending key. *)
val or_default : default:'a -> 'a t -> ('a, string) result

(** [require r] turns both [Missing] and [Type_mismatch] into
    [Error]. Use for required fields. *)
val require : 'a t -> ('a, string) result

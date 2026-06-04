(** Typed extraction from [Yojson.Safe.t] with explicit shape-mismatch
    diagnostics.

    Replaces the ad-hoc [| `String s -> Some s | _ -> None] catch-all
    pattern at JSON boundaries. The wildcard arm is correct on the
    happy path but silently swallows {i schema drift} — an upstream
    payload that changed shape (e.g. [`String _] became [`Assoc _])
    disappears as [None] with no operator-visible signal.

    This module makes the three outcomes structurally distinct so the
    caller can decide what to do about each:

    {ul
    {- [Found v] — the field is present and matches the requested
       OCaml type.}
    {- [Field_absent] — the field is not present in the object
       (i.e. either the object lacks the key, or the input is not an
       [`Assoc] at all). The caller almost always wants to treat
       this as "no value".}
    {- [Wrong_shape { expected; got }] — the field is present but
       carries a different JSON variant than asked for. This is the
       interesting case: today it disappears into [None]; here it
       is preserved with both the expected OCaml-side type and the
       actual JSON variant name.}}

    Two helpers cover the most common migration shapes:

    {ul
    {- [to_option] discards the [Wrong_shape] diagnostic. Use at
       call sites whose surrounding logic already accepts "no value"
       semantics — the behavior is identical to the legacy
       catch-all, only the typing is tighter.}
    {- [log_wrong_shape] adds a [Log.Misc.warn] line on
       [Wrong_shape] before discarding it. Use where schema drift
       in upstream payloads should be operator-visible without
       aborting the calling path.}}

    See RFC-0142 §3 Phase 1 for the migration plan and RFC-0088 §3.5
    for the catch-all anti-pattern this module closes. *)

(** Result of a typed JSON field extraction. *)
type 'a extraction =
  | Found of 'a
  | Field_absent
  | Wrong_shape of { expected : string; got : string }
    (** [expected] names the requested OCaml-side type ("string",
        "int", "bool", "list", "assoc"). [got] names the JSON
        variant actually encountered ("null", "bool", "int",
        "intlit", "float", "string", "list", "assoc"). *)

(** [string json key] reads [key] from [json] (which must be an
    [`Assoc]) and requires the value to be a [`String]. *)
val string : Yojson.Safe.t -> string -> string extraction

(** [int json key] reads [key] and accepts [`Int] only.
    JSON integers wider than OCaml's [int] are reported as
    [Wrong_shape] with [got = "intlit"]. *)
val int : Yojson.Safe.t -> string -> int extraction

(** [bool json key] reads [key] and accepts [`Bool] only. *)
val bool : Yojson.Safe.t -> string -> bool extraction

(** [float json key] reads [key] and accepts both [`Float f] and
    [`Int i] (returning [float_of_int i]). Mixed numeric input is
    a JSON-on-the-wire reality, not schema drift. *)
val float : Yojson.Safe.t -> string -> float extraction

(** [assoc json key] reads [key] and accepts [`Assoc fields]. *)
val assoc : Yojson.Safe.t -> string -> (string * Yojson.Safe.t) list extraction

(** [list json key] reads [key] and accepts [`List items]. *)
val list : Yojson.Safe.t -> string -> Yojson.Safe.t list extraction

(** [to_option r] collapses both [Field_absent] and [Wrong_shape]
    into [None]. Use for mechanical replacement of the legacy
    [| _ -> None] catch-all where the caller already swallows
    schema drift. *)
val to_option : 'a extraction -> 'a option

(** [log_wrong_shape ~label r] is [to_option r] plus a
    [Log.Misc.warn] line on the [Wrong_shape] branch.
    [label] identifies the call site in the log
    (e.g. ["tool_called_detail_from_fields"]). *)
val log_wrong_shape : label:string -> 'a extraction -> 'a option

(** [require r] turns both [Field_absent] and [Wrong_shape] into
    [Error msg] with a human-readable diagnostic. Use at strict
    boundaries (e.g. config parsing) where missing or malformed
    fields are programmer errors, not silent defaults. *)
val require : 'a extraction -> ('a, string) result

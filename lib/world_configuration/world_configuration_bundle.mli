(** Full authored world declarations, independent of runtime metadata.

    This format retains complete Keeper TOML and Runtime TOML bytes and the
    versioned durable override envelope. Source locations describe where a
    capture came from; they never authorize an import destination.

    A validated bundle proves document syntax, strict Keeper profiles,
    override schema and retained digests. It does not prove a coherent live
    capture, receiver dependency availability, installation or activation.
    Callers must keep those observations separate. Serialized bodies may
    contain confidential authored configuration; do not log them. *)

type source = private { content : string; sha256 : string }
type keeper = private { name : string; declaration : source }
type origin = { base_path : string; config_root : string }

type t = private
  { origin : origin
  ; runtime : source option
  ; overrides : source option
  ; keepers : keeper list
  }
(** [None] records an absent document. It never means that an unreadable
    document was omitted. Keeper names are canonical filename stems; source
    order is preserved. Explicit false/empty/missing declarations remain in
    the original document bytes. *)

type document = Runtime | Overrides | Keeper of string
type error =
  | Invalid_json of string
  | Invalid_envelope of string
  | Unsupported_version of int
  | Invalid_keeper_name of string
  | Duplicate_keeper of string
  | Invalid_document of { document : document; detail : string }
  | Digest_mismatch of document

val make :
  origin:origin ->
  runtime:string option ->
  overrides:string option ->
  keepers:(string * string) list ->
  (t, error) result
(** Validate captured documents without reading their source paths. Runtime
    validation here is TOML syntax, not receiver materialization. Keeper
    profiles use the existing strict declaration validator, including filename
    identity and instructions. Every supplied
    document either survives unchanged or makes the whole bundle an error. *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, error) result
val of_string : string -> (t, error) result
val to_string : t -> string
(** The versioned envelope rejects duplicate, missing and unknown fields,
    duplicate Keeper names, invalid declarations and incorrect digests. *)

val summary_to_yojson : t -> Yojson.Safe.t
(** Origin, document presence, Keeper names and digests, without document
    contents. Does not claim dependency readiness or import completion. *)

val error_to_string : error -> string

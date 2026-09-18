(* Distinguishing opaque identifiers for the three string meanings that
   historically shared one slot (board note p-565b55be, task-1618; the
   #37009 class of slot mix-ups).  The types are mutually incompatible on
   purpose: passing an [Api_name.t] where a [Model_id.t] is expected fails
   at compile time.

   [of_string] enforces the same invariants the TOML loaders enforce
   (non-empty, no leading or trailing whitespace) and returns the unchanged
   bytes.  [equal] applies the historical comparison-time normalization
   (ASCII case-fold + trim) and never rewrites stored bytes — the original
   string is preserved for display.  [to_string] is the boundary escape
   hatch (TUI rows, JSON/TOML wire, logs). *)

(* Representations live here (plain strings); opacity is imposed by the
   .mli, so the three types stay mutually incompatible for callers. *)
type id_prefix = string

type api_name = string

type model_id = string

module Id_prefix : sig
  type t = id_prefix

  val of_string : string -> (t, string) result
  (** [Error message] mirrors the model-catalog loader messages byte for
      byte: [model entry field "id_prefix" must not be empty] and
      [model entry field "id_prefix" must not have leading or trailing
      whitespace]. *)

  val of_string_exn : string -> t
  (** Same invariants as {!of_string}; raises [Invalid_argument] on
      violation (programmer error in test builders and fixtures). *)

  val equal : t -> t -> bool
  (** Comparison-time normalization (ASCII case-fold + trim); stored bytes
      are never rewritten. *)

  val starts_with : prefix:t -> t -> bool
  (** Prefix matching with the same comparison-time normalization as
      [equal] (ASCII case-fold + trim on both sides); the only sanctioned
      prefix comparison on [t]. *)

  val to_string : t -> string
  (** The original, unnormalized bytes. *)
end = struct
  type t = id_prefix

  let of_string raw =
    let trimmed = String.trim raw in
    if trimmed = ""
    then Error "model entry field \"id_prefix\" must not be empty"
    else if raw <> trimmed
    then
      Error "model entry field \"id_prefix\" must not have leading or trailing whitespace"
    else Ok raw
  ;;

  let of_string_exn raw =
    match of_string raw with
    | Ok value -> value
    | Error message -> invalid_arg ("Model_identifiers.Id_prefix: " ^ message)
  ;;

  let equal a b =
    String.equal
      (String.lowercase_ascii (String.trim a))
      (String.lowercase_ascii (String.trim b))
  ;;

  let starts_with ~prefix t =
    String.starts_with
      ~prefix:(String.lowercase_ascii (String.trim prefix))
      (String.lowercase_ascii (String.trim t))
  ;;

  let to_string t = t
end

module Api_name : sig
  type t = api_name

  val of_string : string -> (t, string) result
  (** Same invariants as {!Id_prefix.of_string}; messages are neutral
      ([api_name must not be empty] / [api_name must not have leading or
      trailing whitespace]) until a loader moves its validation here. *)

  val of_string_exn : string -> t
  (** Same invariants as {!of_string}; raises [Invalid_argument] on
      violation (programmer error in test builders and fixtures). *)

  val equal : t -> t -> bool
  (** Comparison-time normalization (ASCII case-fold + trim). *)

  val to_string : t -> string
end = struct
  type t = api_name

  let of_string raw =
    let trimmed = String.trim raw in
    if trimmed = ""
    then Error "api_name must not be empty"
    else if raw <> trimmed
    then Error "api_name must not have leading or trailing whitespace"
    else Ok raw
  ;;

  let of_string_exn raw =
    match of_string raw with
    | Ok value -> value
    | Error message -> invalid_arg ("Model_identifiers.Api_name: " ^ message)
  ;;

  let equal a b =
    String.equal
      (String.lowercase_ascii (String.trim a))
      (String.lowercase_ascii (String.trim b))
  ;;

  let to_string t = t
end

module Model_id : sig
  type t = model_id

  val of_string : string -> (t, string) result
  (** Same invariants as {!Id_prefix.of_string}; messages are neutral
      ([model_id must not be empty] / [model_id must not have leading or
      trailing whitespace]) until a loader moves its validation here. *)

  val of_string_exn : string -> t
  (** Same invariants as {!of_string}; raises [Invalid_argument] on
      violation (programmer error in test builders and fixtures). *)

  val equal : t -> t -> bool
  (** Comparison-time normalization (ASCII case-fold + trim). *)

  val to_string : t -> string
end = struct
  type t = model_id

  let of_string raw =
    let trimmed = String.trim raw in
    if trimmed = ""
    then Error "model_id must not be empty"
    else if raw <> trimmed
    then Error "model_id must not have leading or trailing whitespace"
    else Ok raw
  ;;

  let of_string_exn raw =
    match of_string raw with
    | Ok value -> value
    | Error message -> invalid_arg ("Model_identifiers.Model_id: " ^ message)
  ;;

  let equal a b =
    String.equal
      (String.lowercase_ascii (String.trim a))
      (String.lowercase_ascii (String.trim b))
  ;;

  let to_string t = t
end

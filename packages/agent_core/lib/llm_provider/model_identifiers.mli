(* Distinguishing opaque identifiers for the three string meanings that
   historically shared one slot (board note p-565b55be, task-1618; the
   #37009 class of slot mix-ups).  The types are mutually incompatible on
   purpose: passing an [Api_name.t] where a [Model_id.t] is expected fails
   at compile time.

   [of_string] enforces the same invariants the TOML loaders enforce
   (non-empty, no leading or trailing whitespace) and returns the
   input bytes unchanged, so [to_string (of_string x) = x].  The
   spelling belongs to the outside system (models.toml:2870), so it is
   never rewritten; case-insensitive matching is done by [equal],
   [Id_prefix.starts_with], and [Model_id.starts_with], which fold ASCII case.
   [to_string] is the boundary escape hatch (TUI rows, JSON/TOML wire, logs)
   and returns the original bytes. *)

module Id_prefix : sig
  type t
  (** The catalog row [id_prefix] — the row's original bytes. *)

  val of_string : string -> (t, string) result
  (** [Error message] mirrors the model-catalog loader messages byte for
      byte: [model entry field "id_prefix" must not be empty] and
      [model entry field "id_prefix" must not have leading or trailing
      whitespace].  Success returns the input bytes unchanged. *)

  val of_string_exn : string -> t
  (** Same invariants as {!of_string}; raises [Invalid_argument] on
      violation (programmer error in test builders and fixtures). *)

  val equal : t -> t -> bool
  (** Case-insensitive equality (ASCII case folded); no trim, since
      {!of_string} rejects padded input. *)

  val starts_with : prefix:t -> t -> bool
  (** Prefix matching between catalog identifiers, e.g. wizard client gating
      on [claude-] / [gpt-]. ASCII case is folded on both sides. *)

  val to_string : t -> string
  (** The original bytes, verbatim. *)
end

module Api_name : sig
  type t
  (** The runtime [api-name] — the configured bytes, verbatim. *)

  val of_string : string -> (t, string) result
  (** Same invariants as {!Id_prefix.of_string}; messages are neutral
      ([api_name must not be empty] / [api_name must not have leading or
      trailing whitespace]) until a loader moves its validation here.
      Success returns the input bytes unchanged. *)

  val of_string_exn : string -> t
  (** Same invariants as {!of_string}; raises [Invalid_argument] on
      violation (programmer error in test builders and fixtures). *)

  val equal : t -> t -> bool
  (** Case-insensitive equality (ASCII case folded); no trim, since
      {!of_string} rejects padded input. *)

  val to_string : t -> string
  (** The original bytes, verbatim. *)
end

module Model_id : sig
  type t
  (** The exact-output resolve target [model_id] — the configured
      bytes, verbatim. *)

  val of_string : string -> (t, string) result
  (** Same invariants as {!Id_prefix.of_string}; messages are neutral
      ([model_id must not be empty] / [model_id must not have leading or
      trailing whitespace]) until a loader moves its validation here.
      Success returns the input bytes unchanged. *)

  val of_string_exn : string -> t
  (** Same invariants as {!of_string}; raises [Invalid_argument] on
      violation (programmer error in test builders and fixtures). *)

  val equal : t -> t -> bool
  (** Case-insensitive equality (ASCII case folded); no trim, since
      {!of_string} rejects padded input. *)

  val equal_id_prefix : prefix:Id_prefix.t -> t -> bool
  (** Exact comparison with a catalog row identifier. ASCII case is folded;
      neither side is trimmed. *)

  val starts_with : prefix:Id_prefix.t -> t -> bool
  (** Prefix matching between a catalog row and a requested model id.
      ASCII case is folded on both sides. Escaping through
      {!Id_prefix.to_string} to run [String.starts_with] is a review flag. *)

  val to_string : t -> string
  (** The original bytes, verbatim. *)
end

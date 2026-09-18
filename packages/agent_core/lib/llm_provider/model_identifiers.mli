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

type id_prefix (** Catalog row prefix — TOML [models.*] [id_prefix]. *)

type api_name (**
   Runtime model name — [runtime.toml] [models.NAME] [api-name]. *)

type model_id (**
   Exact-output resolve target — the [model_id] argument of
   {!Exact_output_catalog_binding.resolve_exact}. *)

module Id_prefix : sig
  type t = id_prefix
  (** The catalog row [id_prefix]. *)

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

  val to_string : t -> string
  (** The original, unnormalized bytes. *)
end

module Api_name : sig
  type t = api_name
  (** The runtime [api-name]. *)

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
end

module Model_id : sig
  type t = model_id
  (** The exact-output resolve target [model_id]. *)

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
end

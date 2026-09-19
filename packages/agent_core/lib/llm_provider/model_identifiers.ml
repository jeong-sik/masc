(* Distinguishing opaque identifiers for the three string meanings that
   historically shared one slot (board note p-565b55be, task-1618; the
   #37009 class of slot mix-ups).  The types are mutually incompatible on
   purpose: passing an [Api_name.t] where a [Model_id.t] is expected fails
   at compile time.  That incompatibility is imposed by the .mli — each
   module exports an abstract [t] — exactly as in the first round; the
   functor below owns the shared rule so the three hand-copied bodies
   cannot drift apart.  The functor result is deliberately left concrete
   ([t = string] stays visible inside this file) because [Id_prefix] has
   to define [starts_with] on those bytes; sealing the result at a
   signature would abstract [t] here too and no prefix rule could be
   written.  Callers never see the concrete form.

   A [t] stores the producer's bytes verbatim: [of_string] enforces the
   same invariants the TOML loaders enforce (non-empty, no leading or
   trailing whitespace) and returns the input unchanged.  The spelling
   is a contract with the outside system (models.toml:2870 is a
   HuggingFace path whose mixed case is the name ollama knows), so
   normalizing at storage would be irreversible.  Case-insensitive
   matching lives at the comparison edge: [equal], [starts_with], and
   [matches_model_id] fold ASCII case. No trim there — [of_string] already
   rejects padded input. [to_string] is the boundary escape hatch (TUI rows,
   JSON/TOML wire, logs) and returns the original bytes, so
   [to_string (of_string x) = x]. *)

module type LABELS = sig
  val empty : string
  val padded : string
  val label : string
end

(* One rule, three instances.  The abstract [t] each caller sees comes
   from the .mli, not from here. *)
module Make (L : LABELS) = struct
  type t = string

  let of_string raw =
    let trimmed = String.trim raw in
    if String.equal trimmed "" then Error L.empty
    else if not (String.equal raw trimmed) then Error L.padded
    else Ok raw
  ;;

  let of_string_exn raw =
    match of_string raw with
    | Ok value -> value
    | Error message -> invalid_arg (L.label ^ ": " ^ message)
  ;;

  let equal a b =
    String.equal (String.lowercase_ascii a) (String.lowercase_ascii b)
  ;;

  let to_string t = t
end

module Model_id =
  Make (struct
      let empty = "model_id must not be empty"

      let padded = "model_id must not have leading or trailing whitespace"

      let label = "Model_identifiers.Model_id"
    end)

module Id_prefix = struct
  include
    Make (struct
        let empty = "model entry field \"id_prefix\" must not be empty"

        let padded =
          "model entry field \"id_prefix\" must not have leading or trailing whitespace"

        let label = "Model_identifiers.Id_prefix"
      end)

  let starts_with_bytes ~prefix value =
    String.starts_with
      ~prefix:(String.lowercase_ascii prefix)
      (String.lowercase_ascii value)
  ;;

  let starts_with ~prefix t = starts_with_bytes ~prefix t
  let matches_model_id ~prefix model_id = starts_with_bytes ~prefix model_id
end

module Api_name =
  Make (struct
      let empty = "api_name must not be empty"

      let padded = "api_name must not have leading or trailing whitespace"

      let label = "Model_identifiers.Api_name"
    end)

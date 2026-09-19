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

   [of_string] enforces the same invariants the TOML loaders enforce
   (non-empty, no leading or trailing whitespace) and returns the
   normalized form (ASCII lowercase).  Normalization lives at
   construction, not at comparison: every [t] is already normalized, so
   [equal] and [starts_with] are plain byte comparisons and a [t] works
   as a [Hashtbl] key with no separate key function.  The bytes a row or
   a provider wrote are not preserved — display that needs the original
   spelling must source it from the row itself, not from the identifier.
   [to_string] is the boundary escape hatch (TUI rows, JSON/TOML wire,
   logs) and returns the normalized bytes. *)

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
    else Ok (String.lowercase_ascii raw)
  ;;

  let of_string_exn raw =
    match of_string raw with
    | Ok value -> value
    | Error message -> invalid_arg (L.label ^ ": " ^ message)
  ;;

  let equal = String.equal

  let to_string t = t
end

module Id_prefix = struct
  include
    Make (struct
        let empty = "model entry field \"id_prefix\" must not be empty"

        let padded =
          "model entry field \"id_prefix\" must not have leading or trailing whitespace"

        let label = "Model_identifiers.Id_prefix"
      end)

  let starts_with ~prefix t = String.starts_with ~prefix t
end

module Api_name =
  Make (struct
      let empty = "api_name must not be empty"

      let padded = "api_name must not have leading or trailing whitespace"

      let label = "Model_identifiers.Api_name"
    end)

module Model_id =
  Make (struct
      let empty = "model_id must not be empty"

      let padded = "model_id must not have leading or trailing whitespace"

      let label = "Model_identifiers.Model_id"
    end)

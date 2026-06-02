(* Cycle 20 / Tier I8 tests — [@@deriving tla] on GADT variants.

   Tier I8 scope (this PR): the deriver detects GADT constructors via
   [pcd_res <> None] and handles the 0-type-parameter case. 0-param GADT
   shapes structurally like a regular variant, so the deriver emits
   [to_tla_symbol] and [all_symbols] but suppresses [all_states] (GADT
   constructors with explicit result types may not be list-constructed
   uniformly).

   {b Deferred to a follow-up tier} (I8b / I9): 1+ type-parameter GADT
   existentials such as [type 'a any = Any_X : x_phantom any | ...].
   Emitting [let to_tla_symbol : type a. a t -> string = function ...]
   via ppxlib AST builders requires a three-piece AST (ptyp_poly +
   pexp_newtype + inner pexp_constraint) whose interaction with OCaml
   5.4's scoped-type rules is non-trivial. For lib/autonomous/'s small
   number of GADT existentials, hand-writing [to_tla_symbol_any] is
   the recommended workaround until the follow-up tier lands. *)

(* ─── 0 type-param GADT (supported by I8) ────────────────────────── *)

module Tagged_nullary = struct
  type t =
    | A : t
    | B : t
    | C : t
  [@@deriving tla]
end

let test_tagged_nullary_to_tla_symbol () =
  assert (Tagged_nullary.to_tla_symbol Tagged_nullary.A = "a");
  assert (Tagged_nullary.to_tla_symbol Tagged_nullary.B = "b");
  assert (Tagged_nullary.to_tla_symbol Tagged_nullary.C = "c")

let test_tagged_nullary_all_symbols () =
  assert (Tagged_nullary.all_symbols = [ "a"; "b"; "c" ])

(* ─── 0-param GADT with [@tla.symbol] override ──────────────────── *)

module Tagged_with_override = struct
  type t =
    | Foo : t [@tla.symbol "alpha"]
    | Bar : t [@tla.symbol "beta"]
    | Baz : t
  [@@deriving tla]
end

let test_tagged_with_override () =
  assert (Tagged_with_override.to_tla_symbol Tagged_with_override.Foo = "alpha");
  assert (Tagged_with_override.to_tla_symbol Tagged_with_override.Bar = "beta");
  assert (Tagged_with_override.to_tla_symbol Tagged_with_override.Baz = "baz");
  assert
    (Tagged_with_override.all_symbols = [ "alpha"; "beta"; "baz" ])

(* ─── 0-param GADT with payload-bearing constructors (parameterised
   constructor body, not type parameters) ──────────────────────────── *)

module Tagged_payload = struct
  type t =
    | Simple : t
    | With_int : int -> t
    | With_string : string -> t
  [@@deriving tla]
end

let test_tagged_payload () =
  assert (Tagged_payload.to_tla_symbol Tagged_payload.Simple = "simple");
  assert (Tagged_payload.to_tla_symbol (Tagged_payload.With_int 42) = "with_int");
  assert
    (Tagged_payload.to_tla_symbol (Tagged_payload.With_string "x") = "with_string");
  assert
    (Tagged_payload.all_symbols
     = [ "simple"; "with_int"; "with_string" ])

let () =
  test_tagged_nullary_to_tla_symbol ();
  test_tagged_nullary_all_symbols ();
  test_tagged_with_override ();
  test_tagged_payload ();
  print_endline "test_gadt: all assertions passed"

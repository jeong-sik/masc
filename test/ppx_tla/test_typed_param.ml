(* RFC-0054 PR-1 / Tier I8b — investigation evidence.

   This file is intentionally NOT registered in test/ppx_tla/dune.
   It documents the empirical OCaml 5.4 / ppxlib AST inequivalence
   that blocks straightforward [@@deriving tla] generalisation to
   non-phantom N-parameter GADT existentials.

   Background (RFC-0054 §1, §5.3):
     ppx_tla.ml currently raises an explicit error for
       type (_, _) edge =
         | E1 : (unit, string) edge
         | E2 : (string, unit) edge
       [@@deriving tla]
     because emitting [let f : type a b. … = function …] via ppxlib
     [Ast_builder.Default] hit "non-trivial" interaction with OCaml
     5.4 scoped-type rules in a previous attempt.

   Investigation findings (2026-05-09 PR-1 attempt):

   1. Generalising [make_to_tla_symbol_impl_gadt_one_param] to N
      parameters via the natural pattern (List.fold_right over
      pexp_newtype, ptyp_poly with N univ vars, pexp_constraint with
      ptyp_constr (Lident var) []) produces an AST whose
      pretty-printed form matches working hand-written OCaml
      byte-for-byte. Yet the generated AST fails the typechecker
      with:
        Error: This pattern matches values of type (string, unit) edge
               but a pattern was expected which matches values of type
                 (unit, string) edge

   2. The hand-written equivalent compiles and runs cleanly:
        let to_sym : 'a 'b. ('a, 'b) edge -> string =
          fun (type pa) -> fun (type pb) ->
            fun (arg : (pa, pb) edge) ->
              match arg with
              | E1 -> "e1"
              | E2 -> "e2"

   3. Extracting the dumped source from the failing AST and feeding
      it to [ocaml] directly compiles AND runs. So the generated
      *text* is valid OCaml, but the *AST node tree* ppxlib produces
      contains some metadata or location-attribute that diverges
      from what the parser produces for the same source — and that
      divergence triggers GADT narrowing.

   Diagnosis attempts that did NOT resolve the issue (PR-1):
   - Disjoint universal vs locally-abstract names ('a vs pa).
   - Dropping the outer ptyp_poly and relying on inference.
   - Replacing pexp_constraint on the function with a typed
     argument pattern (ppat_constraint).

   None of these produced a working deriver for N ≥ 2.

   Path forward (proposed RFC-0054 amendment):

   Two viable workaround tracks. Both deferred to a separate PR:

   A. Source-template approach. Use [Ppxlib.Parse.expression] on a
      hand-written template string with type-name + constructor-list
      placeholders. Brittle (escaping, hygiene) but guaranteed to
      match what the parser produces.

   B. ppxlib internals approach. Investigate Astlib / Migrate
      transforms to discover which Parsetree node attribute the
      source path attaches that the Ast_builder path omits.
      Requires deep ppxlib knowledge.

   Until one of those lands, [@@deriving tla] continues to raise
   the existing "not yet supported" error for non-phantom N-param
   GADT existentials. shell_ir_typed.ml's hand-written walkers stay.

   This file remains in the tree as a regression marker — when
   Tier I8b lands, the body below should compile under [@@deriving tla]
   and the file gets registered in dune. *)

(* ─── 2-parameter non-phantom GADT (the smallest I8b case) ──────────
   Currently raises:
     [@@deriving tla]: GADT existential with type parameters is not yet
     supported. Add [@@tla.phantom_param] if the type parameters are
     phantom (not specialised in constructor bodies). Otherwise,
     hand-write to_tla_symbol_any for this type. *)

(*
module Two_param = struct
  type (_, _) edge =
    | E_a_to_b : (unit, string) edge
    | E_b_to_a : (string, unit) edge
    | E_self : (int, int) edge
  [@@deriving tla]
end
*)

(* ─── 4-parameter non-phantom GADT (shell_ir_typed shape) ──────────
   The end goal of RFC-0054. Mirrors lib/exec/shell_ir_typed.ml's
   ('input, 'output, 'risk, 'sandbox) command. *)

(*
module Four_param = struct
  type (_, _, _, _) command =
    | C_ls :
        { path : string option }
        -> (unit, string, [ `Safe ], [ `Host ]) command
    | C_git_status :
        { short : bool }
        -> (unit, string, [ `Audited ], [ `Host ]) command
    | C_rm :
        { path : string }
        -> (unit, unit, [ `Privileged ], [ `Host ]) command
  [@@deriving tla]
end
*)

let () = ()

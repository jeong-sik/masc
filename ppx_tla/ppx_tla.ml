(* ppx_tla — derive TLA+ symbol mappings from OCaml variant types.
   Cycle 2 / Tier I1 of the Kimi keeper FSM review plan.
   Plan: planning/claude-plans/30m-users-dancer-downloads-kimi-agent-ke-wobbly-shell.md

   Goal: eliminate the maintenance cost of keeping OCaml `type t = | A | B`
   in lock-step with TLA+ `TurnStateSet = {"a", "b"}`. With this PPX, the
   OCaml type is the single source of truth and a simple `[@@deriving tla]`
   attribute generates the symbol/list helpers that previously required
   hand-written matches that drift over time.

   Cycle 2 (PR #11377): minimal nullary-only generator producing
     [to_tla_symbol] and [all_states].

   Cycle 3 (this commit) extends the deriver to handle realistic ADTs:
   - Parameterised constructors (e.g. [Failed of failure_reason]) — the
     match-pattern uses [_] for the payload; [to_tla_symbol] needs no
     extra information from the args.
   - [@tla.symbol "explicit_name"] override per constructor — covers
     drift between OCaml [Awaiting_tool_result] and TLA+ "awaiting_tool"
     without renaming either side.
   - [all_symbols : string list] — replaces [all_states] as the safe
     enumeration for types with parameterised constructors. [all_states]
     remains generated only when every constructor is nullary, because
     a list literal cannot construct a payload-bearing variant.
   - sig_type_decl: applying the deriver to a .mli now produces the
     corresponding [val to_tla_symbol] / [val all_symbols] / [val all_states]
     declarations so the type can carry [@@deriving tla] in its public
     interface as well as its implementation.

   Cycle 21 closes the deferred classification slice:
   - [@tla.terminal] / [@tla.active] / [@tla.idle] per constructor.
   - [terminal_symbols] / [active_symbols] / [idle_symbols].
   - [is_terminal] / [is_active] / [is_idle] predicates that work even
     when constructors carry payloads. *)

open Ppxlib

(* [@tla.symbol "explicit_name"] override per constructor.
   Without an override the symbol is the lowercased constructor name. *)
let symbol_attr =
  Attribute.declare "tla.symbol"
    Attribute.Context.constructor_declaration
    Ast_pattern.(single_expr_payload (estring __))
    (fun s -> s)

let symbol_of_constructor (cd : constructor_declaration) =
  match Attribute.get symbol_attr cd with
  | Some s -> s
  | None -> String.lowercase_ascii cd.pcd_name.txt

(* Constructor classification attributes.

   These mirror TLA+ sets such as [TerminalStateSet] and
   [ActiveStateSet] without requiring payload-bearing constructors to
   be enumerated as values. The deriver emits symbol subsets plus
   predicates, so [Failed _] can still be classified as terminal. *)
let terminal_attr =
  Attribute.declare "tla.terminal"
    Attribute.Context.constructor_declaration
    Ast_pattern.(pstr nil)
    ()

let active_attr =
  Attribute.declare "tla.active"
    Attribute.Context.constructor_declaration
    Ast_pattern.(pstr nil)
    ()

let idle_attr =
  Attribute.declare "tla.idle"
    Attribute.Context.constructor_declaration
    Ast_pattern.(pstr nil)
    ()

let constructor_is_terminal cd = Attribute.get terminal_attr cd <> None
let constructor_is_active cd = Attribute.get active_attr cd <> None
let constructor_is_idle cd = Attribute.get idle_attr cd <> None

(* [@@tla.phantom_param] flag on type declarations (Cycle 20 / Tier I9).

   Marks every type parameter of the annotated type as phantom — i.e.
   not specialised in any constructor body — so that the deriver can
   emit [to_tla_symbol] / [all_symbols] for a 1+ type-parameter GADT
   existential as if it had no type parameters at all.

   Motivating use case: phase-encoded state machines such as
     type 'a perceiving =
       | P_observe : 'a perceiving
       | P_wait    : 'a perceiving
     [@@deriving tla] [@@tla.phantom_param]
   where 'a is used purely as a type-level tag and never narrowed by a
   constructor's payload.

   Type safety: if the user lies about phantom-ness (a constructor
   does specialise 'a, e.g. [P_count : int -> int perceiving]), the
   emitted match desugars to a regular [match e with ...] without the
   locally-abstract-type wrapper, and OCaml's type-checker rejects the
   pattern with an unambiguous error. The attribute is therefore an
   advisory contract — the deriver trusts it but the compiler enforces
   the underlying invariant. *)
let phantom_param_attr =
  Attribute.declare "tla.phantom_param"
    Attribute.Context.type_declaration
    Ast_pattern.(pstr nil)
    ()

let has_phantom_param_attr (td : type_declaration) =
  Attribute.get phantom_param_attr td <> None

let lid_of_constructor ~loc (cd : constructor_declaration) =
  Loc.make ~loc (Longident.Lident cd.pcd_name.txt)

let constructor_is_nullary (cd : constructor_declaration) =
  match cd.pcd_args with
  | Pcstr_tuple [] -> true
  | Pcstr_tuple _ | Pcstr_record _ -> false

(* Pattern that ignores any payload: [Constructor _] for parameterised,
   [Constructor] for nullary. *)
let constructor_pattern ~loc (cd : constructor_declaration) =
  let lid = lid_of_constructor ~loc cd in
  match cd.pcd_args with
  | Pcstr_tuple [] -> Ast_builder.Default.ppat_construct ~loc lid None
  | Pcstr_tuple _ | Pcstr_record _ ->
      let any_pat = Ast_builder.Default.ppat_any ~loc in
      Ast_builder.Default.ppat_construct ~loc lid (Some any_pat)

(* ── Implementation generators (str_type_decl) ──────────────────── *)

let make_to_tla_symbol_impl ~loc cds =
  let cases =
    List.map
      (fun (cd : constructor_declaration) ->
        let pat = constructor_pattern ~loc cd in
        let rhs =
          Ast_builder.Default.estring ~loc (symbol_of_constructor cd)
        in
        Ast_builder.Default.case ~lhs:pat ~guard:None ~rhs)
      cds
  in
  let arg_name = "__tla_arg" in
  let arg_pat =
    Ast_builder.Default.ppat_var ~loc (Loc.make ~loc arg_name)
  in
  let arg_expr = Ast_builder.Default.evar ~loc arg_name in
  let match_expr = Ast_builder.Default.pexp_match ~loc arg_expr cases in
  let func =
    Ast_builder.Default.pexp_fun ~loc Nolabel None arg_pat match_expr
  in
  let pat =
    Ast_builder.Default.ppat_var ~loc (Loc.make ~loc "to_tla_symbol")
  in
  let binding = Ast_builder.Default.value_binding ~loc ~pat ~expr:func in
  Ast_builder.Default.pstr_value ~loc Nonrecursive [ binding ]

let make_all_symbols_impl ~loc cds =
  let exprs =
    List.map
      (fun cd ->
        Ast_builder.Default.estring ~loc (symbol_of_constructor cd))
      cds
  in
  let list_expr = Ast_builder.Default.elist ~loc exprs in
  let pat =
    Ast_builder.Default.ppat_var ~loc (Loc.make ~loc "all_symbols")
  in
  let binding =
    Ast_builder.Default.value_binding ~loc ~pat ~expr:list_expr
  in
  Ast_builder.Default.pstr_value ~loc Nonrecursive [ binding ]

let make_all_states_impl ~loc cds =
  let exprs =
    List.map
      (fun (cd : constructor_declaration) ->
        let lid = lid_of_constructor ~loc cd in
        Ast_builder.Default.pexp_construct ~loc lid None)
      cds
  in
  let list_expr = Ast_builder.Default.elist ~loc exprs in
  let pat = Ast_builder.Default.ppat_var ~loc (Loc.make ~loc "all_states") in
  let binding =
    Ast_builder.Default.value_binding ~loc ~pat ~expr:list_expr
  in
  Ast_builder.Default.pstr_value ~loc Nonrecursive [ binding ]

let bool_expr ~loc value =
  Ast_builder.Default.pexp_construct ~loc
    (Loc.make ~loc (Longident.Lident (if value then "true" else "false")))
    None

let make_symbol_subset_impl ~loc ~name ~pred cds =
  let exprs =
    cds
    |> List.filter pred
    |> List.map (fun cd ->
           Ast_builder.Default.estring ~loc (symbol_of_constructor cd))
  in
  let list_expr = Ast_builder.Default.elist ~loc exprs in
  let pat = Ast_builder.Default.ppat_var ~loc (Loc.make ~loc name) in
  let binding =
    Ast_builder.Default.value_binding ~loc ~pat ~expr:list_expr
  in
  Ast_builder.Default.pstr_value ~loc Nonrecursive [ binding ]

let make_constructor_predicate_impl ~loc ~name ~pred cds =
  let cases =
    List.map
      (fun (cd : constructor_declaration) ->
        let pat = constructor_pattern ~loc cd in
        let rhs = bool_expr ~loc (pred cd) in
        Ast_builder.Default.case ~lhs:pat ~guard:None ~rhs)
      cds
  in
  let arg_name = "__tla_arg" in
  let arg_pat =
    Ast_builder.Default.ppat_var ~loc (Loc.make ~loc arg_name)
  in
  let arg_expr = Ast_builder.Default.evar ~loc arg_name in
  let match_expr = Ast_builder.Default.pexp_match ~loc arg_expr cases in
  let func =
    Ast_builder.Default.pexp_fun ~loc Nolabel None arg_pat match_expr
  in
  let pat = Ast_builder.Default.ppat_var ~loc (Loc.make ~loc name) in
  let binding = Ast_builder.Default.value_binding ~loc ~pat ~expr:func in
  Ast_builder.Default.pstr_value ~loc Nonrecursive [ binding ]

let make_classification_impls ~loc cds =
  [
    make_symbol_subset_impl ~loc ~name:"terminal_symbols"
      ~pred:constructor_is_terminal cds;
    make_symbol_subset_impl ~loc ~name:"active_symbols"
      ~pred:constructor_is_active cds;
    make_symbol_subset_impl ~loc ~name:"idle_symbols"
      ~pred:constructor_is_idle cds;
    make_constructor_predicate_impl ~loc ~name:"is_terminal"
      ~pred:constructor_is_terminal cds;
    make_constructor_predicate_impl ~loc ~name:"is_active"
      ~pred:constructor_is_active cds;
    make_constructor_predicate_impl ~loc ~name:"is_idle"
      ~pred:constructor_is_idle cds;
  ]

let derive_impl_for_variant ~loc cds =
  let to_tla = make_to_tla_symbol_impl ~loc cds in
  let all_symbols = make_all_symbols_impl ~loc cds in
  let classification = make_classification_impls ~loc cds in
  if List.for_all constructor_is_nullary cds then
    [ to_tla; all_symbols; make_all_states_impl ~loc cds ] @ classification
  else
    [ to_tla; all_symbols ] @ classification

(* ── Record-type implementation generators (Cycle 20 / Tier I7) ────

   For record types we emit:
   - [field_names : string list]   — every field's source name
   - [field_count : int]           — [List.length field_names]

   These two helpers let TLA+ specs assert structural shape without the
   deriver having to know how to render arbitrary field values. Future
   tiers may add a [to_tla_record] combinator that delegates field-value
   rendering to user-supplied per-field [to_tla] functions. *)

let make_field_names_impl ~loc lds =
  let exprs =
    List.map
      (fun (ld : label_declaration) ->
        Ast_builder.Default.estring ~loc ld.pld_name.txt)
      lds
  in
  let list_expr = Ast_builder.Default.elist ~loc exprs in
  let pat = Ast_builder.Default.ppat_var ~loc (Loc.make ~loc "field_names") in
  let binding =
    Ast_builder.Default.value_binding ~loc ~pat ~expr:list_expr
  in
  Ast_builder.Default.pstr_value ~loc Nonrecursive [ binding ]

let make_field_count_impl ~loc lds =
  let count = List.length lds in
  let int_expr = Ast_builder.Default.eint ~loc count in
  let pat = Ast_builder.Default.ppat_var ~loc (Loc.make ~loc "field_count") in
  let binding =
    Ast_builder.Default.value_binding ~loc ~pat ~expr:int_expr
  in
  Ast_builder.Default.pstr_value ~loc Nonrecursive [ binding ]

let derive_impl_for_record ~loc lds =
  [ make_field_names_impl ~loc lds; make_field_count_impl ~loc lds ]

(* ── GADT existential support (Cycle 20 / Tier I8) ─────────────────

   A constructor is a GADT constructor iff [pcd_res <> None]: the
   constructor explicitly carries a result type (e.g. [Any_idle : idle any]).

   For GADT existentials we emit:
   - [to_tla_symbol]: type-locally-abstract pattern match
     (`fun (type a) (x : a TYPE) -> match x with ...`) so OCaml accepts the
     pattern match without quantifier inference.
   - [all_symbols : string list]: the constructor name strings (always safe).

   We do NOT emit [all_states] for GADT existentials. A list literal
   cannot pack constructors with different phantom indices into a single
   homogeneous list without an existential wrapper, which would change
   the deriver's contract. Users who need enumeration can define their
   own [type any = Any : 'a t -> any] and lift each constructor manually.

   Type-parameter scope (Tier I8): 0 or 1 type parameter. Two-parameter
   GADTs (e.g. `(_, _) transition`) are deferred to Tier I9 when the
   `[@tla.phantom_param]` attribute is introduced. *)

let is_gadt_constructor (cd : constructor_declaration) =
  cd.pcd_res <> None

let any_gadt_constructor cds =
  List.exists is_gadt_constructor cds

let make_to_tla_symbol_impl_gadt_one_param ~loc ~type_name cds =
  (* OCaml's [let f : type a. T = e] desugars to:

       let f : 'a. 'a T_subst = fun (type a) -> (e : a T_concrete)

     Three AST pieces work together:
     1. Pattern carries [ptyp_poly] -> outer binding is polymorphic.
     2. Body wrapped in [pexp_newtype "a"] -> introduces locally
        abstract type `a` for the body.
     3. The body's expression carries [pexp_constraint] with the
        concrete-`a` type -> the inner [function ...] is locked to
        [a T_concrete -> string], which lets the GADT pattern match
        type-check uniformly across constructors.

     Emitting only #1 (just the poly annotation) is NOT enough — OCaml
     doesn't auto-introduce the locally abstract type from the poly
     annotation alone. The newtype wrapper + inner constraint are
     what unlock GADT match without narrowing to the first case. *)
  let cases =
    List.map
      (fun (cd : constructor_declaration) ->
        let pat = constructor_pattern ~loc cd in
        let rhs =
          Ast_builder.Default.estring ~loc (symbol_of_constructor cd)
        in
        Ast_builder.Default.case ~lhs:pat ~guard:None ~rhs)
      cds
  in
  let arg_name = "__tla_arg" in
  let a_var = "a" in
  let a_type = Ast_builder.Default.ptyp_var ~loc a_var in
  let arg_type =
    Ast_builder.Default.ptyp_constr ~loc
      (Loc.make ~loc (Longident.Lident type_name))
      [ a_type ]
  in
  let string_t_inline =
    Ast_builder.Default.ptyp_constr ~loc
      (Loc.make ~loc (Longident.Lident "string")) []
  in
  let arg_pat =
    Ast_builder.Default.ppat_var ~loc (Loc.make ~loc arg_name)
  in
  let arg_expr = Ast_builder.Default.evar ~loc arg_name in
  let match_expr =
    Ast_builder.Default.pexp_match ~loc arg_expr cases
  in
  let body_fun =
    Ast_builder.Default.pexp_fun ~loc Nolabel None arg_pat match_expr
  in
  let fn_type =
    Ast_builder.Default.ptyp_arrow ~loc Nolabel arg_type string_t_inline
  in
  (* Inner constraint locks body to [a t -> string] with concrete 'a'. *)
  let constrained_body =
    Ast_builder.Default.pexp_constraint ~loc body_fun fn_type
  in
  (* Newtype wrapper introduces locally abstract 'a'. *)
  let newtype_wrapped =
    Ast_builder.Default.pexp_newtype ~loc
      (Loc.make ~loc a_var) constrained_body
  in
  let poly_type =
    Ast_builder.Default.ptyp_poly ~loc [ Loc.make ~loc a_var ] fn_type
  in
  let pat_var =
    Ast_builder.Default.ppat_var ~loc (Loc.make ~loc "to_tla_symbol")
  in
  let pat =
    Ast_builder.Default.ppat_constraint ~loc pat_var poly_type
  in
  let binding =
    Ast_builder.Default.value_binding ~loc ~pat ~expr:newtype_wrapped
  in
  Ast_builder.Default.pstr_value ~loc Nonrecursive [ binding ]

let derive_impl_for_gadt ~loc ~type_name ~type_params ~is_phantom cds =
  let _ = type_name in
  let all_symbols = make_all_symbols_impl ~loc cds in
  let classification = make_classification_impls ~loc cds in
  match (type_params, is_phantom) with
  | [], _ ->
    (* GADT with no type params: structurally like ordinary variant but
       all_states is suppressed because GADT constructors with explicit
       result types may not list-construct cleanly without payload. *)
    let to_tla = make_to_tla_symbol_impl ~loc cds in
    [ to_tla; all_symbols ] @ classification
  | _ :: _, true ->
    (* Phantom-parameter GADT (Tier I9): the user has asserted via
       [@@tla.phantom_param] that no constructor specialises any type
       parameter. The emitted [to_tla_symbol] is structurally identical
       to the regular-variant case — OCaml's type checker accepts the
       match because every arm returns the same uniform type [string],
       so no locally-abstract-type scoping is required. The compiler
       enforces the phantom contract: a constructor that specialises
       a parameter triggers a clean type error at the user's call site. *)
    let to_tla = make_to_tla_symbol_impl ~loc cds in
    [ to_tla; all_symbols ] @ classification
  | _ :: _, false ->
    (* Non-phantom 1+ parameter GADT existentials still require the
       three-piece AST trick (ptyp_poly + pexp_newtype + inner
       pexp_constraint) whose ppxlib-builder reproduction empirically
       conflicts with OCaml 5.4 scoped-type rules. Workaround paths:
       - If parameters are phantom, add [@@tla.phantom_param] (Tier I9).
       - Otherwise, hand-write [to_tla_symbol_any] for this type. *)
    Location.raise_errorf ~loc
      "[@@deriving tla]: GADT existential with type parameters is not \
       yet supported. Add [@@tla.phantom_param] if the type parameters \
       are phantom (not specialised in constructor bodies). Otherwise, \
       hand-write to_tla_symbol_any for this type."

let str_type_decl ~ctxt (_rec_flag, type_decls) =
  let loc = Expansion_context.Deriver.derived_item_loc ctxt in
  match type_decls with
  | [ td ] -> (
      match td.ptype_kind with
      | Ptype_variant cds ->
          if any_gadt_constructor cds then
            derive_impl_for_gadt ~loc
              ~type_name:td.ptype_name.txt
              ~type_params:td.ptype_params
              ~is_phantom:(has_phantom_param_attr td)
              cds
          else
            derive_impl_for_variant ~loc cds
      | Ptype_record lds -> derive_impl_for_record ~loc lds
      | Ptype_abstract | Ptype_open ->
          Location.raise_errorf ~loc
            "[@@deriving tla]: only variant and record types are supported")
  | _ ->
      Location.raise_errorf ~loc
        "[@@deriving tla]: a single type declaration is supported per \
         attribute"

(* ── Signature generators (sig_type_decl) ───────────────────────── *)

let type_t ~loc ~type_name =
  Ast_builder.Default.ptyp_constr ~loc
    (Loc.make ~loc (Longident.Lident type_name))
    []

let string_t ~loc =
  Ast_builder.Default.ptyp_constr ~loc
    (Loc.make ~loc (Longident.Lident "string"))
    []

let list_t ~loc element_t =
  Ast_builder.Default.ptyp_constr ~loc
    (Loc.make ~loc (Longident.Lident "list"))
    [ element_t ]

let bool_t ~loc =
  Ast_builder.Default.ptyp_constr ~loc
    (Loc.make ~loc (Longident.Lident "bool"))
    []

let make_value_sig ~loc ~name ~type_ =
  Ast_builder.Default.psig_value ~loc
    (Ast_builder.Default.value_description ~loc
       ~name:(Loc.make ~loc name) ~type_ ~prim:[])

let derive_sig_for_variant ~loc ~type_name ~type_params ~is_phantom cds =
  let is_gadt = any_gadt_constructor cds in
  let arg_t =
    if is_gadt then
      match (type_params, is_phantom) with
      | [], _ -> type_t ~loc ~type_name
      | _ :: _, true ->
        (* Phantom GADT (Tier I9): apply the original type parameters so
           the emitted signature reads e.g. [val to_tla_symbol :
           'a perceiving -> string]. Free type variables in a value
           description are implicitly universally quantified, which is
           the correct semantics here — the function works for any
           instantiation of the phantom parameters. *)
        let type_args = List.map (fun (ct, _vi) -> ct) type_params in
        Ast_builder.Default.ptyp_constr ~loc
          (Loc.make ~loc (Longident.Lident type_name))
          type_args
      | _ :: _, false ->
        Location.raise_errorf ~loc
          "[@@deriving tla]: GADT existential with type parameters is \
           not yet supported in signatures. Add [@@tla.phantom_param] if \
           the type parameters are phantom (not specialised in \
           constructor bodies)."
    else
      type_t ~loc ~type_name
  in
  let to_tla_sig =
    let arrow =
      Ast_builder.Default.ptyp_arrow ~loc Nolabel arg_t (string_t ~loc)
    in
    make_value_sig ~loc ~name:"to_tla_symbol" ~type_:arrow
  in
  let all_symbols_sig =
    make_value_sig ~loc ~name:"all_symbols"
      ~type_:(list_t ~loc (string_t ~loc))
  in
  let all_states_sig_opt =
    if (not is_gadt) && List.for_all constructor_is_nullary cds then
      let t = type_t ~loc ~type_name in
      [ make_value_sig ~loc ~name:"all_states" ~type_:(list_t ~loc t) ]
    else
      []
  in
  let symbol_list_t = list_t ~loc (string_t ~loc) in
  let bool_arrow =
    Ast_builder.Default.ptyp_arrow ~loc Nolabel arg_t (bool_t ~loc)
  in
  let classification_sigs =
    [
      make_value_sig ~loc ~name:"terminal_symbols" ~type_:symbol_list_t;
      make_value_sig ~loc ~name:"active_symbols" ~type_:symbol_list_t;
      make_value_sig ~loc ~name:"idle_symbols" ~type_:symbol_list_t;
      make_value_sig ~loc ~name:"is_terminal" ~type_:bool_arrow;
      make_value_sig ~loc ~name:"is_active" ~type_:bool_arrow;
      make_value_sig ~loc ~name:"is_idle" ~type_:bool_arrow;
    ]
  in
  to_tla_sig :: all_symbols_sig :: all_states_sig_opt @ classification_sigs

let int_t ~loc =
  Ast_builder.Default.ptyp_constr ~loc
    (Loc.make ~loc (Longident.Lident "int"))
    []

let derive_sig_for_record ~loc lds =
  let _ = lds in
  let field_names_sig =
    make_value_sig ~loc ~name:"field_names"
      ~type_:(list_t ~loc (string_t ~loc))
  in
  let field_count_sig =
    make_value_sig ~loc ~name:"field_count" ~type_:(int_t ~loc)
  in
  [ field_names_sig; field_count_sig ]

let sig_type_decl ~ctxt (_rec_flag, type_decls) =
  let loc = Expansion_context.Deriver.derived_item_loc ctxt in
  match type_decls with
  | [ td ] -> (
      match td.ptype_kind with
      | Ptype_variant cds ->
          derive_sig_for_variant ~loc
            ~type_name:td.ptype_name.txt
            ~type_params:td.ptype_params
            ~is_phantom:(has_phantom_param_attr td)
            cds
      | Ptype_record lds ->
          derive_sig_for_record ~loc lds
      | Ptype_abstract | Ptype_open ->
          Location.raise_errorf ~loc
            "[@@deriving tla]: only variant and record types are supported")
  | _ ->
      Location.raise_errorf ~loc
        "[@@deriving tla]: a single type declaration is supported per \
         attribute"

(* ── Registration ───────────────────────────────────────────────── *)

let _ : Deriving.t =
  let str_type_decl =
    Deriving.Generator.V2.make_noarg str_type_decl
  in
  let sig_type_decl =
    Deriving.Generator.V2.make_noarg sig_type_decl
  in
  Deriving.add "tla" ~str_type_decl ~sig_type_decl

(* ── [@fsm_guard "<OCaml-bool-expr>"] (Cycle 12 / Tier I3) ──────────────

   Marks an OCaml [let]-binding (typically a state-machine transition
   function) with a TLA+-style enablement guard. The PPX rewrites the
   binding so that, whenever the function body is *invoked*, the guard
   is asserted before the original body runs.

   Example:
     let start_turn state input = body
       [@@fsm_guard "state.phase = `Idle && not state.stop_signaled"]

   becomes (conceptually):
     let start_turn state input =
       Keeper_fsm_guard_runtime.wrap_unit
         ~action:"start_turn"
         ~stage:"guard"
         (fun () -> assert (state.phase = `Idle && not state.stop_signaled));
       body

   [wrap_unit] records guard assertion failures in the Prometheus FSM
   guard counter and follows the runtime re-raise policy. For curried
   definitions ([let f x y = body]) the wrapped assert is injected into
   the innermost lambda body, so it fires per-application rather than
   per-partial-application.

   Constant ([non-lambda]) bindings get the wrapped assert evaluated at
   binding-creation time (rare in practice for FSM transition tables).

   Honest about scope: this is a lightweight runtime check that only
   fires when execution reaches the function. It is NOT TLC's exhaustive
   model check — for that, use the TLA+ spec under [specs/]. The two
   are complementary: TLC proves the spec, [@fsm_guard] catches a
   runtime divergence between OCaml caller and OCaml callee. *)

let parse_guard_expression ~loc s =
  let lexbuf = Lexing.from_string s in
  Lexing.set_position lexbuf loc.Location.loc_start;
  try Parse.expression lexbuf
  with _exn ->
    Location.raise_errorf ~loc
      "[@@fsm_guard]: payload is not a valid OCaml boolean expression: %S"
      s

(* Build [Keeper_fsm_guard_runtime.wrap_unit ~action:<s> ~stage:"guard" <thunk>]. *)
let make_wrap_unit_call ~loc ~action_str thunk =
  let open Asttypes in
  let lid : Longident.t Location.loc =
    { Location.txt = Longident.Ldot (Longident.Lident "Keeper_fsm_guard_runtime", "wrap_unit"); loc }
  in
  let wrap_unit_ref = Ast_builder.Default.pexp_ident ~loc lid in
  let action_label = Ast_builder.Default.estring ~loc action_str in
  let stage_label = Ast_builder.Default.estring ~loc "guard" in
  Ast_builder.Default.pexp_apply ~loc wrap_unit_ref
    [ (Labelled "action", action_label)
    ; (Labelled "stage", stage_label)
    ; (Nolabel, thunk)
    ]

(* Generate: [wrap_unit ~action ~stage (fun () -> assert expr); body]
   The assert is isolated inside a unit thunk so that [wrap_unit] can
   catch [Assert_failure] and bump a Prometheus counter.  The original
   body follows as a sequence expression so its return type is preserved.

   Result for [let f x = body [@@fsm_guard "expr"]]:
     let f x =
       (Keeper_fsm_guard_runtime.wrap_unit ~action:"f" ~stage:"guard"
          (fun () -> assert (expr)));
       body
*)
let inject_wrapped_body ~action_str assert_expr expr =
  let loc = expr.pexp_loc in
  let wrap_assert_as_unit =
    let unit_pat =
      Ast_builder.Default.ppat_construct ~loc
        (Loc.make ~loc (Longident.Lident "()"))
        None
    in
    let thunk =
      Ast_builder.Default.pexp_fun ~loc Asttypes.Nolabel None
        unit_pat assert_expr
    in
    make_wrap_unit_call ~loc ~action_str thunk
  in
  match expr.pexp_desc with
  | Pexp_function (params, constraint_, Pfunction_body body) ->
      let new_body =
        Ast_builder.Default.pexp_sequence ~loc:body.pexp_loc
          wrap_assert_as_unit body
      in
      { expr with pexp_desc = Pexp_function (params, constraint_, Pfunction_body new_body) }
  | _ ->
      Ast_builder.Default.pexp_sequence ~loc wrap_assert_as_unit expr

let fsm_guard_attr =
  Attribute.declare "ppx_tla.fsm_guard"
    Attribute.Context.value_binding
    Ast_pattern.(single_expr_payload (estring __))
    (fun s -> s)

class fsm_guard_mapper =
  object (_self)
    inherit Ast_traverse.map as super

    method! value_binding vb =
      let vb = super#value_binding vb in
      match Attribute.get fsm_guard_attr vb with
      | None -> vb
      | Some expr_str ->
          let loc = vb.pvb_loc in
          let parsed = parse_guard_expression ~loc expr_str in
          let assert_expr =
            Ast_builder.Default.pexp_assert ~loc parsed
          in
          let action_str =
            match vb.pvb_pat.ppat_desc with
            | Ppat_var { txt } -> txt
            | _ ->
                Location.raise_errorf ~loc:vb.pvb_pat.ppat_loc
                  "[@@fsm_guard]: expected a simple let-binding name so the guard metric has a stable action label"
          in
          let new_expr = inject_wrapped_body ~action_str assert_expr vb.pvb_expr in
          { vb with pvb_expr = new_expr }
  end

let () =
  Driver.register_transformation "ppx_tla.fsm_guard"
    ~impl:(new fsm_guard_mapper)#structure

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

   Classification attributes ([@tla.terminal] / [@tla.idle] / [@tla.active])
   that derive [terminal_states] / [idle_states] / [active_states] subsets
   are intentionally deferred to a follow-up cycle to keep this commit
   focused on the parity test for the existing TurnStateSet. *)

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

let derive_impl_for_variant ~loc cds =
  let to_tla = make_to_tla_symbol_impl ~loc cds in
  let all_symbols = make_all_symbols_impl ~loc cds in
  if List.for_all constructor_is_nullary cds then
    [ to_tla; all_symbols; make_all_states_impl ~loc cds ]
  else
    [ to_tla; all_symbols ]

let str_type_decl ~ctxt (_rec_flag, type_decls) =
  let loc = Expansion_context.Deriver.derived_item_loc ctxt in
  match type_decls with
  | [ td ] -> (
      match td.ptype_kind with
      | Ptype_variant cds -> derive_impl_for_variant ~loc cds
      | Ptype_abstract | Ptype_record _ | Ptype_open ->
          Location.raise_errorf ~loc
            "[@@deriving tla]: only variant types are supported")
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

let make_value_sig ~loc ~name ~type_ =
  Ast_builder.Default.psig_value ~loc
    (Ast_builder.Default.value_description ~loc
       ~name:(Loc.make ~loc name) ~type_ ~prim:[])

let derive_sig_for_variant ~loc ~type_name cds =
  let t = type_t ~loc ~type_name in
  let to_tla_sig =
    let arrow =
      Ast_builder.Default.ptyp_arrow ~loc Nolabel t (string_t ~loc)
    in
    make_value_sig ~loc ~name:"to_tla_symbol" ~type_:arrow
  in
  let all_symbols_sig =
    make_value_sig ~loc ~name:"all_symbols"
      ~type_:(list_t ~loc (string_t ~loc))
  in
  let all_states_sig_opt =
    if List.for_all constructor_is_nullary cds then
      [ make_value_sig ~loc ~name:"all_states" ~type_:(list_t ~loc t) ]
    else
      []
  in
  to_tla_sig :: all_symbols_sig :: all_states_sig_opt

let sig_type_decl ~ctxt (_rec_flag, type_decls) =
  let loc = Expansion_context.Deriver.derived_item_loc ctxt in
  match type_decls with
  | [ td ] -> (
      match td.ptype_kind with
      | Ptype_variant cds ->
          derive_sig_for_variant ~loc ~type_name:td.ptype_name.txt cds
      | Ptype_abstract | Ptype_record _ | Ptype_open ->
          Location.raise_errorf ~loc
            "[@@deriving tla]: only variant types are supported")
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

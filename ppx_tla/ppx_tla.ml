(* ppx_tla — derive TLA+ symbol mappings from OCaml variant types.
   Cycle 2 / Tier I1 of the Kimi keeper FSM review plan.
   Plan: planning/claude-plans/30m-users-dancer-downloads-kimi-agent-ke-wobbly-shell.md

   Goal: eliminate the maintenance cost of keeping OCaml `type t = | A | B`
   in lock-step with TLA+ `TurnStateSet = {"a", "b"}`. With this PPX, the
   OCaml type is the single source of truth and a simple `[@@deriving tla]`
   attribute generates the symbol/list helpers that previously required
   hand-written matches that drift over time.

   This is Part 1 (Cycle 2): minimal nullary-only generator producing
   `to_tla_symbol` and `all_states`. Cycle 3 adds attribute-driven
   classification (`[@tla.terminal]`, `[@tla.idle]`) and applies it to
   `Keeper_turn_fsm.turn_state` for the first real consumer. *)

open Ppxlib

let symbol_of_constructor (cd : constructor_declaration) =
  String.lowercase_ascii cd.pcd_name.txt

let lid_of_constructor ~loc (cd : constructor_declaration) =
  Loc.make ~loc (Longident.Lident cd.pcd_name.txt)

let make_to_tla_symbol ~loc cds =
  let cases =
    List.map
      (fun (cd : constructor_declaration) ->
        let lid = lid_of_constructor ~loc cd in
        let pat = Ast_builder.Default.ppat_construct ~loc lid None in
        let rhs =
          Ast_builder.Default.estring ~loc (symbol_of_constructor cd)
        in
        Ast_builder.Default.case ~lhs:pat ~guard:None ~rhs)
      cds
  in
  (* OCaml 5.4 AST changed [pexp_function] to take a parameter list;
     stay portable by building [fun __x -> match __x with ...] from
     [pexp_fun] + [pexp_match] rather than relying on [pexp_function]. *)
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

let make_all_states ~loc cds =
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

let constructor_is_nullary (cd : constructor_declaration) =
  match cd.pcd_args with
  | Pcstr_tuple [] -> true
  | Pcstr_tuple _ | Pcstr_record _ -> false

let derive_for_variant ~loc cds =
  if List.exists (fun cd -> not (constructor_is_nullary cd)) cds then
    Location.raise_errorf ~loc
      "[@@deriving tla]: only nullary constructors are supported in Cycle \
       2. Cycle 3 (planned) will add [@tla.terminal] / [@tla.idle] \
       attributes for parameterised constructors."
  else
    [ make_to_tla_symbol ~loc cds; make_all_states ~loc cds ]

let str_type_decl ~ctxt (_rec_flag, type_decls) =
  let loc = Expansion_context.Deriver.derived_item_loc ctxt in
  match type_decls with
  | [ td ] -> (
      match td.ptype_kind with
      | Ptype_variant cds -> derive_for_variant ~loc cds
      | Ptype_abstract | Ptype_record _ | Ptype_open ->
          Location.raise_errorf ~loc
            "[@@deriving tla]: only variant types are supported (got %s)"
            (match td.ptype_kind with
             | Ptype_abstract -> "abstract"
             | Ptype_record _ -> "record"
             | Ptype_open -> "open"
             | Ptype_variant _ -> "variant"))
  | _ ->
      Location.raise_errorf ~loc
        "[@@deriving tla]: a single type declaration is supported per \
         attribute"

let _ : Deriving.t =
  let str_type_decl =
    Deriving.Generator.V2.make_noarg str_type_decl
  in
  Deriving.add "tla" ~str_type_decl

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

let str_type_decl ~ctxt (_rec_flag, type_decls) =
  let loc = Expansion_context.Deriver.derived_item_loc ctxt in
  match type_decls with
  | [ td ] -> (
      match td.ptype_kind with
      | Ptype_variant cds -> derive_impl_for_variant ~loc cds
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
          derive_sig_for_variant ~loc ~type_name:td.ptype_name.txt cds
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
       assert (state.phase = `Idle && not state.stop_signaled);
       body

   For curried definitions ([let f x y = body]) the assert is injected
   into the innermost lambda body, so it fires per-application rather
   than per-partial-application.

   Constant ([non-lambda]) bindings get the assert evaluated at
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

(* OCaml 5.4 / ppxlib 0.37 unified function representation:
   [Pexp_function (params, constraint_, body)] where [body] is either
   [Pfunction_body expr] (right-hand expression of [let f x y = expr])
   or [Pfunction_cases cases] (pattern-matching [function]).

   For [Pfunction_body], inject the assert at the head of [expr] so the
   guard fires per application of the innermost lambda — partial
   applications do not trigger.

   For [Pfunction_cases] and non-function expressions, sequence the
   assert before the expression itself; the timing differs (per
   binding-creation rather than per call) but no equivalent injection
   point is portable across the unified representation. *)
let inject_into_body assert_expr expr =
  match expr.pexp_desc with
  | Pexp_function (params, constraint_, Pfunction_body body) ->
      let new_body =
        Ast_builder.Default.pexp_sequence ~loc:body.pexp_loc
          assert_expr body
      in
      { expr with
        pexp_desc =
          Pexp_function (params, constraint_, Pfunction_body new_body); }
  | _ ->
      Ast_builder.Default.pexp_sequence ~loc:expr.pexp_loc assert_expr expr

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
          let new_expr = inject_into_body assert_expr vb.pvb_expr in
          { vb with pvb_expr = new_expr }
  end

let () =
  Driver.register_transformation "ppx_tla.fsm_guard"
    ~impl:(new fsm_guard_mapper)#structure

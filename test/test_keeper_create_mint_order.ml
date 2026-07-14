(** Structural guard for the adversarial re-review of PR #24364 (P1-1),
    AST edition (re-review P3): the first version scanned source text with
    [Str.search_forward], so a comment above the mint mentioning the
    validate callee would have produced a false pass. AST nodes carry no
    comments, so this version proves the ordering on real call sites only.

    [handle_keeper_create_from_persona] in
    [lib/keeper/keeper_tool_surface_ops.ml] used to mint the initial_goal
    Goal entity ([Goal_store.upsert_goal]) BEFORE the validate gate
    ([validate_resolved_keeper_create_json]). Every rejected create then
    left an unlinked Goal on disk, one more per retry.

    Pinned here:

    - (a) inside the handler binding, the first real application of the
          validate gate precedes the first real application of the mint
    - (b) a compensation path ([Goal_store.delete_goal]) exists inside
          the same binding for the failure branches after the mint

    The semantic premise that makes the reorder valid (the pre-mint
    injected shape passes the gate) is pinned behaviourally in
    [test_keeper_create_validate.ml]. *)

open Alcotest

let module_path = "lib/keeper/keeper_tool_surface_ops.ml"
let handler_binding = "handle_keeper_create_from_persona"

let validate_callee =
  "Keeper_tool_persona_runtime.validate_resolved_keeper_create_json"

let mint_callee = "Goal_store.upsert_goal"
let release_callee = "Goal_store.delete_goal"

(* Earliest character offset of a [callee] application inside the value
   binding [binding_name]; [None] when the binding never applies it. *)
let first_call_offset ~binding_name ~callee =
  let structure = Ast_grep.parse_implementation_or_fail module_path in
  let best = ref None in
  let note (loc : Location.t) =
    let off = loc.Location.loc_start.Lexing.pos_cnum in
    match !best with
    | Some prev when prev <= off -> ()
    | _ -> best := Some off
  in
  let scan_expr expr =
    let iter =
      { Ast_iterator.default_iterator with
        expr =
          (fun self e ->
            (match e.Parsetree.pexp_desc with
             | Parsetree.Pexp_apply
                 ({ pexp_desc = Parsetree.Pexp_ident { txt; _ }; _ }, _)
               when String.equal (Ast_grep.longident_to_string txt) callee ->
                 note e.Parsetree.pexp_loc
             | _ -> ());
            Ast_iterator.default_iterator.expr self e)
      }
    in
    iter.expr iter expr
  in
  let iter =
    { Ast_iterator.default_iterator with
      value_binding =
        (fun self vb ->
          (match vb.Parsetree.pvb_pat.Parsetree.ppat_desc with
           | Parsetree.Ppat_var { txt; _ }
             when String.equal txt binding_name ->
               scan_expr vb.Parsetree.pvb_expr
           | _ -> ());
          Ast_iterator.default_iterator.value_binding self vb)
    }
  in
  iter.structure iter structure;
  !best

let test_validate_before_mint () =
  let validate_off =
    first_call_offset ~binding_name:handler_binding ~callee:validate_callee
  in
  let mint_off =
    first_call_offset ~binding_name:handler_binding ~callee:mint_callee
  in
  match (validate_off, mint_off) with
  | None, _ ->
      fail
        "validate_resolved_keeper_create_json application disappeared from \
         handle_keeper_create_from_persona"
  | _, None ->
      fail
        "Goal_store.upsert_goal mint disappeared from \
         handle_keeper_create_from_persona"
  | Some v, Some m ->
      check bool
        "validate gate must be applied before the Goal mint (orphan-Goal \
         guard)"
        true (v < m)

let test_compensation_present () =
  let releases =
    Ast_grep.count_calls_in_value_binding ~module_path
      ~binding_name:handler_binding ~callee:release_callee
  in
  check bool
    "post-mint failure branches must keep a Goal_store.delete_goal \
     compensation inside the handler"
    true (releases >= 1)

let () =
  run "keeper_create_mint_order"
    [
      ( "orphan_goal_guard",
        [
          test_case "validate applied before mint (AST)" `Quick
            test_validate_before_mint;
          test_case "compensation delete present (AST)" `Quick
            test_compensation_present;
        ] );
    ]

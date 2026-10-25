open Parsetree

let read path =
  let channel = open_in path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
    let lexbuf = Lexing.from_channel channel in
    Location.init lexbuf path;
    Parse.implementation lexbuf)

let named name binding =
  match binding.pvb_pat.ppat_desc with
  | Ppat_var { txt; _ } -> txt = name
  | _ -> false

let one label = function
  | [value] -> value
  | _ -> failwith ("expected exactly one " ^ label)

let () =
  let source = read Sys.argv.(1) in
  let type_item name =
    List.filter (fun item -> match item.pstr_desc with
      | Pstr_type (_, declarations) ->
          List.exists (fun declaration -> declaration.ptype_name.txt = name) declarations
      | _ -> false) source |> one ("type " ^ name) in
  let binding name =
    List.concat_map (fun item -> match item.pstr_desc with
      | Pstr_value (_, bindings) -> List.filter (named name) bindings
      | _ -> []) source |> one ("binding " ^ name) in
  let targets = ref [] in
  let iterator = { Ast_iterator.default_iterator with
    expr = (fun self expression ->
      let is_target = match expression.pexp_desc with
        | Pexp_match ({ pexp_desc = Pexp_field (_, { txt = Longident.Lident "view"; _ }); _ }, _) -> true
        | Pexp_ifthenelse
            ({ pexp_desc = Pexp_apply
                ({ pexp_desc = Pexp_ident { txt = Longident.Lident "view_is_chat"; _ }; _ }, _); _ }, _, Some _) -> true
        | _ -> false in
      if is_target then targets := expression :: !targets;
      Ast_iterator.default_iterator.expr self expression) } in
  iterator.expr iterator (binding "apply_keeper_schedules_read").pvb_expr;
  let target = one "schedule target expression" !targets in
  let declarations = [type_item "keeper_mode"; type_item "surface";
    Ast_helper.Str.value Asttypes.Nonrecursive [binding "view_is_chat"]] in
  Format.printf "%a@." Pprintast.structure declarations;
  Format.printf "type scope_state = { view : surface; msg_target_keeper_name : string option }@.";
  Format.printf "type scope_request = { drr_keeper : string }@.";
  Format.printf "let schedule_target keeper_detail_target_matches state request = %a@."
    Pprintast.expression target

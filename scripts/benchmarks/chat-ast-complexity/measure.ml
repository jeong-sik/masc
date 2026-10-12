open Parsetree
let metrics binding =
  let decisions = ref 0 and mutation_sites = ref 0 and depth = ref 0 and max_depth = ref 0 in
  let cases_score cases =
    List.iter (fun case -> if case.pc_guard <> None then incr decisions) cases;
    max 0 (List.length cases - 1)
  in
  let iterator = { Ast_iterator.default_iterator with
    expr = (fun self expression ->
      let branching, score = match expression.pexp_desc with
        | Pexp_match (_, cases) -> true, cases_score cases
        | Pexp_try (_, cases) -> true, 1 + cases_score cases
        | Pexp_function (_, _, Pfunction_cases (cases, _, _)) -> true, cases_score cases
        | Pexp_ifthenelse _ | Pexp_while _ | Pexp_for _ -> true, 1
        | Pexp_apply ({pexp_desc=Pexp_ident {txt=Longident.Lident ("&&" | "||");_};_},_) -> true,1
        | _ -> false,0
      in
      decisions := !decisions + score;
      (match expression.pexp_desc with
       | Pexp_setfield _ -> incr mutation_sites
       | Pexp_apply ({pexp_desc=Pexp_ident {txt=Longident.Lident ":=";_};_},_) -> incr mutation_sites
       | _ -> ());
      if branching then (incr depth; max_depth := max !max_depth !depth);
      Ast_iterator.default_iterator.expr self expression;
      if branching then decr depth)
  } in
  iterator.expr iterator binding.pvb_expr;
  !decisions + 1, !mutation_sites, !max_depth
let measure path =
  let channel = open_in path in
  let ast = Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
    let lexbuf = Lexing.from_channel channel in
    Location.init lexbuf path; Parse.implementation lexbuf) in
  List.concat_map (fun item -> match item.pstr_desc with
    | Pstr_value (_,bindings) -> List.filter_map (fun binding ->
      match binding.pvb_pat.ppat_desc,binding.pvb_expr.pexp_desc with
      | Ppat_var name,Pexp_function _ ->
        let score,mutations,depth=metrics binding in
        Some (`Assoc ["file",`String path;"function",`String name.txt;
          "line",`Int binding.pvb_loc.loc_start.pos_lnum;
          "syntactic_decision_score",`Int score;
          "branch_nesting",`Int depth;"field_or_ref_mutation_sites",`Int mutations])
      | _ -> None) bindings
    | _ -> []) ast
let () =
  let rows = Array.to_list Sys.argv |> List.tl |> List.concat_map measure in
  let score row = Yojson.Safe.Util.(row |> member "syntactic_decision_score" |> to_int) in
  Yojson.Safe.pretty_to_channel stdout (`List (List.sort (fun a b -> Int.compare (score b) (score a)) rows));
  print_newline ()

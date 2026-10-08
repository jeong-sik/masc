(* Run with OCaml 5.5's compiler-libs interpreter. This counts source AST
   decisions, not a compiler CFG, and is an audit prioritization aid only. *)
open Parsetree
let lid x = String.concat "." (Longident.flatten x)
let branches e = match e.pexp_desc with
  | Pexp_ifthenelse _ | Pexp_while _ | Pexp_for _ -> 1
  | Pexp_match (_, cases) -> max 0 (List.length cases - 1)
  | Pexp_try (_, cases) -> List.length cases
  | Pexp_function (_, _, Pfunction_cases (cases, _, _)) -> max 0 (List.length cases - 1)
  | Pexp_apply ({pexp_desc = Pexp_ident {txt = Lident ("&&" | "||"); _}; _}, _) -> 1
  | _ -> 0
let measure ~include_nested root =
  let score = ref 1 and depth = ref 0 and nesting = ref 0 and writes = ref 0 in
  let fields = Hashtbl.create 16 and calls = Hashtbl.create 16 in
  let it = { Ast_iterator.default_iterator with
    expr = (fun self e ->
      let skip = not include_nested && e != root && match e.pexp_desc with
        | Pexp_function _ -> true | _ -> false in
      if not skip then begin
        let decision = branches e in
        score := !score + decision;
        if decision > 0 then incr depth;
        nesting := max !nesting !depth;
        (match e.pexp_desc with
         | Pexp_setfield (_, field, _) -> incr writes; Hashtbl.replace fields (lid field.txt) ()
         | Pexp_field (_, field) -> Hashtbl.replace fields (lid field.txt) ()
         | Pexp_apply ({pexp_desc = Pexp_ident name; _}, _) ->
             let name = lid name.txt in
             Hashtbl.replace calls name ();
             if List.mem name [":="; "Hashtbl.replace"; "Hashtbl.add"; "Hashtbl.remove"; "Buffer.add_string"; "Buffer.clear"] then incr writes
         | _ -> ());
        Ast_iterator.default_iterator.expr self e;
        if decision > 0 then decr depth
      end);
    case = (fun self c ->
      if Option.is_some c.pc_guard then incr score;
      Ast_iterator.default_iterator.case self c)
  } in
  it.expr it root;
  !score, !nesting, !writes, Hashtbl.length fields, Hashtbl.length calls
let scan file =
  let ch = open_in file in
  let lexbuf = Lexing.from_channel ch in
  Location.init lexbuf file;
  let tree = Fun.protect ~finally:(fun () -> close_in ch) (fun () -> Parse.implementation lexbuf) in
  let walk = {Ast_iterator.default_iterator with
    value_binding = (fun self vb ->
      (match vb.pvb_pat.ppat_desc, vb.pvb_expr.pexp_desc with
      | Ppat_var name, Pexp_function _ ->
          let score, nesting, writes, fields, calls = measure ~include_nested:true vb.pvb_expr in
          let direct, _, _, _, _ = measure ~include_nested:false vb.pvb_expr in
          let first = vb.pvb_loc.loc_start.pos_lnum and last = vb.pvb_loc.loc_end.pos_lnum in
          Printf.printf "{\"file\":%S,\"function\":%S,\"line\":%d,\"lines\":%d,\"ast_branch_score\":%d,\"without_nested_functions\":%d,\"max_decision_nesting\":%d,\"mutable_writes\":%d,\"distinct_fields\":%d,\"distinct_calls\":%d}\n"
            file name.txt first (last-first+1) score direct nesting writes fields calls
      | _ -> ());
      Ast_iterator.default_iterator.value_binding self vb)
  } in walk.structure walk tree
let () = Array.iteri (fun i f -> if i > 0 then scan f) Sys.argv

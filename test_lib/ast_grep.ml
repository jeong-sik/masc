(* RFC-0085 PR-1 — AST-based structural verification for regression
   tests.  Skips comments and docstrings (which trapped RFC-0084
   PR-E / PR-F / PR-A / PR-I-3 source-grep regressions). *)

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when Sys.file_exists root -> root
  | _ -> Sys.getcwd ()
;;

let resolve_path path =
  if Filename.is_relative path then
    let candidate = Filename.concat (source_root ()) path in
    if Sys.file_exists candidate then candidate else path
  else path
;;

let resolve_module_path = resolve_path

let parse_implementation path =
  let path = resolve_module_path path in
  match open_in path with
  | exception Sys_error msg -> Error msg
  | ic ->
    let lexbuf = Lexing.from_channel ic in
    Lexing.set_filename lexbuf path;
    let result =
      try Ok (Parse.implementation lexbuf) with
      | Syntaxerr.Error _ as e ->
        close_in ic;
        Error (Format.asprintf "%a" Location.report_exception e)
    in
    close_in ic;
    result
;;

let parse_implementation_or_fail path =
  match parse_implementation path with
  | Ok structure -> structure
  | Error msg ->
    failwith
      (Printf.sprintf "Ast_grep failed to parse implementation %S: %s" path msg)
;;

(* Flatten Longident.t into "M.N.field" / "name". *)
let rec longident_to_string : Longident.t -> string = function
  | Lident s -> s
  | Ldot (rest, name) ->
    longident_to_string rest.Location.txt ^ "." ^ name.Location.txt
  | Lapply (l, r) ->
    longident_to_string l.Location.txt
    ^ "("
    ^ longident_to_string r.Location.txt
    ^ ")"
;;

let rec longident_leaf : Longident.t -> string = function
  | Lident s -> s
  | Ldot (_, name) -> name.Location.txt
  | Lapply (_, r) -> longident_leaf r.Location.txt
;;

(* Count function-application sites where the callee identifier matches
   [callee] exactly (string form "Module.fn" or just "fn" for unqualified).
   Skips comments / docstrings (AST has no nodes for them). *)
let count_calls ~module_path ~callee =
  let structure = parse_implementation_or_fail module_path in
  let count = ref 0 in
  let iter =
    { Ast_iterator.default_iterator with
      expr =
        (fun self e ->
          (match e.pexp_desc with
           | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, _) ->
             if longident_to_string txt = callee then incr count
           | _ -> ());
          Ast_iterator.default_iterator.expr self e)
    }
  in
  iter.structure iter structure;
  !count
;;

let count_calls_across_files ~module_paths ~callee =
  List.fold_left
    (fun acc module_path -> acc + count_calls ~module_path ~callee)
    0
    module_paths
;;

let count_calls_in_value_binding ~module_path ~binding_name ~callee =
  let structure = parse_implementation_or_fail module_path in
  let count_calls_in_expr expr =
    let count = ref 0 in
    let iter =
      { Ast_iterator.default_iterator with
        expr =
          (fun self e ->
            (match e.pexp_desc with
             | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, _) ->
               if longident_to_string txt = callee then incr count
             | _ -> ());
            Ast_iterator.default_iterator.expr self e)
      }
    in
    iter.expr iter expr;
    !count
  in
  let total = ref 0 in
  let iter =
    { Ast_iterator.default_iterator with
      value_binding =
        (fun self vb ->
          (match vb.pvb_pat.ppat_desc with
           | Ppat_var { txt; _ } when txt = binding_name ->
             total := !total + count_calls_in_expr vb.pvb_expr
           | _ -> ());
          Ast_iterator.default_iterator.value_binding self vb)
    }
  in
  iter.structure iter structure;
  !total
;;

let call_count_in_expression ~callee expression =
  let count = ref 0 in
  let iter =
    { Ast_iterator.default_iterator with
      expr =
        (fun self e ->
          (match e.pexp_desc with
           | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, _)
             when String.equal (longident_to_string txt) callee -> incr count
           | _ -> ());
          Ast_iterator.default_iterator.expr self e)
    }
  in
  iter.expr iter expression;
  !count
;;

let count_applications_with_label_containing_call_in_value_binding
      ~module_path
      ~binding_name
      ~callee
      ~label
      ~nested_callee
  =
  let structure = parse_implementation_or_fail module_path in
  let count_in_expression expression =
    let count = ref 0 in
    let labelled_argument_contains_call args =
      List.exists
        (fun (argument_label, argument) ->
           let label_matches =
             match argument_label with
             | Asttypes.Labelled name | Asttypes.Optional name ->
               String.equal name label
             | Asttypes.Nolabel -> false
           in
           label_matches
           && call_count_in_expression ~callee:nested_callee argument > 0)
        args
    in
    let iter =
      { Ast_iterator.default_iterator with
        expr =
          (fun self expression ->
            (match expression.pexp_desc with
             | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args)
               when String.equal (longident_to_string txt) callee
                    && labelled_argument_contains_call args -> incr count
             | _ -> ());
            Ast_iterator.default_iterator.expr self expression)
      }
    in
    iter.expr iter expression;
    !count
  in
  let total = ref 0 in
  let iter =
    { Ast_iterator.default_iterator with
      value_binding =
        (fun self binding ->
          (match binding.pvb_pat.ppat_desc with
           | Ppat_var { txt; _ } when String.equal txt binding_name ->
             total := !total + count_in_expression binding.pvb_expr
           | _ -> ());
          Ast_iterator.default_iterator.value_binding self binding)
    }
  in
  iter.structure iter structure;
  !total
;;

let rec pattern_has_constructor_leaf ~name (pattern : Parsetree.pattern) =
  match pattern.ppat_desc with
  | Ppat_construct ({ txt; _ }, _) -> String.equal (longident_leaf txt) name
  | Ppat_alias (nested, _) | Ppat_constraint (nested, _) ->
    pattern_has_constructor_leaf ~name nested
  | _ -> false
;;

(* Conservative structural proof for the common Result launch-gate shape:

     match <every branch calls gate> with
     | Error _ -> ...
     | Ok _ -> guarded side effects

   The proof fails closed for any other shape. It also compares the complete
   named binding with the [Ok] branch, so a lexical call before the match or in
   an error branch is reported as unguarded. *)
let result_ok_match_dominates_call_in_value_binding
      ~module_path
      ~binding_name
      ~gate
      ~callee
  =
  let structure = parse_implementation_or_fail module_path in
  let rec every_result_path_calls_gate (expression : Parsetree.expression) =
    match expression.pexp_desc with
    | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, _) ->
      String.equal (longident_to_string txt) gate
    | Pexp_match (_, cases) ->
      cases <> []
      && List.for_all
           (fun (case : Parsetree.case) -> every_result_path_calls_gate case.pc_rhs)
           cases
    | Pexp_constraint (nested, _) | Pexp_coerce (nested, _, _) ->
      every_result_path_calls_gate nested
    | _ -> false
  in
  let binding_expressions = ref [] in
  let iter =
    { Ast_iterator.default_iterator with
      value_binding =
        (fun self vb ->
          (match vb.pvb_pat.ppat_desc with
           | Ppat_var { txt; _ } when String.equal txt binding_name ->
             binding_expressions := vb.pvb_expr :: !binding_expressions
           | _ -> ());
          Ast_iterator.default_iterator.value_binding self vb)
    }
  in
  iter.structure iter structure;
  match !binding_expressions with
  | [ binding_expression ] ->
    let total_calls = call_count_in_expression ~callee binding_expression in
    if total_calls = 0
    then false
    else (
      let dominated = ref false in
      let match_iter =
        { Ast_iterator.default_iterator with
          expr =
            (fun self expression ->
              (match expression.pexp_desc with
               | Pexp_match (scrutinee, cases)
                 when every_result_path_calls_gate scrutinee ->
                 let guarded_calls =
                   cases
                   |> List.filter (fun (case : Parsetree.case) ->
                     pattern_has_constructor_leaf ~name:"Ok" case.pc_lhs)
                   |> List.fold_left
                        (fun count (case : Parsetree.case) ->
                           count + call_count_in_expression ~callee case.pc_rhs)
                        0
                 in
                 if guarded_calls = total_calls then dominated := true
               | _ -> ());
              Ast_iterator.default_iterator.expr self expression)
        }
      in
      match_iter.expr match_iter binding_expression;
      !dominated)
  | [] | _ :: _ :: _ -> false
;;

let count_calls_with_label ~module_path ~callee ~label =
  let structure = parse_implementation_or_fail module_path in
  let count = ref 0 in
  let has_label args =
    List.exists
      (function
        | (Asttypes.Labelled arg | Asttypes.Optional arg), _ -> String.equal arg label
        | Asttypes.Nolabel, _ -> false)
      args
  in
  let iter =
    { Ast_iterator.default_iterator with
      expr =
        (fun self e ->
          (match e.pexp_desc with
           | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args)
             when String.equal (longident_to_string txt) callee
                  && has_label args -> incr count
           | _ -> ());
          Ast_iterator.default_iterator.expr self e)
    }
  in
  iter.structure iter structure;
  !count
;;

let count_constructors ~module_path ~constructor =
  let structure = parse_implementation_or_fail module_path in
  let count = ref 0 in
  let iter =
    { Ast_iterator.default_iterator with
      expr =
        (fun self e ->
          (match e.pexp_desc with
           | Pexp_construct ({ txt; _ }, _) ->
             if longident_to_string txt = constructor then incr count
           | _ -> ());
          Ast_iterator.default_iterator.expr self e)
    }
  in
  iter.structure iter structure;
  !count
;;

let count_constructor_leaf_names ~module_path ~name =
  let structure = parse_implementation_or_fail module_path in
  let count = ref 0 in
  let iter =
    { Ast_iterator.default_iterator with
      expr =
        (fun self e ->
          (match e.pexp_desc with
           | Pexp_construct ({ txt; _ }, _) ->
             if String.equal (longident_leaf txt) name then incr count
           | _ -> ());
          Ast_iterator.default_iterator.expr self e)
    }
  in
  iter.structure iter structure;
  !count
;;

(* Count value-binding patterns ([let name = ...] or [let rec name = ...])
   whose identifier equals [name] exactly.  Catches the *identifier* —
   the axis [count_string_literals] cannot see, because identifiers are
   [Ppat_var] / [Pexp_ident] nodes, not [Pconst_string].

   Use this for rename-regression tests: if a sweep dropped a
   misleading [_xxx] underscore prefix, [count_value_bindings ~name:"_xxx"]
   must return 0 across the affected files. *)
let count_value_bindings ~module_path ~name =
  let structure = parse_implementation_or_fail module_path in
  let count = ref 0 in
  let iter =
    { Ast_iterator.default_iterator with
      value_binding =
        (fun self vb ->
          (match vb.pvb_pat.ppat_desc with
           | Ppat_var { txt; _ } when txt = name -> incr count
           | _ -> ());
          Ast_iterator.default_iterator.value_binding self vb)
    }
  in
  iter.structure iter structure;
  !count
;;

let count_value_bindings_with_unit_arg ~module_path ~name =
  let structure = parse_implementation_or_fail module_path in
  let count = ref 0 in
  let has_unit_arg (expr : Parsetree.expression) =
    match expr.pexp_desc with
    | Pexp_function (param :: _, _, _) ->
      (match param.pparam_desc with
       | Pparam_val (_, _, pat) ->
         (match pat.ppat_desc with
          | Ppat_construct ({ txt = Lident "()"; _ }, _) -> true
          | _ -> false)
       | Pparam_newtype _ -> false)
    | _ -> false
  in
  let iter =
    { Ast_iterator.default_iterator with
      value_binding =
        (fun self vb ->
          (match vb.pvb_pat.ppat_desc with
           | Ppat_var { txt; _ } when txt = name && has_unit_arg vb.pvb_expr ->
             incr count
           | _ -> ());
          Ast_iterator.default_iterator.value_binding self vb)
    }
  in
  iter.structure iter structure;
  !count
;;

(* Count value bindings whose identifier starts with [prefix].
   Useful for prefix-purge regressions (e.g., [_tool_spec_*]). *)
let count_value_bindings_with_prefix ~module_path ~prefix =
  let structure = parse_implementation_or_fail module_path in
  let count = ref 0 in
  let plen = String.length prefix in
  let starts_with s =
    String.length s >= plen && String.sub s 0 plen = prefix
  in
  let iter =
    { Ast_iterator.default_iterator with
      value_binding =
        (fun self vb ->
          (match vb.pvb_pat.ppat_desc with
           | Ppat_var { txt; _ } when starts_with txt -> incr count
           | _ -> ());
          Ast_iterator.default_iterator.value_binding self vb)
    }
  in
  iter.structure iter structure;
  !count
;;

let constructor_names_of_type ~module_path ~type_name =
  match parse_implementation module_path with
  | Error _ -> []
  | Ok structure ->
    let names = ref [] in
    let iter =
      { Ast_iterator.default_iterator with
        structure_item =
          (fun self item ->
            (match item.pstr_desc with
             | Pstr_type (_, declarations) ->
               List.iter
                 (fun (declaration : Parsetree.type_declaration) ->
                    if declaration.ptype_name.txt = type_name then
                      match declaration.ptype_kind with
                      | Ptype_variant constructors ->
                        let constructor_names =
                          List.map
                            (fun (constructor : Parsetree.constructor_declaration) ->
                               constructor.pcd_name.txt)
                            constructors
                        in
                        names := constructor_names @ !names
                      | _ -> ())
                 declarations
             | _ -> ());
            Ast_iterator.default_iterator.structure_item self item)
      }
    in
    iter.structure iter structure;
    !names
;;

(* Count string literals whose value contains [needle] as a substring.
   Excludes comments and docstrings — those are not Pconst_string
   nodes in the Parsetree. *)
let count_string_literals ~module_path ~needle =
  let structure = parse_implementation_or_fail module_path in
  let count = ref 0 in
  let needle_len = String.length needle in
  let contains haystack =
    if needle_len = 0
    then false
    else (
      let h_len = String.length haystack in
      let rec scan i =
        if i + needle_len > h_len
        then false
        else if String.sub haystack i needle_len = needle
        then true
        else scan (i + 1)
      in
      scan 0)
  in
  let iter =
    { Ast_iterator.default_iterator with
      expr =
        (fun self e ->
          (match e.pexp_desc with
           | Pexp_constant { pconst_desc = Pconst_string (s, _, _); _ } ->
             if contains s then incr count
           | _ -> ());
          Ast_iterator.default_iterator.expr self e)
    }
  in
  iter.structure iter structure;
  !count
;;

let count_string_literals_across_files ~module_paths ~needle =
  List.fold_left
    (fun acc module_path -> acc + count_string_literals ~module_path ~needle)
    0
    module_paths
;;

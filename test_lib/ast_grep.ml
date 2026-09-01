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
             (* [x |> f] is a call to [f]. Counting only direct application
                made every structural invariant blind to piped call sites, so
                a binding that reached its callee through [|>] read as zero. *)
             | Pexp_apply
                 ( { pexp_desc = Pexp_ident { txt = Lident "|>"; _ }; _ }
                 , [ (_, _); (_, { pexp_desc = Pexp_ident { txt; _ }; _ }) ] )
               ->
               if longident_to_string txt = callee then incr count
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

let count_calls_inside_while_in_value_binding ~module_path ~binding_name ~callee =
  let structure = parse_implementation_or_fail module_path in
  let count_calls_in_expr expr =
    let while_depth = ref 0 in
    let count = ref 0 in
    let iter =
      { Ast_iterator.default_iterator with
        expr =
          (fun self expression ->
            let enters_while =
              match expression.pexp_desc with
              | Pexp_while _ -> true
              | _ -> false
            in
            if enters_while then incr while_depth;
            (match expression.pexp_desc with
             | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, _)
               when !while_depth > 0
                    && String.equal (longident_to_string txt) callee ->
               incr count
             | _ -> ());
            Ast_iterator.default_iterator.expr self expression;
            if enters_while then decr while_depth)
      }
    in
    iter.expr iter expr;
    !count
  in
  let total = ref 0 in
  let iter =
    { Ast_iterator.default_iterator with
      value_binding =
        (fun self binding ->
          (match binding.pvb_pat.ppat_desc with
           | Ppat_var { txt; _ } when String.equal txt binding_name ->
             total := !total + count_calls_in_expr binding.pvb_expr
           | _ -> ());
          Ast_iterator.default_iterator.value_binding self binding)
    }
  in
  iter.structure iter structure;
  !total
;;

let count_expressions_outside_calls_in_value_binding
      ~module_path
      ~binding_name
      ~callees
      ~matches
  =
  let structure = parse_implementation_or_fail module_path in
  let count_in_expr expression =
    let protected_depth = ref 0 in
    let count = ref 0 in
    let iter =
      { Ast_iterator.default_iterator with
        expr =
          (fun self node ->
             let enters_protected_call =
               match node.pexp_desc with
               | Pexp_apply
                   ({ pexp_desc = Pexp_ident { txt; _ }; _ }, _) ->
                 List.mem (longident_to_string txt) callees
               | _ -> false
             in
             if enters_protected_call then incr protected_depth;
             if !protected_depth = 0 && matches node then incr count;
             Ast_iterator.default_iterator.expr self node;
             if enters_protected_call then decr protected_depth)
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
              total := !total + count_in_expr binding.pvb_expr
            | _ -> ());
           Ast_iterator.default_iterator.value_binding self binding)
    }
  in
  iter.structure iter structure;
  !total
;;

let count_field_accesses_outside_calls_in_value_binding
      ~module_path
      ~binding_name
      ~callees
      ~fields
  =
  count_expressions_outside_calls_in_value_binding ~module_path ~binding_name
    ~callees
    ~matches:(fun expression ->
      match expression.pexp_desc with
      | Pexp_field (_, { txt; _ }) ->
        List.mem (longident_leaf txt) fields
      | _ -> false)
;;

(* String literals a binding draws, by value. A screen mark is a literal, and
   a table that draws one mark for several states says less than the style
   beside it does -- which is a thing to assert, and not one the type checker
   can. Keeping the AST here means a caller needs no Ppxlib of its own. *)
let count_string_literals_in_value_binding ~module_path ~binding_name ~literals =
  count_expressions_outside_calls_in_value_binding ~module_path ~binding_name
    ~callees:[]
    ~matches:(fun expression ->
      match expression.pexp_desc with
      | Pexp_constant { pconst_desc = Pconst_string (text, _, _); _ } ->
        List.mem text literals
      | _ -> false)
;;

(* Constructors a binding names, in patterns as well as expressions. A match
   arm is where a rule about which cases behave alike actually lives, and an
   arm is a pattern -- an expression walk alone sees nothing. *)
let count_constructors_in_value_binding ~module_path ~binding_name ~constructors
  =
  let structure = parse_implementation_or_fail module_path in
  let count_in_expr expr =
    let count = ref 0 in
    let iter =
      { Ast_iterator.default_iterator with
        expr =
          (fun self e ->
            (match e.pexp_desc with
             | Pexp_construct ({ txt; _ }, _)
               when List.mem (longident_to_string txt) constructors ->
               incr count
             | _ -> ());
            Ast_iterator.default_iterator.expr self e)
      ; pat =
          (fun self p ->
            (match p.ppat_desc with
             | Ppat_construct ({ txt; _ }, _)
               when List.mem (longident_to_string txt) constructors ->
               incr count
             | _ -> ());
            Ast_iterator.default_iterator.pat self p)
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
             total := !total + count_in_expr vb.pvb_expr
           | _ -> ());
          Ast_iterator.default_iterator.value_binding self vb)
    }
  in
  iter.structure iter structure;
  !total
;;

let count_identifiers_outside_calls_in_value_binding
      ~module_path
      ~binding_name
      ~callees
      ~identifiers
  =
  count_expressions_outside_calls_in_value_binding ~module_path ~binding_name
    ~callees
    ~matches:(fun expression ->
      match expression.pexp_desc with
      | Pexp_ident { txt; _ } ->
        List.mem (longident_to_string txt) identifiers
      | _ -> false)
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

let count_exact_applications_in_value_binding
      ~module_path
      ~binding_name
      ~callee
      ~arguments_match
  =
  let structure = parse_implementation_or_fail module_path in
  let count_in_expression expression =
    let count = ref 0 in
    let iter =
      { Ast_iterator.default_iterator with
        expr =
          (fun self expression ->
            (match expression.pexp_desc with
             | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args)
               when String.equal (longident_to_string txt) callee
                    && arguments_match args -> incr count
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

let count_applications_with_exact_positional_constructor_in_value_binding
      ~module_path
      ~binding_name
      ~callee
      ~position
      ~constructor
  =
  let arguments_match args =
    args
    |> List.filter_map (function
      | Asttypes.Nolabel, argument -> Some argument
      | (Asttypes.Labelled _ | Asttypes.Optional _), _ -> None)
    |> fun positional_arguments -> List.nth_opt positional_arguments position
    |> Option.exists (fun (argument : Parsetree.expression) ->
      match argument.pexp_desc with
      | Pexp_construct ({ txt; _ }, _) ->
          String.equal (longident_to_string txt) constructor
      | _ -> false)
  in
  count_exact_applications_in_value_binding ~module_path ~binding_name ~callee
    ~arguments_match
;;

let positional_argument args position =
  args
  |> List.filter_map (function
    | Asttypes.Nolabel, argument -> Some argument
    | (Asttypes.Labelled _ | Asttypes.Optional _), _ -> None)
  |> fun positional_arguments -> List.nth_opt positional_arguments position
;;

let expression_is_identifier identifier (expression : Parsetree.expression) =
  match expression.pexp_desc with
  | Pexp_ident { txt; _ } ->
      String.equal (longident_to_string txt) identifier
  | _ -> false
;;

let expression_is_constructor constructor (expression : Parsetree.expression) =
  match expression.pexp_desc with
  | Pexp_construct ({ txt; _ }, None) ->
      String.equal (longident_to_string txt) constructor
  | _ -> false
;;

let count_applications_with_exact_positional_identifier_in_value_binding
      ~module_path
      ~binding_name
      ~callee
      ~position
      ~identifier
  =
  let arguments_match args =
    positional_argument args position
    |> Option.exists (expression_is_identifier identifier)
  in
  count_exact_applications_in_value_binding ~module_path ~binding_name ~callee
    ~arguments_match
;;

let count_applications_with_exact_identifier_and_constructor_in_value_binding
      ~module_path
      ~binding_name
      ~callee
      ~identifier_position
      ~identifier
      ~constructor_position
      ~constructor
  =
  let arguments_match args =
    Option.exists (expression_is_identifier identifier)
      (positional_argument args identifier_position)
    && Option.exists (expression_is_constructor constructor)
         (positional_argument args constructor_position)
  in
  count_exact_applications_in_value_binding ~module_path ~binding_name ~callee
    ~arguments_match
;;

let count_applications_with_exact_signal_handler_in_value_binding
      ~module_path
      ~binding_name
      ~signal
      ~handler
  =
  let is_signal_handler expression =
    match expression.Parsetree.pexp_desc with
    | Pexp_construct
        ( { txt; _ }
        , Some { pexp_desc = Pexp_ident { txt = handler_id; _ }; _ } ) ->
        String.equal (longident_to_string txt) "Sys.Signal_handle"
        && String.equal (longident_to_string handler_id) handler
    | _ -> false
  in
  let arguments_match args =
    Option.exists (expression_is_identifier signal) (positional_argument args 0)
    && Option.exists is_signal_handler (positional_argument args 1)
  in
  count_exact_applications_in_value_binding ~module_path ~binding_name
    ~callee:"Sys.set_signal" ~arguments_match
;;

let count_applications_with_exact_labelled_identifiers_in_value_binding
      ~module_path
      ~binding_name
      ~callee
      ~arguments
  =
  let arguments_match actual_arguments =
    let actual_labelled =
      List.filter_map
        (fun (label, expression) ->
           match label with
           | Asttypes.Labelled name -> Some (name, expression)
           | Asttypes.Nolabel | Asttypes.Optional _ -> None)
        actual_arguments
    in
    List.length actual_labelled = List.length arguments
    && List.for_all
         (fun (expected_label, expected_identifier) ->
            match List.assoc_opt expected_label actual_labelled with
            | Some expression ->
                expression_is_identifier expected_identifier expression
            | None -> false)
         arguments
  in
  count_exact_applications_in_value_binding ~module_path ~binding_name ~callee
    ~arguments_match
;;

let expressions_of_value_binding ~module_path ~binding_name =
  let structure = parse_implementation_or_fail module_path in
  let expressions = ref [] in
  let iter =
    { Ast_iterator.default_iterator with
      value_binding =
        (fun self binding ->
          (match binding.pvb_pat.ppat_desc with
           | Ppat_var { txt; _ } when String.equal txt binding_name ->
             expressions := binding.pvb_expr :: !expressions
           | _ -> ());
          Ast_iterator.default_iterator.value_binding self binding)
    }
  in
  iter.structure iter structure;
  List.rev !expressions
;;

(* [Pexp_field] is a read. Clearing a field is [Pexp_setfield], so a test
   that pins "this path clears X" has to look for the write or it counts
   zero while the code is correct. *)
let count_field_clears_to_none ~module_path ~binding_name ~field_name =
  let count = ref 0 in
  let iter =
    { Ast_iterator.default_iterator with
      expr =
        (fun self expression ->
          (match expression.Parsetree.pexp_desc with
           | Parsetree.Pexp_setfield (_, { txt; _ }, value)
             when String.equal (longident_leaf txt) field_name -> (
             match value.Parsetree.pexp_desc with
             | Parsetree.Pexp_construct ({ txt; _ }, None)
               when String.equal (longident_leaf txt) "None" -> incr count
             | _ -> ())
           | _ -> ());
          Ast_iterator.default_iterator.expr self expression)
    }
  in
  List.iter (iter.expr iter)
    (expressions_of_value_binding ~module_path ~binding_name);
  !count
;;

(* Every [x.field <- _] in a module, wherever it sits. A field whose writes
   are meant to funnel through one setter has a count of zero everywhere else,
   and that is a claim a reader can check rather than trust. *)
let count_field_writes_in_module ~module_path ~field =
  let structure = parse_implementation_or_fail module_path in
  let count = ref 0 in
  let iter =
    { Ast_iterator.default_iterator with
      expr =
        (fun self expression ->
          (match expression.Parsetree.pexp_desc with
           | Parsetree.Pexp_setfield (_, { txt; _ }, _)
             when String.equal (longident_leaf txt) field -> incr count
           | _ -> ());
          Ast_iterator.default_iterator.expr self expression)
    }
  in
  iter.structure iter structure;
  !count
;;

let rec strip_function_parameters (expression : Parsetree.expression) =
  match expression.pexp_desc with
  | Pexp_function (_, _, Pfunction_body body) -> strip_function_parameters body
  | _ -> expression
;;

let rec flatten_direct_sequence (expression : Parsetree.expression) =
  match expression.pexp_desc with
  | Pexp_sequence (left, right) -> left :: flatten_direct_sequence right
  | _ -> [ expression ]
;;

let direct_callee (expression : Parsetree.expression) =
  match expression.pexp_desc with
  | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, _) ->
      Some (longident_to_string txt)
  | _ -> None
;;

let direct_call_sequence_matches_in_value_binding
      ~module_path
      ~binding_name
      ~callees
  =
  match expressions_of_value_binding ~module_path ~binding_name with
  | [ expression ] ->
      let actual =
        expression
        |> strip_function_parameters
        |> flatten_direct_sequence
        |> List.map direct_callee
      in
      List.equal (Option.equal String.equal) actual (List.map Option.some callees)
  | [] | _ :: _ :: _ -> false
;;

let unit_lambda_body (expression : Parsetree.expression) =
  match expression.pexp_desc with
  | Pexp_function
      ( [ { pparam_desc =
              Pparam_val
                ( Asttypes.Nolabel
                , None
                , { ppat_desc =
                      Ppat_construct ({ txt = Lident "()"; _ }, None);
                    _ } );
            _ } ]
      , None
      , Pfunction_body body ) -> Some body
  | _ -> None
;;

let fun_protect_sequences_match_in_value_binding
      ~module_path
      ~binding_name
      ~body_callees
      ~finally_callees
  =
  let callback_callees expression =
    expression
    |> unit_lambda_body
    |> Option.map (fun body ->
      body |> flatten_direct_sequence |> List.map direct_callee)
  in
  let expected callees = List.map Option.some callees in
  match expressions_of_value_binding ~module_path ~binding_name with
  | [ expression ] ->
      let statements =
        expression |> strip_function_parameters |> flatten_direct_sequence
      in
      (match List.rev statements with
       | { pexp_desc =
             Pexp_apply
               ( { pexp_desc = Pexp_ident { txt; _ }; _ }
               , [ (Asttypes.Labelled "finally", finally_callback)
                 ; (Asttypes.Nolabel, body_callback)
                 ] );
           _ }
         :: _
         when String.equal (longident_to_string txt) "Fun.protect" ->
           Option.equal
             (List.equal (Option.equal String.equal))
             (callback_callees body_callback)
             (Some (expected body_callees))
           && Option.equal
                (List.equal (Option.equal String.equal))
                (callback_callees finally_callback)
                (Some (expected finally_callees))
       | _ -> false)
  | [] | _ :: _ :: _ -> false
;;

let try_handler_wraps_nested_callback_in_value_binding
      ~module_path
      ~binding_name
      ~exception_constructor
      ~outer_callee
      ~inner_callee
      ~callback_callee
  =
  let unit_expression (expression : Parsetree.expression) =
    match expression.pexp_desc with
    | Pexp_construct ({ txt = Lident "()"; _ }, None) -> true
    | _ -> false
  in
  let catches_exception (case : Parsetree.case) =
    let matches =
      match case.pc_lhs.ppat_desc with
      | Ppat_construct ({ txt; _ }, None) ->
          String.equal (longident_leaf txt) exception_constructor
      | _ -> false
    in
    matches && Option.is_none case.pc_guard && unit_expression case.pc_rhs
  in
  let callback_ends_with_call callback =
    let statements =
      callback |> strip_function_parameters |> flatten_direct_sequence
    in
    match List.rev statements with
    | { pexp_desc =
          Pexp_apply
            ( { pexp_desc = Pexp_ident { txt; _ }; _ }
            , [ Asttypes.Nolabel, argument ] );
        _ }
      :: _ ->
        String.equal (longident_to_string txt) callback_callee
        && unit_expression argument
    | [] | _ :: _ -> false
  in
  let try_body_matches (body : Parsetree.expression) =
    match body.pexp_desc with
    | Pexp_apply
        ( { pexp_desc = Pexp_ident { txt = outer_id; _ }; _ }
        , [ Asttypes.Nolabel, outer_callback ] )
      when String.equal (longident_to_string outer_id) outer_callee ->
        (match (strip_function_parameters outer_callback).pexp_desc with
         | Pexp_apply
             ( { pexp_desc = Pexp_ident { txt = inner_id; _ }; _ }
             , [ Asttypes.Nolabel, inner_callback ] ) ->
             String.equal (longident_to_string inner_id) inner_callee
             && callback_ends_with_call inner_callback
         | _ -> false)
    | _ -> false
  in
  match expressions_of_value_binding ~module_path ~binding_name with
  | [ expression ] ->
      (match (strip_function_parameters expression).pexp_desc with
       | Pexp_try (body, cases) ->
           try_body_matches body && List.exists catches_exception cases
       | _ -> false)
  | [] | _ :: _ :: _ -> false
;;

let count_applications_with_exact_labelled_unit_call_in_value_binding
      ~module_path
      ~binding_name
      ~callee
      ~label
      ~nested_callee
  =
  let is_unit_expression (expression : Parsetree.expression) =
    match expression.pexp_desc with
    | Pexp_construct ({ txt = Lident "()"; _ }, None) -> true
    | _ -> false
  in
  let arguments_match args =
    List.exists
      (fun (argument_label, (argument : Parsetree.expression)) ->
         let label_matches =
           match argument_label with
           | Asttypes.Labelled name -> String.equal name label
           | Asttypes.Nolabel | Asttypes.Optional _ -> false
         in
         label_matches
         &&
         match argument.pexp_desc with
         | Pexp_apply
             ( { pexp_desc = Pexp_ident { txt; _ }; _ }
             , [ Asttypes.Nolabel, unit_argument ] ) ->
             String.equal (longident_to_string txt) nested_callee
             && is_unit_expression unit_argument
         | _ -> false)
      args
  in
  count_exact_applications_in_value_binding ~module_path ~binding_name ~callee
    ~arguments_match
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

(* Substring matching is right for a needle that names a fragment ("goal_" in
   a family of keys) and wrong for one that names a whole key: "running" is a
   substring of "running_keeper_fiber_count", so a guard forbidding the first
   also refuses the second. This counts literals equal to the needle. *)
(* Whole-file literal counts cannot say which reader a literal belongs to. A
   file-wide ban on ["running"] in lib/tui_decode.ml was written for the
   retired planning alias and then caught an unrelated Fusion status variant
   that spells the same word. Scoping the count to the binding that is
   supposed to be free of it asks the question the guard means to ask. *)
let count_exact_string_literals_in_value_binding ~module_path ~binding_name ~needle =
  let structure = parse_implementation_or_fail module_path in
  let count_in_expr expr =
    let count = ref 0 in
    let iter =
      { Ast_iterator.default_iterator with
        expr =
          (fun self e ->
            (match e.pexp_desc with
             | Pexp_constant { pconst_desc = Pconst_string (s, _, _); _ } ->
               if String.equal s needle then incr count
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
             total := !total + count_in_expr vb.pvb_expr
           | _ -> ());
          Ast_iterator.default_iterator.value_binding self vb)
    }
  in
  iter.structure iter structure;
  !total
;;

let count_exact_string_literals ~module_path ~needle =
  let structure = parse_implementation_or_fail module_path in
  let count = ref 0 in
  let iter =
    { Ast_iterator.default_iterator with
      expr =
        (fun self e ->
          (match e.pexp_desc with
           | Pexp_constant { pconst_desc = Pconst_string (s, _, _); _ } ->
             if String.equal s needle then incr count
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

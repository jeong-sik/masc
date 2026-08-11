open Parsetree

type occurrence =
  { file : string
  ; caller : string
  ; line : int
  ; column : int
  ; offset : int
  }

exception Boundary_violation of string

let failf format =
  Printf.ksprintf (fun message -> raise (Boundary_violation message)) format
;;

let targets =
  [ "append_before_retire"
  ; "append_event_queue_transition_outbox_result"
  ; "mark_transition_projected_result"
  ; "project_event_queue_transition_outbox_result"
  ; "project_transition_outbox_after_append_result"
  ; "project_transition_outbox_result"
  ; "run_after_ledger_append_hook"
  ; "transition_outbox_result"
  ; "with_after_ledger_append"
  ]
;;

let is_target name = List.mem name targets

let rec longident_leaf (identifier : Longident.t) =
  match identifier with
  | Longident.Lident name -> name
  | Longident.Ldot (_, name) -> name.txt
  | Longident.Lapply (_, right) -> longident_leaf right.txt
;;

let rec longident_segments (identifier : Longident.t) =
  match identifier with
  | Longident.Lident name -> [ name ]
  | Longident.Ldot (prefix, name) -> longident_segments prefix.txt @ [ name.txt ]
  | Longident.Lapply (left, right) ->
    longident_segments left.txt @ longident_segments right.txt
;;

let location_fields (location : Location.t) =
  let start = location.loc_start in
  start.pos_lnum, start.pos_cnum - start.pos_bol, start.pos_cnum
;;

let occurrences : (string * occurrence) list ref = ref []
let definitions : (string * occurrence) list ref = ref []
let declarations : (string * occurrence) list ref = ref []

let add table ~file ~caller ~name location =
  if is_target name
  then (
    let line, column, offset = location_fields location in
    table := (name, { file; caller; line; column; offset }) :: !table)
;;

let qualified_name modules name = String.concat "." (modules @ [ name ])

let guarded_owner_modules =
  [ "Keeper_event_queue_persistence"
  ; "Keeper_reaction_ledger"
  ; "Keeper_event_queue_recovery"
  ]
;;

let guarded_owner identifier =
  longident_segments identifier
  |> List.find_opt (fun name -> List.mem name guarded_owner_modules)
;;

let reject_guarded_owner_reexport ~file ~surface visit =
  let reject identifier location =
    match guarded_owner identifier with
    | None -> ()
    | Some owner ->
    let line, column, _ = location_fields location in
    failf
      "%s:%d:%d %s re-exports guarded projection owner %s"
      file
      line
      column
      surface
      owner
  in
  let iterator =
    { Ast_iterator.default_iterator with
      module_expr =
        (fun self expression ->
           (match expression.pmod_desc with
             | Pmod_ident identifier ->
               reject identifier.txt identifier.loc
             | Pmod_unpack packed ->
               let packed_iterator =
                 { Ast_iterator.default_iterator with
                   module_expr =
                     (fun self expression ->
                        match expression.pmod_desc with
                        | Pmod_ident identifier ->
                          reject identifier.txt identifier.loc
                        | Pmod_unpack packed -> self.expr self packed
                        | _ ->
                          Ast_iterator.default_iterator.module_expr
                            self
                            expression)
                 ;
                   expr =
                     (fun self expression ->
                        match expression.pexp_desc with
                        | Pexp_ident identifier ->
                          reject identifier.txt identifier.loc
                        | Pexp_pack (packed, _) -> self.module_expr self packed
                        | _ -> Ast_iterator.default_iterator.expr self expression)
                 }
               in
               packed_iterator.expr packed_iterator packed
             | _ -> ());
            Ast_iterator.default_iterator.module_expr self expression)
    ; module_type =
        (fun self module_type ->
           (match module_type.pmty_desc with
            | Pmty_ident identifier | Pmty_alias identifier ->
              reject identifier.txt identifier.loc
            | Pmty_with (_, constraints) ->
              List.iter
                (function
                  | Pwith_module (_, manifest) | Pwith_modsubst (_, manifest) ->
                    reject manifest.txt manifest.loc
                  | _ -> ())
                constraints
            | _ -> ());
           Ast_iterator.default_iterator.module_type self module_type)
    ; expr =
        (fun self expression ->
           match expression.pexp_desc with
           | Pexp_pack (packed, _) -> self.module_expr self packed
           | _ -> Ast_iterator.default_iterator.expr self expression)
    }
  in
  visit iterator
;;

let allowed_internal_alias ~file (binding : module_binding) =
  String.equal file "lib/keeper/keeper_event_queue_recovery.ml"
  && binding.pmb_name.txt = Some "Persistence"
  &&
  match binding.pmb_expr.pmod_desc with
  | Pmod_ident { txt = Longident.Lident "Keeper_event_queue_persistence"; _ } -> true
  | _ -> false
;;

let pattern_variables (pattern : pattern) =
  let variables = ref [] in
  let remember (name : string Location.loc) =
    if
      not
        (List.exists
           (fun (existing : string Location.loc) ->
              String.equal existing.txt name.txt)
           !variables)
    then variables := name :: !variables
  in
  let iterator =
    { Ast_iterator.default_iterator with
      pat =
        (fun self nested ->
           (match nested.ppat_desc with
            | Ppat_var name -> remember name
            | Ppat_alias (_, name) -> remember name
            | _ -> ());
           Ast_iterator.default_iterator.pat self nested)
    }
  in
  iterator.pat iterator pattern;
  List.rev !variables
;;

let collect_structure_definitions ~file structure =
  let module_path = ref [] in
  let iterator =
    { Ast_iterator.default_iterator with
      value_binding =
        (fun self binding ->
           pattern_variables binding.pvb_pat
           |> List.iter (fun (name : string Location.loc) ->
              add
                definitions
                ~file
                ~caller:(qualified_name !module_path name.txt)
                ~name:name.txt
                name.loc);
           Ast_iterator.default_iterator.value_binding self binding)
    ; module_binding =
        (fun self (binding : module_binding) ->
           if not (allowed_internal_alias ~file binding)
           then
             reject_guarded_owner_reexport
               ~file
               ~surface:"module alias"
               (fun iterator -> iterator.module_expr iterator binding.pmb_expr);
           let previous = !module_path in
           (match binding.pmb_name.txt with
            | Some name -> module_path := previous @ [ name ]
            | None -> ());
           Ast_iterator.default_iterator.module_binding self binding;
           module_path := previous)
    ; structure_item =
        (fun self item ->
           (match item.pstr_desc with
            | Pstr_include inclusion ->
              reject_guarded_owner_reexport
                ~file
                ~surface:"structure include"
                (fun iterator ->
                   iterator.module_expr iterator inclusion.pincl_mod)
            | Pstr_primitive value ->
              add
                definitions
                ~file
                ~caller:(qualified_name !module_path value.pval_name.txt)
                ~name:value.pval_name.txt
                value.pval_name.loc
            | _ -> ());
           Ast_iterator.default_iterator.structure_item self item)
    ; expr =
        (fun self expression ->
           (match expression.pexp_desc with
            | Pexp_pack (packed, _) ->
              reject_guarded_owner_reexport
                ~file
                ~surface:"first-class module pack"
                (fun iterator -> iterator.module_expr iterator packed)
            | _ -> ());
           Ast_iterator.default_iterator.expr self expression)
    }
  in
  iterator.structure iterator structure
;;

let collect_signature_declarations ~file signature =
  let module_path = ref [] in
  let iterator =
    { Ast_iterator.default_iterator with
      value_description =
        (fun self (value : value_description) ->
           add
             declarations
             ~file
             ~caller:(qualified_name !module_path value.pval_name.txt)
             ~name:value.pval_name.txt
             value.pval_name.loc;
           Ast_iterator.default_iterator.value_description self value)
    ; module_declaration =
        (fun self (declaration : module_declaration) ->
           reject_guarded_owner_reexport
             ~file
             ~surface:"signature module alias"
             (fun iterator ->
                iterator.module_type iterator declaration.pmd_type);
           let previous = !module_path in
           (match declaration.pmd_name.txt with
            | Some name -> module_path := previous @ [ name ]
            | None -> ());
           Ast_iterator.default_iterator.module_declaration self declaration;
           module_path := previous)
    ; module_type_declaration =
        (fun self (declaration : module_type_declaration) ->
           Option.iter
             (fun module_type ->
                reject_guarded_owner_reexport
                  ~file
                  ~surface:"module type alias"
                  (fun iterator -> iterator.module_type iterator module_type))
             declaration.pmtd_type;
           let previous = !module_path in
           module_path := previous @ [ "Module_type"; declaration.pmtd_name.txt ];
           Ast_iterator.default_iterator.module_type_declaration self declaration;
           module_path := previous)
    ; signature_item =
        (fun self item ->
           (match item.psig_desc with
            | Psig_include inclusion ->
              reject_guarded_owner_reexport
                ~file
                ~surface:"signature include"
                (fun iterator ->
                   iterator.module_type iterator inclusion.pincl_mod)
            | Psig_modsubst substitution ->
              (match guarded_owner substitution.pms_manifest.txt with
               | None -> ()
               | Some owner ->
                 let line, column, _ =
                   location_fields substitution.pms_manifest.loc
                 in
                 failf
                   "%s:%d:%d signature module substitution re-exports guarded projection owner %s"
                   file
                   line
                   column
                   owner)
            | Psig_modtypesubst declaration ->
              Option.iter
                (fun module_type ->
                   reject_guarded_owner_reexport
                     ~file
                     ~surface:"signature module type substitution"
                     (fun iterator -> iterator.module_type iterator module_type))
                declaration.pmtd_type
            | _ -> ());
           Ast_iterator.default_iterator.signature_item self item)
    }
  in
  iterator.signature iterator signature
;;

let parse_implementation file =
  let channel = open_in_bin file in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
       let lexbuf = Lexing.from_channel channel in
       Location.init lexbuf file;
       Parse.implementation lexbuf)
;;

let parse_interface file =
  let channel = open_in_bin file in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
       let lexbuf = Lexing.from_channel channel in
       Location.init lexbuf file;
       Parse.interface lexbuf)
;;

let fixture_definitions ?reported_file file =
  let reported_file = Option.value reported_file ~default:file in
  let saved = !definitions in
  Fun.protect
    ~finally:(fun () -> definitions := saved)
    (fun () ->
       definitions := [];
       collect_structure_definitions
         ~file:reported_file
         (parse_implementation file);
       List.rev !definitions)
;;

let fixture_declarations file =
  let saved = !declarations in
  Fun.protect
    ~finally:(fun () -> declarations := saved)
    (fun () ->
       declarations := [];
       collect_signature_declarations ~file (parse_interface file);
       List.rev !declarations)
;;

let run_pattern_fixture_tests () =
  let constrained_file =
    "scripts/fixtures/keeper_event_queue_projection_boundary/constrained_binding.ml"
  in
  let comment_and_string_file =
    "scripts/fixtures/keeper_event_queue_projection_boundary/comment_and_string.ml"
  in
  (match fixture_definitions constrained_file with
   | [ _ ] -> ()
   | found ->
     failf
       "constrained target binding fixture escaped definition collection: expected 1, got %d"
       (List.length found));
  match fixture_definitions comment_and_string_file with
  | [] -> ()
  | found ->
    failf
      "comment/string fixture produced guarded definitions: expected 0, got %d"
      (List.length found)
;;

let inspect_implementation file =
  let structure =
    try parse_implementation file with
    | exn -> failf "cannot parse %s: %s" file (Printexc.to_string exn)
  in
  collect_structure_definitions ~file structure;
  let module_path = ref [] in
  let current_caller = ref "<toplevel>" in
  let iterator =
    { Ast_iterator.default_iterator with
      expr =
        (fun self expression ->
           (match expression.pexp_desc with
            | Pexp_ident identifier ->
              let name = longident_leaf identifier.txt in
              add
                occurrences
                ~file
                ~caller:!current_caller
                ~name
                identifier.loc
            | _ -> ());
           Ast_iterator.default_iterator.expr self expression)
    ; value_binding =
        (fun self (binding : Parsetree.value_binding) ->
           let previous = !current_caller in
           (match binding.pvb_pat.ppat_desc with
            | Ppat_var name ->
              current_caller := qualified_name !module_path name.txt
            | _ -> ());
           Ast_iterator.default_iterator.value_binding self binding;
           current_caller := previous)
    ; module_binding =
        (fun self (binding : Parsetree.module_binding) ->
           let previous = !module_path in
           (match binding.pmb_name.txt with
            | Some name -> module_path := previous @ [ name ]
            | None -> ());
           Ast_iterator.default_iterator.module_binding self binding;
           module_path := previous)
    }
  in
  iterator.structure iterator structure
;;

let inspect_interface file =
  let signature =
    try parse_interface file with
    | exn -> failf "cannot parse %s: %s" file (Printexc.to_string exn)
  in
  collect_signature_declarations ~file signature
;;

let rec source_files directory =
  Sys.readdir directory
  |> Array.to_list
  |> List.sort String.compare
  |> List.concat_map (fun name ->
    let path = Filename.concat directory name in
    if Sys.is_directory path
    then source_files path
    else if Filename.check_suffix path ".ml" || Filename.check_suffix path ".mli"
    then [ path ]
    else [])
;;

let occurrence_key occurrence = occurrence.file, occurrence.caller

let render_occurrence occurrence =
  Printf.sprintf
    "%s:%d:%d caller=%s"
    occurrence.file
    occurrence.line
    occurrence.column
    occurrence.caller
;;

let check_exact ?(report_actual = true) table ~kind name expected =
  let actual =
    !table
    |> List.filter_map (fun (candidate, occurrence) ->
      if String.equal candidate name then Some occurrence else None)
    |> List.sort (fun left right ->
      compare (occurrence_key left) (occurrence_key right))
  in
  let expected = List.sort compare expected in
  let actual_keys = List.map occurrence_key actual in
  if actual_keys <> expected
  then (
    if report_actual
    then
      List.iter
        (fun occurrence ->
           prerr_endline
             (Printf.sprintf
                "[keeper-event-queue-projection-boundary] actual %s %s: %s"
                kind
                name
                (render_occurrence occurrence)))
        actual;
    failf
      "%s %s expected=[%s] actual=[%s]"
      kind
      name
      (String.concat
         ", "
         (List.map (fun (file, caller) -> file ^ ":" ^ caller) expected))
      (String.concat
         ", "
         (List.map
            (fun occurrence ->
               occurrence.file ^ ":" ^ occurrence.caller)
            actual)))
;;

let with_table table contents check =
  let saved = !table in
  Fun.protect
    ~finally:(fun () -> table := saved)
    (fun () ->
       table := contents;
       check ())
;;

let expect_boundary_rejection label check =
  let rejected =
    match check () with
    | () -> false
    | exception Boundary_violation _ -> true
  in
  if not rejected then failf "AST rejection fixture unexpectedly passed: %s" label
;;

let matrix_entry ~kind expectations name =
  match List.assoc_opt name expectations with
  | Some expected -> expected
  | None -> failf "%s matrix is missing target %s" kind name
;;

let expect_exact_rejection ~kind ~expectations ~table ~contents name =
  let expected = matrix_entry ~kind expectations name in
  expect_boundary_rejection
    (kind ^ ":" ^ name)
    (fun () ->
       with_table table contents (fun () ->
         check_exact ~report_actual:false table ~kind name expected))
;;

let run_ast_rejection_fixtures
    ~definition_expectations
    ~declaration_expectations
    ()
  =
  let fixture name =
    Filename.concat
      "scripts/fixtures/keeper_event_queue_projection_boundary"
      name
  in
  let shadow_definitions =
    fixture_definitions (fixture "target_local_shadows.ml")
  in
  let shadow_declarations =
    fixture_declarations (fixture "target_declarations.mli")
  in
  List.iter
    (fun name ->
       expect_exact_rejection
         ~kind:"definition"
         ~expectations:definition_expectations
         ~table:definitions
         ~contents:shadow_definitions
         name;
       expect_exact_rejection
         ~kind:"declaration"
         ~expectations:declaration_expectations
         ~table:declarations
         ~contents:shadow_declarations
         name)
    [ "append_event_queue_transition_outbox_result"
    ; "run_after_ledger_append_hook"
    ];
  let primitive_definitions =
    fixture_definitions (fixture "target_primitive.ml")
  in
  expect_exact_rejection
    ~kind:"definition"
    ~expectations:definition_expectations
    ~table:definitions
    ~contents:primitive_definitions
    "project_transition_outbox_after_append_result";
  List.iter
    (fun name ->
       let file = fixture name in
       expect_boundary_rejection file (fun () ->
         let (_ : (string * occurrence) list) = fixture_definitions file in
         ()))
    [ "guarded_longident_prefix.ml"
    ; "guarded_alias_inside_unpack.ml"
    ; "guarded_pack.ml"
    ; "guarded_unpack.ml"
    ];
  let (_ : (string * occurrence) list) =
    fixture_definitions (fixture "opaque_unpack.ml")
  in
  List.iter
    (fun name ->
       let file = fixture name in
       expect_boundary_rejection file (fun () ->
         let (_ : (string * occurrence) list) = fixture_declarations file in
         ()))
    [ "guarded_modsubst.mli"; "guarded_with_module.mli" ];
  let recovery_file = "lib/keeper/keeper_event_queue_recovery.ml" in
  let (_ : (string * occurrence) list) =
    fixture_definitions
      ~reported_file:recovery_file
      (fixture "allowed_bare_alias.ml")
  in
  expect_boundary_rejection
    "constrained recovery alias"
    (fun () ->
       let (_ : (string * occurrence) list) =
         fixture_definitions
           ~reported_file:recovery_file
           (fixture "constrained_alias.ml")
       in
       ())
;;

let unique_reference name =
  match
    !occurrences
    |> List.filter_map (fun (candidate, occurrence) ->
      if String.equal candidate name then Some occurrence else None)
  with
  | [ occurrence ] -> occurrence
  | occurrences ->
    failf
      "expected one executable reference to %s, found %d"
      name
      (List.length occurrences)
;;

let check_order ~file ~caller first_name second_name =
  let first = unique_reference first_name in
  let second = unique_reference second_name in
  if
    not
      (String.equal first.file file
       && String.equal second.file file
       && String.equal first.caller caller
       && String.equal second.caller caller
       && first.offset < second.offset)
  then
    failf
      "required executable order %s then %s inside %s:%s; actual %s / %s"
      first_name
      second_name
      file
      caller
      (render_occurrence first)
      (render_occurrence second)
;;

let run () =
  let root =
    match Array.to_list Sys.argv with
    | [ _; root ] -> root
    | _ -> failf "usage: checker REPO_ROOT"
  in
  Sys.chdir root;
  let persistence_ml =
    "lib/keeper_runtime/keeper_event_queue_persistence.ml"
  in
  let persistence_mli =
    "lib/keeper_runtime/keeper_event_queue_persistence.mli"
  in
  let ledger_ml = "lib/keeper/keeper_reaction_ledger.ml" in
  let ledger_mli = "lib/keeper/keeper_reaction_ledger.mli" in
  let recovery_ml = "lib/keeper/keeper_event_queue_recovery.ml" in
  let registry_event_queue_ml =
    "lib/keeper/keeper_registry_event_queue.ml"
  in
  let schedule_consumers_ml = "lib/server/server_schedule_consumers.ml" in
  let definition_expectations =
    [ "append_event_queue_transition_outbox_result", []
    ; "mark_transition_projected_result", [ persistence_ml, "mark_transition_projected_result" ]
    ; ( "project_event_queue_transition_outbox_result"
      , [ ledger_ml, "project_event_queue_transition_outbox_result" ] )
    ; "project_transition_outbox_after_append_result", []
    ; ( "project_transition_outbox_result"
      , [ persistence_ml, "project_transition_outbox_result" ] )
    ; "run_after_ledger_append_hook", []
    ; "transition_outbox_result", []
    ; ( "with_after_ledger_append"
      , [ ledger_ml, "For_testing.with_after_ledger_append" ] )
    ]
  in
  let declaration_expectations =
    [ "append_event_queue_transition_outbox_result", []
    ; "mark_transition_projected_result", []
    ; ( "project_event_queue_transition_outbox_result"
      , [ ledger_mli, "project_event_queue_transition_outbox_result" ] )
    ; "project_transition_outbox_after_append_result", []
    ; ( "project_transition_outbox_result"
      , [ persistence_mli, "project_transition_outbox_result" ] )
    ; "run_after_ledger_append_hook", []
    ; "transition_outbox_result", []
    ; ( "with_after_ledger_append"
      , [ ledger_mli, "For_testing.with_after_ledger_append" ] )
    ]
  in
  run_pattern_fixture_tests ();
  run_ast_rejection_fixtures
    ~definition_expectations
    ~declaration_expectations
    ();
  source_files "lib"
  |> List.iter (fun file ->
    if Filename.check_suffix file ".mli"
    then inspect_interface file
    else inspect_implementation file);
  List.iter
    (fun (name, expected) ->
       check_exact occurrences ~kind:"reference" name expected)
    [ "append_before_retire", [ persistence_ml, "project_transition_outbox_result" ]
    ; "append_event_queue_transition_outbox_result", []
    ; ( "mark_transition_projected_result"
      , [ persistence_ml, "project_transition_outbox_result" ] )
    ; ( "project_event_queue_transition_outbox_result"
      , [ recovery_ml, "project_open_owner"
        ; registry_event_queue_ml, "project_source_ack_receipt"
        ; schedule_consumers_ml, "accept_terminal"
        ] )
    ; "project_transition_outbox_after_append_result", []
    ; ( "project_transition_outbox_result"
      , [ ledger_ml, "project_event_queue_transition_outbox_result" ] )
    ; "run_after_ledger_append_hook", []
    ; "transition_outbox_result", []
    ; "with_after_ledger_append", []
    ];
  List.iter
    (fun (name, expected) ->
       check_exact definitions ~kind:"definition" name expected)
    definition_expectations;
  List.iter
    (fun (name, expected) ->
       check_exact declarations ~kind:"declaration" name expected)
    declaration_expectations;
  check_order
    ~file:persistence_ml
    ~caller:"project_transition_outbox_result"
    "append_before_retire"
    "mark_transition_projected_result";
  print_endline "[keeper-event-queue-projection-boundary] OK"
;;

let () =
  match run () with
  | () -> ()
  | exception Boundary_violation message ->
    prerr_endline ("[keeper-event-queue-projection-boundary] " ^ message);
    exit 1
;;

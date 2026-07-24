open Parsetree

type occurrence =
  { file : string
  ; caller : string
  ; line : int
  ; column : int
  ; offset : int
  }

let failf format =
  Printf.ksprintf
    (fun message ->
       prerr_endline ("[keeper-event-queue-projection-boundary] " ^ message);
       exit 1)
    format
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

let rec longident_leaf = function
  | Longident.Lident name -> name
  | Longident.Ldot (_, name) -> name.txt
  | Longident.Lapply (_, right) -> longident_leaf right
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

let rec collect_structure_definitions ~file ~modules structure =
  List.iter
    (fun item ->
       match item.pstr_desc with
       | Pstr_value (_, bindings) ->
         List.iter
           (fun binding ->
              match binding.pvb_pat.ppat_desc with
              | Ppat_var name ->
                add
                  definitions
                  ~file
                  ~caller:(qualified_name modules name.txt)
                  ~name:name.txt
                  name.loc
              | _ -> ())
           bindings
       | Pstr_module binding ->
         (match binding.pmb_name.txt, binding.pmb_expr.pmod_desc with
          | Some name, Pmod_structure nested ->
            collect_structure_definitions
              ~file
              ~modules:(modules @ [ name ])
              nested
          | None, Pmod_structure nested ->
            collect_structure_definitions ~file ~modules nested
          | (Some _ | None), _ -> ())
       | Pstr_recmodule bindings ->
         List.iter
           (fun binding ->
              match binding.pmb_name.txt, binding.pmb_expr.pmod_desc with
              | Some name, Pmod_structure nested ->
                collect_structure_definitions
                  ~file
                  ~modules:(modules @ [ name ])
                  nested
              | (Some _ | None), _ -> ())
           bindings
       | _ -> ())
    structure
;;

let rec collect_signature_declarations ~file ~modules signature =
  List.iter
    (fun item ->
       match item.psig_desc with
       | Psig_value value ->
         add
           declarations
           ~file
           ~caller:(qualified_name modules value.pval_name.txt)
           ~name:value.pval_name.txt
           value.pval_name.loc
       | Psig_module declaration ->
         (match declaration.pmd_name.txt, declaration.pmd_type.pmty_desc with
          | Some name, Pmty_signature nested ->
            collect_signature_declarations
              ~file
              ~modules:(modules @ [ name ])
              nested
          | None, Pmty_signature nested ->
            collect_signature_declarations ~file ~modules nested
          | (Some _ | None), _ -> ())
       | Psig_recmodule declarations ->
         List.iter
           (fun declaration ->
              match declaration.pmd_name.txt, declaration.pmd_type.pmty_desc with
              | Some name, Pmty_signature nested ->
                collect_signature_declarations
                  ~file
                  ~modules:(modules @ [ name ])
                  nested
              | (Some _ | None), _ -> ())
           declarations
       | _ -> ())
    signature
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

let inspect_implementation file =
  let structure =
    try parse_implementation file with
    | exn -> failf "cannot parse %s: %s" file (Printexc.to_string exn)
  in
  collect_structure_definitions ~file ~modules:[] structure;
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
        (fun self binding ->
           let previous = !current_caller in
           (match binding.pvb_pat.ppat_desc with
            | Ppat_var name ->
              current_caller := qualified_name !module_path name.txt
            | _ -> ());
           Ast_iterator.default_iterator.value_binding self binding;
           current_caller := previous)
    ; module_binding =
        (fun self binding ->
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
  collect_signature_declarations ~file ~modules:[] signature
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

let check_exact table ~kind name expected =
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

let () =
  let root =
    match Array.to_list Sys.argv with
    | [ _; root ] -> root
    | _ -> failf "usage: checker REPO_ROOT"
  in
  Sys.chdir root;
  source_files "lib"
  |> List.iter (fun file ->
    if Filename.check_suffix file ".mli"
    then inspect_interface file
    else inspect_implementation file);
  let persistence_ml =
    "lib/keeper_runtime/keeper_event_queue_persistence.ml"
  in
  let persistence_mli =
    "lib/keeper_runtime/keeper_event_queue_persistence.mli"
  in
  let ledger_ml = "lib/keeper/keeper_reaction_ledger.ml" in
  let ledger_mli = "lib/keeper/keeper_reaction_ledger.mli" in
  let recovery_ml = "lib/keeper/keeper_event_queue_recovery.ml" in
  List.iter
    (fun (name, expected) ->
       check_exact occurrences ~kind:"reference" name expected)
    [ "append_before_retire", [ persistence_ml, "project_transition_outbox_result" ]
    ; ( "append_event_queue_transition_outbox_result"
      , [ ledger_ml, "project_event_queue_transition_outbox_result" ] )
    ; ( "mark_transition_projected_result"
      , [ persistence_ml, "project_transition_outbox_result" ] )
    ; ( "project_event_queue_transition_outbox_result"
      , [ recovery_ml, "project_claimed_owner" ] )
    ; "project_transition_outbox_after_append_result", []
    ; ( "project_transition_outbox_result"
      , [ ledger_ml, "project_event_queue_transition_outbox_result" ] )
    ; ( "run_after_ledger_append_hook"
      , [ ledger_ml, "project_event_queue_transition_outbox_result" ] )
    ; "transition_outbox_result", []
    ; "with_after_ledger_append", []
    ];
  List.iter
    (fun (name, expected) ->
       check_exact definitions ~kind:"definition" name expected)
    [ "mark_transition_projected_result", [ persistence_ml, "mark_transition_projected_result" ]
    ; ( "project_event_queue_transition_outbox_result"
      , [ ledger_ml, "project_event_queue_transition_outbox_result" ] )
    ; "project_transition_outbox_after_append_result", []
    ; ( "project_transition_outbox_result"
      , [ persistence_ml, "project_transition_outbox_result" ] )
    ; "transition_outbox_result", []
    ; ( "with_after_ledger_append"
      , [ ledger_ml, "For_testing.with_after_ledger_append" ] )
    ];
  List.iter
    (fun (name, expected) ->
       check_exact declarations ~kind:"declaration" name expected)
    [ "mark_transition_projected_result", []
    ; ( "project_event_queue_transition_outbox_result"
      , [ ledger_mli, "project_event_queue_transition_outbox_result" ] )
    ; "project_transition_outbox_after_append_result", []
    ; ( "project_transition_outbox_result"
      , [ persistence_mli, "project_transition_outbox_result" ] )
    ; "transition_outbox_result", []
    ; ( "with_after_ledger_append"
      , [ ledger_mli, "For_testing.with_after_ledger_append" ] )
    ];
  check_order
    ~file:persistence_ml
    ~caller:"project_transition_outbox_result"
    "append_before_retire"
    "mark_transition_projected_result";
  check_order
    ~file:ledger_ml
    ~caller:"project_event_queue_transition_outbox_result"
    "append_event_queue_transition_outbox_result"
    "run_after_ledger_append_hook";
  print_endline "[keeper-event-queue-projection-boundary] OK"
;;

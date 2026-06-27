let default_base_path () =
  match Sys.getenv_opt "MASC_BASE_PATH" with
  | Some path when String.trim path <> "" -> path
  | _ -> Sys.getcwd ()
;;

let base_path = ref (default_base_path ())
let json = ref false
let trace_limit = ref 50

let specs =
  [ ( "--base-path"
    , Arg.Set_string base_path
    , "PATH Workspace root; runtime state is read from PATH/.masc" )
  ; "--json", Arg.Set json, "Emit JSON"
  ; "--trace-limit", Arg.Set_int trace_limit, "N Number of joined trace rows to print"
  ]
;;

let () =
  Arg.parse specs (fun arg -> raise (Arg.Bad ("unexpected argument: " ^ arg)))
    "masc-recall-outcome-eval [--base-path PATH] [--json] [--trace-limit N]";
  let base_path = Env_config.normalize_masc_base_path_input !base_path in
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  let trace_limit = max 0 !trace_limit in
  let report = Masc.Keeper_recall_outcome_eval.evaluate ~masc_root in
  if !json
  then
    print_endline
      (Yojson.Safe.pretty_to_string
         (Masc.Keeper_recall_outcome_eval.to_json ~trace_limit report))
  else print_string (Masc.Keeper_recall_outcome_eval.render_text ~trace_limit report)
;;

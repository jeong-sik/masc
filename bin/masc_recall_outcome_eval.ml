let default_base_path_opt () =
  Config_dir_resolver.current_env_base_path_opt ()
;;

let base_path = ref (Option.value (default_base_path_opt ()) ~default:"")
let json = ref false
let trace_limit = ref 50
let fact_key_limit = ref 50
let summary_index_path = ref ""

let specs =
  [ ( "--base-path"
    , Arg.Set_string base_path
    , "PATH Workspace root; runtime state is read from PATH/.masc" )
  ; "--json", Arg.Set json, "Emit JSON"
  ; "--trace-limit", Arg.Set_int trace_limit, "N Number of joined trace rows to print"
  ; "--fact-key-limit", Arg.Set_int fact_key_limit, "N Number of fact-key summary rows to print"
  ; ( "--summary-index-path"
    , Arg.Set_string summary_index_path
    , "PATH Write compact fact-key outcome summary JSONL to PATH" )
  ]
;;

let () =
  Arg.parse specs (fun arg -> raise (Arg.Bad ("unexpected argument: " ^ arg)))
    "masc-recall-outcome-eval [--base-path PATH] [--json] [--trace-limit N] \
     [--fact-key-limit N] [--summary-index-path PATH]";
  let base_path =
    match String.trim !base_path with
    | "" ->
      prerr_endline
        "masc-recall-outcome-eval: --base-path is required when \
         MASC_BASE_PATH_INPUT/MASC_BASE_PATH is unset";
      exit 2
    | value -> Env_config.normalize_masc_base_path_input value
  in
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  let trace_limit = max 0 !trace_limit in
  let fact_key_limit = max 0 !fact_key_limit in
  let report = Masc.Keeper_recall_outcome_eval.evaluate ~masc_root in
  if String.trim !summary_index_path <> ""
  then Masc.Keeper_recall_outcome_eval.write_summary_index ~path:!summary_index_path report;
  if !json
  then
    print_endline
      (Yojson.Safe.pretty_to_string
         (Masc.Keeper_recall_outcome_eval.to_json
            ~trace_limit
            ~fact_key_limit
            report))
  else
    print_string
      (Masc.Keeper_recall_outcome_eval.render_text
         ~trace_limit
         ~fact_key_limit
         report)
;;

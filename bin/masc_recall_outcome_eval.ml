let default_base_path_opt () =
  Config_dir_resolver.current_env_base_path_opt ()
;;

let nonempty_opt value =
  match String.trim value with
  | "" -> None
  | value -> Some value
;;

type cli_config =
  { base_path : string
  ; json : bool
  ; trace_limit : int
  ; fact_key_limit : int
  ; summary_index_path : string option
  }

let default_config () =
  { base_path = Option.value (default_base_path_opt ()) ~default:""
  ; json = false
  ; trace_limit = 50
  ; fact_key_limit = 50
  ; summary_index_path = None
  }
;;

let () =
  let config = ref (default_config ()) in
  let update f = config := f !config in
  let specs =
    [ ( "--base-path"
      , Arg.String (fun base_path -> update (fun c -> { c with base_path }))
      , "PATH Workspace root; runtime state is read from PATH/.masc" )
    ; "--json", Arg.Unit (fun () -> update (fun c -> { c with json = true })), "Emit JSON"
    ; ( "--trace-limit"
      , Arg.Int (fun trace_limit -> update (fun c -> { c with trace_limit }))
      , "N Number of joined trace rows to print" )
    ; ( "--fact-key-limit"
      , Arg.Int (fun fact_key_limit -> update (fun c -> { c with fact_key_limit }))
      , "N Number of fact-key summary rows to print" )
    ; ( "--summary-index-path"
      , Arg.String
          (fun value ->
             update (fun c -> { c with summary_index_path = nonempty_opt value }))
      , "PATH Write compact fact-key outcome summary JSONL to PATH" )
    ]
  in
  Arg.parse specs (fun arg -> raise (Arg.Bad ("unexpected argument: " ^ arg)))
    "masc-recall-outcome-eval [--base-path PATH] [--json] [--trace-limit N] \
     [--fact-key-limit N] [--summary-index-path PATH]";
  let base_path =
    match String.trim (!config).base_path with
    | "" ->
      prerr_endline
        "masc-recall-outcome-eval: --base-path is required when \
         MASC_BASE_PATH_INPUT/MASC_BASE_PATH is unset";
      exit 2
    | value -> Env_config.normalize_masc_base_path_input value
  in
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  let trace_limit = max 0 (!config).trace_limit in
  let fact_key_limit = max 0 (!config).fact_key_limit in
  let report = Masc.Keeper_recall_outcome_eval.evaluate ~masc_root in
  Option.iter
    (fun path -> Masc.Keeper_recall_outcome_eval.write_summary_index ~path report)
    (!config).summary_index_path;
  if (!config).json
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

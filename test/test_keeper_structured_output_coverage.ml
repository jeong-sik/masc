open Alcotest

let contains_substring ~needle haystack =
  String_util.contains_substring haystack needle
;;

let rec ml_files_under rel =
  let abs = Masc_test_deps.source_path rel in
  Sys.readdir abs
  |> Array.to_list
  |> List.sort String.compare
  |> List.concat_map (fun name ->
    let child_rel = Filename.concat rel name in
    let child_abs = Filename.concat abs name in
    if Sys.is_directory child_abs
    then ml_files_under child_rel
    else if Filename.check_suffix name ".ml"
    then [ child_rel ]
    else [])
;;

let source rel = Masc_test_deps.read_source_file rel

let keeper_direct_completion_files () =
  ml_files_under "lib/keeper"
  |> List.filter (fun rel ->
    source rel |> contains_substring ~needle:"Llm_provider.Complete.complete")
  |> List.sort String.compare
;;

let expected_direct_completion_files =
  List.sort
    String.compare
    [ "lib/keeper/keeper_librarian_runtime.ml"
    ; "lib/keeper/keeper_memory_llm_summary.ml"
    ; "lib/keeper/keeper_memory_os_consolidation_runtime.ml"
    ; "lib/keeper/keeper_vision_tool.ml"
    ]
;;

let test_keeper_direct_completions_are_enumerated () =
  check
    (list string)
    "keeper direct completion files"
    expected_direct_completion_files
    (keeper_direct_completion_files ())
;;

let test_keeper_direct_completions_request_structured_output () =
  List.iter
    (fun rel ->
       let text = source rel in
       check
         bool
         (rel ^ " applies structured-output schema")
         true
         (contains_substring
            ~needle:"Keeper_structured_output_schema.apply_to_provider_config"
            text))
    expected_direct_completion_files
;;

let () =
  run
    "keeper-structured-output-coverage"
    [ ( "direct completion"
      , [ test_case
            "lib/keeper direct completion files are enumerated"
            `Quick
            test_keeper_direct_completions_are_enumerated
        ; test_case
            "lib/keeper direct completions request structured output"
            `Quick
            test_keeper_direct_completions_request_structured_output
        ] )
    ]
;;

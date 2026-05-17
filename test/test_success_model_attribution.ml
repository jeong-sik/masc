open Alcotest

module Candidate = Masc_mcp.Cascade_runtime_candidate
module Driver = Masc_mcp.Keeper_turn_driver
module Provider_config = Llm_provider.Provider_config

let make_candidate () =
  Provider_config.make
    ~kind:Provider_config.OpenAI_compat
    ~model_id:"qwen3.6-27b"
    ~base_url:"https://example.invalid/v1"
    ()
  |> Candidate.of_provider_config

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0
  then true
  else (
    let last = haystack_len - needle_len in
    let rec loop idx =
      idx <= last
      && (String.equal (String.sub haystack idx needle_len) needle
          || loop (idx + 1))
    in
    loop 0)

let substring_index_opt haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0
  then Some 0
  else (
    let last = haystack_len - needle_len in
    let rec loop idx =
      if idx > last
      then None
      else if String.equal (String.sub haystack idx needle_len) needle
      then Some idx
      else loop (idx + 1)
    in
    loop 0)

let repo_root () =
  let rec climb dir depth =
    if depth > 8
    then dir
    else if Sys.file_exists (Filename.concat dir "lib")
            && Sys.file_exists (Filename.concat dir "dune-project")
    then dir
    else climb (Filename.dirname dir) (depth + 1)
  in
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> climb (Sys.getcwd ()) 0

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let test_success_helper_uses_model_health_key () =
  let candidate = make_candidate () in
  check
    (option string)
    "success attribution"
    (Some (Candidate.model_health_key candidate))
    (Driver.For_testing.success_selected_model_raw candidate)

let test_unexpected_accept_branch_is_success_attributed () =
  let source =
    read_file (Filename.concat (repo_root ()) "lib/keeper/keeper_turn_driver.ml")
  in
  let branch_marker = "| Cascade_fsm.Accept _resp ->" in
  let branch =
    match substring_index_opt source branch_marker with
    | None -> fail "missing Accept branch marker"
    | Some idx ->
      String.sub source idx (min 1800 (String.length source - idx))
  in
  check bool "branch marker present" true (contains_substring branch branch_marker);
  check
    bool
    "unexpected Accept branch preserves candidate model attribution"
    true
    (contains_substring branch "success_selected_model_raw candidate")

let () =
  Alcotest.run
    "success_model_attribution"
    [ ( "keeper_turn_driver"
      , [ test_case
            "success helper returns model health key"
            `Quick
            test_success_helper_uses_model_health_key
        ; test_case
            "unexpected Accept success branch keeps selected model"
            `Quick
            test_unexpected_accept_branch_is_success_attributed
        ] )
    ]

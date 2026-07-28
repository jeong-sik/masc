(** Prompt asset guard for the keeper no-work contract.

    Keeper finalization requires visible response text or executed tool
    progress. Prompt assets must not tell keepers to finish a proactive turn
    with no visible reply and no tool call; that produces a fatal
    ["keeper turn completed with no textual reply"] runtime error. *)

open Alcotest

let rec find_repo_root dir =
  let marker = Filename.concat dir "config/prompts/keeper.core_behavior.md" in
  if Sys.file_exists marker then dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir
    then fail "could not locate repo root from prompt contract test"
    else find_repo_root parent
;;

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       really_input_string ic len)
;;

let prompt_path name =
  Filename.concat (find_repo_root (Sys.getcwd ())) ("config/prompts/" ^ name)
;;

let keeper_config_path name =
  Filename.concat (find_repo_root (Sys.getcwd ())) ("config/keepers/" ^ name)
;;

let contains text needle =
  String_util.contains_substring text needle
;;

let assert_not_contains ~prompt text needle =
  check
    bool
    (Printf.sprintf "%s must not contain %S" prompt needle)
    false
    (contains text needle)
;;

let assert_contains ~prompt text needle =
  check
    bool
    (Printf.sprintf "%s must contain %S" prompt needle)
    true
    (contains text needle)
;;

let test_critical_contracts_exist_in_both_keeper_lanes () =
  let autonomous =
    read_file (prompt_path "keeper.unified.system.md")
  in
  let chat =
    [ "keeper.core_behavior.md"
    ; "keeper.capabilities.md"
    ; "keeper.constitution.md"
    ]
    |> List.map (fun name -> read_file (prompt_path name))
    |> String.concat "\n"
  in
  [ ( "typed tool authority"
    , "The active typed schema is the only callable catalog"
    , "The active typed tool schema supplied with this turn is the sole \
       authority" )
  ; ( "nonblocking Gate"
    , "External effects use the configured Gate"
    , "External effects use the configured nonblocking Gate" )
  ; ( "typed failure handling"
    , "Every failed call returns a typed error"
    , "Do not silently ignore a tool error" )
  ; ( "merge blocker"
    , "Do not merge with failing required checks"
    , "Never merge with an unresolved blocker, failing required checks" )
  ; ( "no-work response"
    , "short no-work report"
    , "short no-work report" )
  ]
  |> List.iter (fun (contract, chat_needle, autonomous_needle) ->
    assert_contains
      ~prompt:("chat lane: " ^ contract)
      chat
      chat_needle;
    assert_contains
      ~prompt:("autonomous lane: " ^ contract)
      autonomous
      autonomous_needle)
;;

let test_no_work_prompts_do_not_request_silent_finish () =
  List.iter
    (fun prompt ->
       let text = read_file (prompt_path prompt) in
       assert_not_contains
         ~prompt
         text
         "without a visible reply or tool call";
       assert_not_contains ~prompt text "stay_silent";
       assert_contains ~prompt text "short no-work report")
    [ "keeper.core_behavior.md"; "keeper.unified.system.md" ]
;;

let test_keeper_toml_does_not_request_silent_finish () =
  let root = find_repo_root (Sys.getcwd ()) in
  let keepers_dir = Filename.concat root "config/keepers" in
  Sys.readdir keepers_dir
  |> Array.to_list
  |> List.filter (fun file -> Filename.check_suffix file ".toml")
  |> List.sort String.compare
  |> List.iter (fun file ->
    let prompt = "config/keepers/" ^ file in
    let text = read_file (keeper_config_path file) in
    assert_not_contains ~prompt text "SPEECH_ACT: stay_silent";
    assert_not_contains ~prompt text "DELIVERY_SURFACE: silent";
    assert_not_contains ~prompt text "stay_silent")
;;

let () =
  run
    "prompt no silent reply contract"
    [ ( "prompt assets"
      , [ test_case
            "critical contracts exist in both Keeper lanes"
            `Quick
            test_critical_contracts_exist_in_both_keeper_lanes
        ; test_case
            "no-work prompts require visible no-work report"
            `Quick
            test_no_work_prompts_do_not_request_silent_finish
        ; test_case
            "keeper TOML must not request silent no-work finish"
            `Quick
            test_keeper_toml_does_not_request_silent_finish
        ] )
    ]
;;

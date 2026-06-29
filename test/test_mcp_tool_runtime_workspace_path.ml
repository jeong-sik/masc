module Cases = Test_mcp_tool_matrix_cases

let contains_substring text fragment =
  let text_len = String.length text in
  let fragment_len = String.length fragment in
  let rec loop index =
    if fragment_len = 0 then true
    else if index + fragment_len > text_len then false
    else if String.sub text index fragment_len = fragment then true
    else loop (index + 1)
  in
  loop 0
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""
;;

let test_masc_start_tilde_rejects_empty_initial_home () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = Cases.temp_dir "mcp-start-home-empty-" in
  let saved_home = Sys.getenv_opt "HOME" in
  let saved_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      Cases.cleanup_dir base_path;
      restore_env "HOME" saved_home;
      restore_env "MASC_BASE_PATH" saved_base_path)
    (fun () ->
      Unix.putenv "MASC_BASE_PATH" base_path;
      let fixture =
        Cases.make_fixture
          sw
          ~proc_mgr:(Eio.Stdenv.process_mgr env)
          ~fs:(Eio.Stdenv.fs env)
          ~net:(Eio.Stdenv.net env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          (Eio.Stdenv.clock env)
          ~base_path
          Cases.Fresh
      in
      let result =
        Cases.execute_tool
          fixture
          ~name:"masc_start"
          ~arguments:(`Assoc [ "path", `String "~" ])
      in
      Alcotest.(check bool) "rejected" false (Tool_result.is_success result);
      let message = Tool_result.message result in
      Alcotest.(check bool)
        "reports missing HOME"
        true
        (contains_substring message "HOME is required to expand '~'"))
;;

let () =
  Mirage_crypto_rng_unix.use_default ();
  Alcotest.run
    "mcp_tool_runtime_workspace_path"
    [ ( "masc_start"
      , [ Alcotest.test_case
            "rejects tilde expansion when initial HOME is empty"
            `Quick
            test_masc_start_tilde_rejects_empty_initial_home
        ] )
    ]
;;

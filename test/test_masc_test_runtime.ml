let mkdir path = Unix.mkdir path 0o755

let touch_executable path =
  let channel = open_out path in
  close_out channel;
  Unix.chmod path 0o755

let with_temp_dir f =
  let path = Filename.temp_dir "masc-test-runtime-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)

let test_requires_explicit_root () =
  match Masc_test_runtime.resolve ~env_override:None ~dune_sourceroot:None with
  | Error _ -> ()
  | Ok path -> Alcotest.failf "unexpected implicit binary: %s" path

let test_does_not_escape_to_parent_checkout () =
  with_temp_dir @@ fun parent ->
  let parent_build = Filename.concat parent "_build" in
  let parent_default = Filename.concat parent_build "default" in
  let parent_bin = Filename.concat parent_default "bin" in
  mkdir parent_build;
  mkdir parent_default;
  mkdir parent_bin;
  touch_executable (Filename.concat parent_bin "main_eio.exe");
  let worktree = Filename.concat parent "worktree" in
  mkdir worktree;
  match
    Masc_test_runtime.resolve ~env_override:None ~dune_sourceroot:(Some worktree)
  with
  | Error _ -> ()
  | Ok path -> Alcotest.failf "escaped current worktree to %s" path

let test_uses_exact_dune_binary () =
  with_temp_dir @@ fun root ->
  let build = Filename.concat root "_build" in
  let default = Filename.concat build "default" in
  let bin = Filename.concat default "bin" in
  mkdir build;
  mkdir default;
  mkdir bin;
  let expected = Filename.concat bin "main_eio.exe" in
  touch_executable expected;
  match
    Masc_test_runtime.resolve ~env_override:None ~dune_sourceroot:(Some root)
  with
  | Error detail -> Alcotest.fail detail
  | Ok actual ->
    Alcotest.(check string) "exact current build" (Unix.realpath expected) actual

let test_invalid_override_does_not_fall_back () =
  with_temp_dir @@ fun root ->
  let build = Filename.concat root "_build" in
  let default = Filename.concat build "default" in
  let bin = Filename.concat default "bin" in
  mkdir build;
  mkdir default;
  mkdir bin;
  touch_executable (Filename.concat bin "main_eio.exe");
  match
    Masc_test_runtime.resolve ~env_override:(Some (Filename.concat root "missing"))
      ~dune_sourceroot:(Some root)
  with
  | Error _ -> ()
  | Ok path -> Alcotest.failf "invalid override fell back to %s" path

let () =
  Alcotest.run "masc test runtime"
    [ ( "binary resolution"
      , [ Alcotest.test_case "requires explicit root" `Quick
            test_requires_explicit_root
        ; Alcotest.test_case "does not escape parent checkout" `Quick
            test_does_not_escape_to_parent_checkout
        ; Alcotest.test_case "uses exact Dune binary" `Quick
            test_uses_exact_dune_binary
        ; Alcotest.test_case "invalid override does not fall back" `Quick
            test_invalid_override_does_not_fall_back
        ] )
    ]

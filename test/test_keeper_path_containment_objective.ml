open Alcotest
open Masc

let counter = ref 0

let temp_dir prefix =
  incr counter;
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) !counter)
  in
  Unix.mkdir path 0o755;
  path
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_roots f =
  let base = temp_dir "masc-path-base" in
  let outside = temp_dir "masc-path-external" in
  Fun.protect
    ~finally:(fun () ->
      remove_tree base;
      remove_tree outside)
    (fun () -> f ~base ~outside)
;;

let resolve_read ~base ~allowed_paths raw_path =
  Keeper_alerting_path.resolve_keeper_read_path
    ~config:(Workspace.default_config base)
    ~allowed_paths
    ~raw_path
;;

let expect_path label expected = function
  | Ok actual -> check string label expected actual
  | Error rejection ->
    failf
      "%s: %s"
      label
      (Keeper_path_rejection.rejection_to_user_message rejection)
;;

let test_missing_relative_path_is_not_inferred () =
  with_roots @@ fun ~base ~outside:_ ->
  let raw = "missing/leaf.txt" in
  resolve_read ~base ~allowed_paths:[] raw
  |> expect_path "literal candidate returned" (Filename.concat base raw)
;;

let test_absolute_path_inside_default_root_is_allowed () =
  with_roots @@ fun ~base ~outside:_ ->
  let target = Filename.concat base "file.txt" in
  resolve_read ~base ~allowed_paths:[] target
  |> expect_path "absolute path preserved" target
;;

let test_explicit_root_outside_base_is_allowed () =
  with_roots @@ fun ~base ~outside ->
  let target = Filename.concat outside "file.txt" in
  resolve_read ~base ~allowed_paths:[ outside ] target
  |> expect_path "external explicit root" target
;;

let test_symlink_escape_requires_explicit_root () =
  with_roots @@ fun ~base ~outside ->
  let link = Filename.concat base "external-link" in
  Unix.symlink outside link;
  let target = Filename.concat link "file.txt" in
  match resolve_read ~base ~allowed_paths:[] target with
  | Error (Keeper_path_rejection.Outside_sandbox _) -> ()
  | Error other ->
    failf
      "expected Outside_sandbox, got %s"
      (Keeper_path_rejection.rejection_to_user_message other)
  | Ok path -> failf "symlink escape unexpectedly allowed as %s" path
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run
    "keeper_path_containment_objective"
    [ ( "containment"
      , [ test_case
            "missing relative path stays literal"
            `Quick
            test_missing_relative_path_is_not_inferred
        ; test_case
            "absolute path inside default root"
            `Quick
            test_absolute_path_inside_default_root_is_allowed
        ; test_case
            "explicit root outside base"
            `Quick
            test_explicit_root_outside_base_is_allowed
        ; test_case
            "symlink escape requires explicit root"
            `Quick
            test_symlink_escape_requires_explicit_root
        ] )
    ]
;;

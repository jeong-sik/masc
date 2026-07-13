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

let test_lexical_endpoint_requires_file_entry () =
  with_roots @@ fun ~base ~outside:_ ->
  List.iter
    (fun raw_path ->
       match
         Keeper_alerting_path.resolve_keeper_confined_path
           ~config:(Workspace.default_config base)
           ~allowed_paths:[]
           ~endpoint:Keeper_alerting_path.Lexical_entry
           ~raw_path
       with
       | Error Keeper_path_rejection.Invalid_lexical_endpoint -> ()
       | Error rejection ->
         failf
           "expected Invalid_lexical_endpoint for %S, got %s"
           raw_path
           (Keeper_path_rejection.rejection_to_user_message rejection)
       | Ok _ -> failf "invalid lexical endpoint %S was accepted" raw_path)
    [ "."; ".." ]
;;

let test_atomic_replace_effect_uses_lexical_symlink_leaf () =
  with_roots @@ fun ~base ~outside:_ ->
  let actual = Filename.concat base "actual" in
  Unix.mkdir actual 0o755;
  let actual_file = Filename.concat actual "file.txt" in
  Fs_compat.save_file actual_file "referent";
  let requested = Filename.concat base "link.txt" in
  Unix.symlink actual_file requested;
  match
    Keeper_alerting_path.resolve_keeper_confined_path
      ~config:(Workspace.default_config base)
      ~allowed_paths:[]
      ~endpoint:Keeper_alerting_path.Lexical_entry
      ~raw_path:requested
  with
  | Error rejection ->
    failf
      "confined projection failed: %s"
      (Keeper_path_rejection.rejection_to_user_message rejection)
  | Ok confined ->
    check string "requested host path preserved" requested
      (Keeper_alerting_path.confined_host_path confined);
    check string "capability execution keeps lexical leaf" "link.txt"
      (Keeper_alerting_path.confined_relative_path confined);
    (match Fs_compat.get_fs_opt () with
     | None -> fail "Eio filesystem capability is unavailable"
     | Some fs ->
       Eio.Path.with_open_dir Eio.Path.(fs / base) @@ fun root ->
       let parent =
         Keeper_alerting_path.path_effect_parent_scope
           ~relative_path:"."
           ~resource:(Eio.Path.stat ~follow:true root)
           ~create_missing_parents:[]
           ~created_directory_permissions:0o755
         |> Result.get_ok
       in
       (match
          Keeper_alerting_path.atomic_replace_effect
            ~parent
            ~result_file_permissions:0o644
            confined
        with
        | Error error -> failf "atomic effect projection failed: %s" error
        | Ok gate_effect ->
          let json = Keeper_alerting_path.path_effect_to_yojson gate_effect in
          check string "Gate operation matches rename semantics"
            "atomic_replace_entry"
            Yojson.Safe.Util.
              (json |> member "operation" |> to_string);
          check string "Gate locator names lexical directory entry"
            "link.txt"
            Yojson.Safe.Util.
              (json |> member "locator" |> member "relative_path" |> to_string);
          check string "Gate locator pins lexical leaf"
            "link.txt"
            Yojson.Safe.Util.
              (json |> member "locator" |> member "leaf" |> to_string);
          check int "Gate result records exact file permissions"
            0o644
            Yojson.Safe.Util.
              (json |> member "result" |> member "permissions" |> to_int);
          check string "fixture canonical referent differs from lexical leaf"
            (Keeper_alerting_path.normalize_path_for_check actual_file)
            (Keeper_alerting_path.normalize_path_for_check requested)))
;;

let test_missing_parent_effect_is_complete () =
  with_roots @@ fun ~base ~outside:_ ->
  let requested = Filename.concat base "missing/nested/file.txt" in
  match
    Keeper_alerting_path.resolve_keeper_confined_path
      ~config:(Workspace.default_config base)
      ~allowed_paths:[]
      ~endpoint:Keeper_alerting_path.Lexical_entry
      ~raw_path:requested
  with
  | Error rejection ->
    failf
      "confined projection failed: %s"
      (Keeper_path_rejection.rejection_to_user_message rejection)
  | Ok confined ->
    (match Fs_compat.get_fs_opt () with
     | None -> fail "Eio filesystem capability is unavailable"
     | Some fs ->
       Eio.Path.with_open_dir Eio.Path.(fs / base) @@ fun root ->
       let parent =
         Keeper_alerting_path.path_effect_parent_scope
           ~relative_path:"."
           ~resource:(Eio.Path.stat ~follow:true root)
           ~create_missing_parents:[ "missing"; "nested" ]
           ~created_directory_permissions:0o755
         |> Result.get_ok
       in
       let gate_effect =
         Keeper_alerting_path.atomic_replace_effect
           ~parent
           ~result_file_permissions:0o644
           confined
         |> Result.get_ok
       in
       let missing =
         Keeper_alerting_path.path_effect_to_yojson gate_effect
         |> Yojson.Safe.Util.member "locator"
         |> Yojson.Safe.Util.member "parent"
         |> Yojson.Safe.Util.member "create_missing_parents"
         |> Yojson.Safe.Util.to_list
         |> List.map (fun entry ->
           ( Yojson.Safe.Util.(entry |> member "name" |> to_string)
           , Yojson.Safe.Util.(entry |> member "permissions" |> to_int) ))
       in
       check (list (pair string int)) "Gate sees every parent and exact mode it may create"
         [ "missing", 0o755; "nested", 0o755 ] missing)
;;

let test_external_root_swap_fails_capability_identity () =
  with_roots @@ fun ~base ~outside ->
  let allowed = Filename.concat outside "allowed" in
  let original = allowed ^ "-original" in
  Unix.mkdir allowed 0o755;
  let target = Filename.concat allowed "target.txt" in
  match
    Keeper_alerting_path.resolve_keeper_confined_path
      ~config:(Workspace.default_config base)
      ~allowed_paths:[ allowed ]
      ~endpoint:Keeper_alerting_path.Follow_referent
      ~raw_path:target
  with
  | Error rejection ->
    failf
      "external confined projection failed: %s"
      (Keeper_path_rejection.rejection_to_user_message rejection)
  | Ok confined ->
    check string "external root parent is capability anchor"
      (Keeper_alerting_path.normalize_path_for_check outside)
      (Keeper_alerting_path.confined_anchor_root confined);
    check string "external allowed root is opened below parent capability"
      "allowed"
      (Keeper_alerting_path.confined_root_relative_path confined);
    Unix.rename allowed original;
    Unix.mkdir allowed 0o755;
    Eio.Cancel.protect @@ fun () ->
    Fun.protect
      ~finally:(fun () ->
        remove_tree allowed;
        Unix.rename original allowed)
      (fun () ->
        match Fs_compat.get_fs_opt () with
        | None -> fail "Eio filesystem capability is unavailable"
        | Some fs ->
          Eio.Path.with_open_dir Eio.Path.(fs / allowed) @@ fun swapped_root ->
          (match
             Keeper_alerting_path.verify_confined_root_capability
               confined
               swapped_root
           with
           | Ok () -> fail "swapped external root capability was accepted"
           | Error message ->
             check bool "root swap is explicit" true
               (String.starts_with
                  ~prefix:
                    "filesystem allowed root changed between resolution and capability acquisition:"
                  message)))
;;

let test_project_inner_root_uses_project_anchor () =
  with_roots @@ fun ~base ~outside ->
  let sandbox = Filename.concat base "sandbox" in
  Unix.symlink outside sandbox;
  let target = Filename.concat sandbox "file.txt" in
  match
    Keeper_alerting_path.resolve_keeper_confined_path
      ~config:(Workspace.default_config base)
      ~allowed_paths:[ sandbox ]
      ~endpoint:Keeper_alerting_path.Follow_referent
      ~raw_path:target
  with
  | Error rejection ->
    failf
      "project anchor projection failed: %s"
      (Keeper_path_rejection.rejection_to_user_message rejection)
  | Ok confined ->
    check string "project root is capability anchor"
      (Keeper_alerting_path.normalize_path_for_check base)
      (Keeper_alerting_path.confined_anchor_root confined);
    check string "allowed root is opened below project capability" "sandbox"
      (Keeper_alerting_path.confined_root_relative_path confined)
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
        ; test_case
            "lexical endpoint requires a file entry"
            `Quick
            test_lexical_endpoint_requires_file_entry
          ; test_case
            "atomic effect identity uses lexical symlink leaf"
            `Quick
            test_atomic_replace_effect_uses_lexical_symlink_leaf
          ; test_case
            "external root swap fails capability identity"
            `Quick
            test_external_root_swap_fails_capability_identity
          ; test_case
            "missing parent effect is complete"
            `Quick
            test_missing_parent_effect_is_complete
        ; test_case
            "project inner root uses project capability anchor"
            `Quick
            test_project_inner_root_uses_project_anchor
        ] )
    ]
;;

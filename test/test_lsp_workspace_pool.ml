open Alcotest

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fs_compat.realpath_lenient path
;;

let touch path =
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  close_out oc
;;

let with_path path f =
  let prior = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH" path;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some value -> Unix.putenv "PATH" value
      | None -> Unix.putenv "PATH" "")
    f
;;

(* --- where a language server gets rooted ------------------------------- *)

let test_root_is_the_clone_not_the_sandbox () =
  (* A Keeper's sandbox holds its clones under repos/<id>/. Rooting a language
     server at the sandbox root puts it one level above every project in it. *)
  let sandbox = temp_dir "masc-sandbox" in
  let clone = Filename.concat sandbox "repos/some-repo" in
  touch (Filename.concat clone "dune-project");
  let file = Filename.concat clone "lib/thing.ml" in
  touch file;
  match Lsp_project_root.resolve ~language:Lsp_process_manager.Ocaml ~file ~boundary:sandbox with
  | Lsp_project_root.Project_root root -> check string "rooted at the clone" clone root
  | Lsp_project_root.No_project_root _ -> fail "found no root"
  | Lsp_project_root.Outside_boundary _ -> fail "called the file outside the sandbox"
;;

let test_root_is_the_nearest_marker () =
  let sandbox = temp_dir "masc-sandbox" in
  touch (Filename.concat sandbox "dune-project");
  let inner = Filename.concat sandbox "vendor/dep" in
  touch (Filename.concat inner "dune-project");
  let file = Filename.concat inner "src/dep.ml" in
  touch file;
  match Lsp_project_root.resolve ~language:Lsp_process_manager.Ocaml ~file ~boundary:sandbox with
  | Lsp_project_root.Project_root root -> check string "nearest wins" inner root
  | Lsp_project_root.No_project_root _ -> fail "found no root"
  | Lsp_project_root.Outside_boundary _ -> fail "called the file outside the sandbox"
;;

let test_no_marker_is_not_the_boundary () =
  (* Answering the sandbox root here would start a server that indexes a
     directory of unrelated clones and answers every question badly. *)
  let sandbox = temp_dir "masc-sandbox" in
  let file = Filename.concat sandbox "loose/script.ml" in
  touch file;
  match Lsp_project_root.resolve ~language:Lsp_process_manager.Ocaml ~file ~boundary:sandbox with
  | Lsp_project_root.No_project_root { markers; _ } ->
    check bool "names the markers it looked for" true (List.mem "dune-project" markers)
  | Lsp_project_root.Project_root root -> failf "rooted at %s with no marker anywhere" root
  | Lsp_project_root.Outside_boundary _ -> fail "called the file outside the sandbox"
;;

let test_marker_above_the_boundary_is_not_reached () =
  let outer = temp_dir "masc-outer" in
  touch (Filename.concat outer "dune-project");
  let sandbox = Filename.concat outer "sandbox" in
  let file = Filename.concat sandbox "a.ml" in
  touch file;
  match Lsp_project_root.resolve ~language:Lsp_process_manager.Ocaml ~file ~boundary:sandbox with
  | Lsp_project_root.No_project_root _ -> ()
  | Lsp_project_root.Project_root root -> failf "walked past the boundary to %s" root
  | Lsp_project_root.Outside_boundary _ -> fail "called the file outside the sandbox"
;;

let test_file_outside_the_boundary_says_so () =
  let sandbox = temp_dir "masc-sandbox" in
  let elsewhere = temp_dir "masc-elsewhere" in
  let file = Filename.concat elsewhere "a.ml" in
  touch file;
  match Lsp_project_root.resolve ~language:Lsp_process_manager.Ocaml ~file ~boundary:sandbox with
  | Lsp_project_root.Outside_boundary { boundary; _ } ->
    check string "names the boundary" sandbox boundary
  | Lsp_project_root.Project_root root -> failf "answered %s for a file outside" root
  | Lsp_project_root.No_project_root _ -> fail "read it as a rootless file inside"
;;

let test_markers_cover_every_language () =
  (* The variant makes this exhaustive at compile time; the assertion is that
     no language was given an empty marker list to satisfy the compiler. A
     language rooted at the boundary says so with its own constructor. *)
  List.iter
    (fun language ->
      let lang_id = Lsp_process_manager.lang_id_of_language language in
      check
        bool
        (Printf.sprintf "%s has a root rule" lang_id)
        true
        (match Lsp_process_manager.root_rule_of_language language with
         | Lsp_process_manager.Marker_files markers -> markers <> []
         | Lsp_process_manager.Boundary_root -> true);
      check
        bool
        (Printf.sprintf "%s has a command" lang_id)
        true
        (fst (Lsp_process_manager.command_of_language language) <> ""))
    Lsp_process_manager.all_languages
;;

let test_a_boundary_rooted_language_is_rooted_at_the_boundary () =
  (* A YAML document has no project file. Its server sees the checkout. *)
  let sandbox = temp_dir "masc-sandbox" in
  let file = Filename.concat sandbox "deploy/config.yaml" in
  touch file;
  match Lsp_project_root.resolve ~language:Lsp_process_manager.Yaml ~file ~boundary:sandbox with
  | Lsp_project_root.Project_root root ->
    check string "the boundary itself" (Fs_compat.realpath_lenient sandbox) root
  | Lsp_project_root.No_project_root _ -> fail "asked for markers a YAML file has none of"
  | Lsp_project_root.Outside_boundary _ -> fail "called the file outside the sandbox"
;;

(* --- what the pool answers when there is no server --------------------- *)

let test_missing_command_is_not_an_empty_answer () =
  Eio_main.run (fun env ->
    Lsp_workspace_pool.with_pool
      ~clock:(Eio.Stdenv.clock env)
      ~proc_mgr:(Eio.Stdenv.process_mgr env)
      (fun pool ->
      let workspace_root = temp_dir "masc-ws" in
      with_path "" (fun () ->
        match
          Lsp_workspace_pool.ensure pool ~language:Lsp_process_manager.Ocaml ~workspace_root
        with
        | Error (Lsp_workspace_pool.Server_unavailable { lang_id; command }) ->
          check string "names the language" "ocaml" lang_id;
          check string "names the command a host would install" "ocamllsp" command
        | Error (Lsp_workspace_pool.Server_failed { reason; _ }) ->
          failf "collapsed a missing command into a failure: %s" reason
        | Ok _ -> fail "started a server with an empty PATH")))
;;

(* --- one server per workspace, against a real ocamllsp ------------------ *)

let ocamllsp_present () = Executable_path.path_has_executable "ocamllsp"

let ocaml_workspace prefix =
  let root = temp_dir prefix in
  touch (Filename.concat root "dune-project");
  root
;;

let test_two_roots_do_not_share_a_server () =
  Eio_main.run (fun env ->
    Lsp_workspace_pool.with_pool
      ~clock:(Eio.Stdenv.clock env)
      ~proc_mgr:(Eio.Stdenv.process_mgr env)
      (fun pool ->
      let ensure workspace_root =
        match
          Lsp_workspace_pool.ensure pool ~language:Lsp_process_manager.Ocaml ~workspace_root
        with
        | Ok proc -> proc
        | Error err -> failf "%a" Lsp_workspace_pool.pp_error err
      in
      let a = ocaml_workspace "masc-ws-a" in
      let b = ocaml_workspace "masc-ws-b" in
      let first = ensure a in
      let second = ensure b in
      let again = ensure a in
      (* Asserted on the records the pool hands back, not on a log line.
         [start_locked] is the only place a record is made and it always
         spawns, so two distinct records are two children — and Eio does not
         expose a pid to check that more directly. *)
      check
        bool
        "the same root is the same server"
        true
        (first == again);
      check
        bool
        "a different root is a different server"
        true
        (first != second)))
;;

let real_server_cases =
  if ocamllsp_present ()
  then
    [ test_case "two roots do not share a server" `Slow test_two_roots_do_not_share_a_server ]
  else (
    print_endline
      "[lsp_workspace_pool] ocamllsp is not on PATH - skipping the case that needs one";
    [])
;;

let () =
  run
    "lsp_workspace_pool"
    [ ( "project root"
      , [ test_case "the clone, not the sandbox" `Quick test_root_is_the_clone_not_the_sandbox
        ; test_case "the nearest marker" `Quick test_root_is_the_nearest_marker
        ; test_case "no marker is not the boundary" `Quick test_no_marker_is_not_the_boundary
        ; test_case
            "a marker above the boundary is out of reach"
            `Quick
            test_marker_above_the_boundary_is_not_reached
        ; test_case
            "a file outside the boundary says so"
            `Quick
            test_file_outside_the_boundary_says_so
        ; test_case "every language has both" `Quick test_markers_cover_every_language
        ; test_case
            "a boundary-rooted language is rooted at the boundary"
            `Quick
            test_a_boundary_rooted_language_is_rooted_at_the_boundary
        ] )
    ; ( "no server"
      , [ test_case
            "a missing command is typed"
            `Quick
            test_missing_command_is_not_an_empty_answer
        ] )
    ; "live server", real_server_cases
    ]
;;

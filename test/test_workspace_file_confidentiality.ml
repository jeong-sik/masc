(** task-1734 / task-1735 — confidentiality guards for the workspace
    file read routes ([/api/v1/workspace/file], [/git/blame], [/git/diff]).

    Two axes, both routed through [resolve_workspace_file]:

    - B1 (secret denylist): a request whose path contains a confidential
      component ([.env], [.masc]*, [credentials]*, [.git], [.ssh]) is
      rejected instead of being served verbatim. The denylist is a single
      SSOT shared with the file tree, so anything blocked from a read is
      also hidden from the tree.
    - B2 (symlink escape): a committed symlink that resolves outside the
      workspace base is rejected. The pre-existing [safe_path] check only
      compared the lexical prefix, so [repo/evil -> /outside/secret]
      satisfied it and the file was read through the link. *)

open Alcotest

module W = Server_routes_http_routes_workspace

let rec rm_rf path =
  (* [lstat], not [stat]: never follow a symlink into the directory it
     targets — the escape tests create links pointing outside [base]. *)
  match Unix.lstat path with
  | exception _ -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
    (try Unix.rmdir path with _ -> ())
  | _ -> (try Sys.remove path with _ -> ())
;;

let with_temp_dir f =
  let path = Filename.temp_file "ide-file-conf" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let mkdir_p path =
  let rec loop p =
    if p = "" || p = "/" || (Sys.file_exists p && Sys.is_directory p)
    then ()
    else (
      loop (Filename.dirname p);
      try Unix.mkdir p 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  loop path
;;

let touch path =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  close_out oc
;;

let write_file path content =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let path_of_node = function
  | `Assoc fields ->
    (match List.assoc_opt "path" fields with
     | Some (`String s) -> s
     | _ -> failwith "node missing path")
  | _ -> failwith "node not an Assoc"
;;

let paths nodes = List.map path_of_node nodes

(* Alcotest testable for the resolution variant so failures print the
   actual constructor instead of an opaque bool. *)
let resolution_tag = function
  | Ok _ -> "ok"
  | Error W.Path_traversal -> "rejected:traversal"
  | Error (W.Confidential_component c) -> "rejected:confidential:" ^ c
  | Error W.Symlink_escape -> "rejected:symlink_escape"
;;

let is_ok = function Ok _ -> true | Error _ -> false
let is_confidential = function
  | Error (W.Confidential_component _) -> true
  | _ -> false
;;
let is_symlink_escape = function
  | Error W.Symlink_escape -> true
  | _ -> false
;;
let is_traversal = function
  | Error W.Path_traversal -> true
  | _ -> false
;;

(* --- B1: secret denylist rejects confidential reads --- *)

let confidential_examples =
  (* (requested path, human label). Each must be rejected even when the
     file exists on disk. *)
  [ ".env", "root .env";
    ".env.local", "prefixed .env.local";
    "src/.env.production", "nested .env.production";
    ".masc/config/credentials.toml", "the concrete leak from the report";
    ".masc-ide/by-url/x/tool_events.jsonl", "keeper tool-event store";
    "credentials.toml", "root credentials file";
    "config/credentials", "nested credentials";
    ".git/config", "git config with credential URLs";
    ".ssh/id_rsa", "private key" ]
;;

let test_confidential_reads_rejected () =
  with_temp_dir (fun base ->
    (* Materialise each secret on disk so the guard — not a missing file —
       is what rejects the request. *)
    List.iter (fun (p, _) -> touch (Filename.concat base p)) confidential_examples;
    List.iter
      (fun (p, label) ->
        let got = W.For_testing.resolve_workspace_file base p in
        check bool ("confidential rejected: " ^ label) true (is_confidential got);
        check bool ("not accepted: " ^ label) false (is_ok got))
      confidential_examples)
;;

let test_confidential_case_insensitive () =
  (* A case-insensitive filesystem would serve [.ENV] as [.env]; the
     denylist must reject regardless of case rather than be bypassable. *)
  with_temp_dir (fun base ->
    List.iter
      (fun p ->
        check bool ("case-insensitive rejected: " ^ p) true
          (is_confidential (W.For_testing.resolve_workspace_file base p)))
      [ ".ENV"; ".Env.Local"; "Credentials.TOML"; ".SSH/id_rsa" ])
;;

let test_normal_source_file_allowed () =
  with_temp_dir (fun base ->
    List.iter (fun rel -> touch (Filename.concat base rel))
      [ "lib/main.ml"; "README.md"; "src/deep/nested/thing.ts" ];
    List.iter
      (fun rel ->
        let got = W.For_testing.resolve_workspace_file base rel in
        check
          string
          ("normal file allowed: " ^ rel)
          "ok" (resolution_tag got))
      [ "lib/main.ml"; "README.md"; "src/deep/nested/thing.ts" ])
;;

let test_parent_traversal_rejected () =
  with_temp_dir (fun base ->
    List.iter
      (fun p ->
        check bool ("traversal rejected: " ^ p) true
          (is_traversal (W.For_testing.resolve_workspace_file base p)))
      [ "../etc/passwd"; "a/../../b"; ".."; "lib/./../.." ])
;;

(* --- B2: symlink escape guard --- *)

let test_symlink_escape_rejected () =
  with_temp_dir (fun base ->
    (* Secret target lives OUTSIDE base (sibling temp file), reachable
       only by following the committed symlink. *)
    let outside = Filename.temp_file "ide-file-conf-secret" ".txt" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove outside with _ -> ())
      (fun () ->
        let oc = open_out outside in
        output_string oc "TOP SECRET";
        close_out oc;
        let link = Filename.concat base "evil" in
        Unix.symlink outside link;
        let got = W.For_testing.resolve_workspace_file base "evil" in
        check
          string
          "escaping symlink rejected"
          "rejected:symlink_escape" (resolution_tag got);
        check bool "escaping symlink not accepted" false (is_ok got)))
;;

let test_symlink_escape_via_dir_rejected () =
  with_temp_dir (fun base ->
    (* A symlinked *directory* component must also be caught: base/link ->
       /outside, then base/link/secret escapes even though the leaf
       "secret" is innocuous. *)
    let outside_dir = Filename.temp_file "ide-file-conf-dir" "" in
    Sys.remove outside_dir;
    Unix.mkdir outside_dir 0o700;
    Fun.protect
      ~finally:(fun () -> rm_rf outside_dir)
      (fun () ->
        touch (Filename.concat outside_dir "secret");
        Unix.symlink outside_dir (Filename.concat base "link");
        let got = W.For_testing.resolve_workspace_file base "link/secret" in
        check bool "escape through symlinked dir rejected" true
          (is_symlink_escape got)))
;;

let test_symlink_to_confidential_target_rejected () =
  with_temp_dir (fun base ->
    touch (Filename.concat base ".env");
    Unix.symlink (Filename.concat base ".env") (Filename.concat base "public_link");
    let got = W.For_testing.resolve_workspace_file base "public_link" in
    check
      string
      "in-base symlink to confidential target rejected"
      "rejected:confidential:.env" (resolution_tag got))
;;

let test_internal_symlink_allowed () =
  with_temp_dir (fun base ->
    (* A symlink pointing back inside the workspace stays allowed: it is a
       legitimate editor scenario and does not escape the base. *)
    touch (Filename.concat base "real.ml");
    Unix.symlink (Filename.concat base "real.ml") (Filename.concat base "link.ml");
    let got = W.For_testing.resolve_workspace_file base "link.ml" in
    check
      string
      "internal symlink allowed"
      "ok" (resolution_tag got))
;;

let resolve_for_read base requested =
  match W.For_testing.resolve_workspace_file base requested with
  | Ok file -> file
  | Error W.Path_traversal -> failwith "unexpected traversal rejection"
  | Error (W.Confidential_component c) ->
    failwith ("unexpected confidential rejection: " ^ c)
  | Error W.Symlink_escape -> failwith "unexpected symlink escape rejection"
;;

let test_read_internal_symlink_uses_resolved_target () =
  with_temp_dir (fun base ->
    let real = Filename.concat base "real.ml" in
    write_file real "let safe = true\n";
    Unix.symlink real (Filename.concat base "link.ml");
    let file = resolve_for_read base "link.ml" in
    match W.For_testing.load_workspace_file_content file with
    | Ok content -> check string "reads resolved in-workspace target" "let safe = true\n" content
    | Error _ -> fail "expected internal symlink read to succeed")
;;

let test_read_rejects_post_resolution_symlink_swap () =
  with_temp_dir (fun base ->
    let victim = Filename.concat base "victim.txt" in
    write_file victim "safe";
    let file = resolve_for_read base "victim.txt" in
    let outside = Filename.temp_file "ide-file-conf-post-resolve" ".txt" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove outside with _ -> ())
      (fun () ->
        write_file outside "TOP SECRET";
        Sys.remove victim;
        Unix.symlink outside victim;
        match W.For_testing.load_workspace_file_content file with
        | Error W.File_not_regular -> ()
        | Ok content -> fail ("unexpectedly read swapped symlink: " ^ content)
        | Error _ -> fail "expected swapped symlink to be rejected as non-regular"))
;;

let test_read_size_cap_rejects_large_file () =
  with_temp_dir (fun base ->
    let path = Filename.concat base "large.txt" in
    write_file path "1234";
    let file = resolve_for_read base "large.txt" in
    match W.For_testing.load_workspace_file_content ~max_bytes:3 file with
    | Error (W.File_too_large 4) -> ()
    | Ok content -> fail ("unexpectedly read oversized file: " ^ content)
    | Error _ -> fail "expected typed File_too_large error")
;;

(* --- (e) denylist SSOT is consistent with the tree listing --- *)

let test_denylist_matches_tree_hidden () =
  with_temp_dir (fun base ->
    (* Populate the tree with confidential entries + a legit file. Every
       confidential component the read guard blocks must also be absent
       from the tree, proving both consume the same SSOT. *)
    mkdir_p (Filename.concat base ".masc/config");
    touch (Filename.concat base ".masc/config/credentials.toml");
    mkdir_p (Filename.concat base ".masc-ide/by-url");
    touch (Filename.concat base ".masc-ide/by-url/tool_events.jsonl");
    mkdir_p (Filename.concat base ".git");
    touch (Filename.concat base ".git/config");
    touch (Filename.concat base ".env");
    touch (Filename.concat base "credentials.toml");
    mkdir_p (Filename.concat base ".ssh");
    touch (Filename.concat base ".ssh/id_rsa");
    touch (Filename.concat base "lib/main.ml");
    let ps = paths (W.scan_dir ~base ~depth:0 ~max_depth:3 ~max_nodes:500 [] base) in
    let top_components =
      [ ".masc"; ".masc-ide"; ".git"; ".env"; "credentials.toml"; ".ssh" ]
    in
    List.iter
      (fun name ->
        (* SSOT predicate agrees the component is confidential ... *)
        check bool (name ^ " is confidential") true (W.component_is_confidential name);
        (* ... and the tree hides it. *)
        check bool (name ^ " hidden from tree") false (List.mem name ps))
      top_components;
    check bool "legit lib file present in tree" true
      (List.exists (fun p -> p = "lib" || p = "lib/main.ml") ps))
;;

let test_tree_does_not_follow_symlinked_dir_escape () =
  with_temp_dir (fun base ->
    let outside_dir = Filename.temp_file "ide-file-conf-tree-dir" "" in
    Sys.remove outside_dir;
    Unix.mkdir outside_dir 0o700;
    Fun.protect
      ~finally:(fun () -> rm_rf outside_dir)
      (fun () ->
        touch (Filename.concat outside_dir "outside_secret_name");
        Unix.symlink outside_dir (Filename.concat base "link");
        let ps =
          paths (W.scan_dir ~base ~depth:0 ~max_depth:3 ~max_nodes:500 [] base)
        in
        check bool "symlink entry itself can be listed" true (List.mem "link" ps);
        check bool "tree does not recurse into escaped symlink dir" false
          (List.mem "link/outside_secret_name" ps)))
;;

(* The node budget bounds the response; it must not decide which directories
   are reachable. A depth-first walk spent the whole budget inside whatever
   sorted first, so on a real repository [lib/] was absent from the tree and
   the client had nothing to expand — the seed has to cover breadth, and the
   client loads a directory's real contents on expand. *)
let test_tree_seed_reaches_every_top_level_directory () =
  with_temp_dir (fun base ->
    (* An early directory deep and wide enough to exhaust the budget on its
       own, and a later one holding the file we must still be able to reach. *)
    for i = 0 to 19 do
      let branch = Printf.sprintf "aaa_early/branch_%02d" i in
      mkdir_p (Filename.concat base branch);
      for j = 0 to 19 do
        touch (Filename.concat base (Printf.sprintf "%s/leaf_%02d.ml" branch j))
      done
    done;
    mkdir_p (Filename.concat base "zzz_late");
    touch (Filename.concat base "zzz_late/wanted.ml");
    let ps = paths (W.scan_dir ~base ~depth:0 ~max_depth:8 ~max_nodes:100 [] base) in
    check bool "early directory is present" true (List.mem "aaa_early" ps);
    check
      bool
      "late directory survives the budget"
      true
      (List.mem "zzz_late" ps))
;;

let test_noise_dirs_not_confidential () =
  (* Noise dirs are hidden from the tree but are NOT secrets: a read under
     them is allowed, so [component_is_confidential] must stay false for
     them (guards the SSOT split against accidental over-blocking). *)
  List.iter
    (fun name ->
      check bool (name ^ " not confidential") false (W.component_is_confidential name))
    [ "node_modules"; "_build"; "dist"; "build"; ".worktrees"; ".cache" ]
;;

let catalog_git ~cwd args =
  match Repo_git.run_git ~cwd args with
  | Ok _ -> ()
  | Error detail -> Alcotest.fail detail

let catalog_or_fail ~base ~path =
  match W.For_testing.workspace_file_catalog ~base ~path with
  | Ok catalog -> catalog
  | Error W.Catalog_invalid_path -> Alcotest.fail "unexpected invalid catalog path"
  | Error W.Catalog_directory_unavailable -> Alcotest.fail "catalog directory unavailable"
  | Error W.Catalog_repository_unavailable -> Alcotest.fail "catalog repository unavailable"
  | Error (W.Catalog_scan_failed detail) -> Alcotest.fail detail

let test_catalog_lists_checkout_with_file_read_guards () =
  with_temp_dir (fun base ->
    with_temp_dir (fun outside ->
      catalog_git ~cwd:base [ "init"; "-b"; "main" ];
      write_file (Filename.concat base "src/selected.ml") "selected\n";
      write_file (Filename.concat base "elsewhere/새 파일\n이름.ml") "other\n";
      write_file (Filename.concat base ".gitignore") "*.ignored\n";
      write_file (Filename.concat base "hidden.ignored") "ignored\n";
      write_file (Filename.concat base "tracked.ignored") "tracked\n";
      write_file (Filename.concat base "deleted.ml") "gone\n";
      catalog_git ~cwd:base [ "add"; "--force"; "--"; "tracked.ignored"; "deleted.ml" ];
      Sys.remove (Filename.concat base "deleted.ml");
      write_file (Filename.concat base ".env") "secret\n";
      write_file (Filename.concat base "keys/credentials.json") "secret\n";
      write_file (Filename.concat base ".masc/state") "internal\n";
      write_file (Filename.concat outside "secret") "outside\n";
      Unix.symlink (Filename.concat outside "secret") (Filename.concat base "escape");
      Unix.symlink ".env" (Filename.concat base "alias-secret");
      Unix.symlink "src/selected.ml" (Filename.concat base "alias-source");
      (* Both files exist: a POSIX backslash name must not open the slash name. *)
      write_file (Filename.concat base "src\\selected.ml") "different\n";
      let catalog = catalog_or_fail ~base ~path:"src" in
      check string "root stays workspace relative" "" catalog.catalog_root;
      check (list string) "whole checkout obeys file read policy"
        (List.sort String.compare
           [ ".gitignore"; "alias-source"; "elsewhere/새 파일\n이름.ml"
           ; "src/selected.ml"; "tracked.ignored" ])
        catalog.catalog_paths;
      List.iter
        (fun path ->
          match W.For_testing.resolve_workspace_file base path with
          | Error _ -> Alcotest.fail "catalog selection cannot resolve for file reading"
          | Ok file ->
              match W.For_testing.load_workspace_file_content file with
              | Ok _ -> ()
              | Error _ -> Alcotest.fail "catalog selection cannot be read")
        catalog.catalog_paths))

let test_catalog_never_searches_above_workspace () =
  with_temp_dir (fun parent ->
    catalog_git ~cwd:parent [ "init"; "-b"; "main" ];
    let base = Filename.concat parent "keeper" in
    mkdir_p base;
    (match W.For_testing.workspace_file_catalog ~base ~path:"" with
     | Error W.Catalog_repository_unavailable -> ()
     | Ok _ -> Alcotest.fail "catalog borrowed the enclosing checkout"
     | Error _ -> Alcotest.fail "expected absence of an owned repository");
    let repo = Filename.concat base "repos/example" in
    mkdir_p (Filename.concat repo "src");
    catalog_git ~cwd:repo [ "init"; "-b"; "main" ];
    write_file (Filename.concat repo "src/one.ml") "one\n";
    write_file (Filename.concat repo "two.ml") "two\n";
    let catalog = catalog_or_fail ~base ~path:"repos/example/src" in
    check string "owning nested checkout" "repos/example" catalog.catalog_root;
    check (list string) "paths retain Keeper bundle prefix"
      [ "repos/example/src/one.ml"; "repos/example/two.ml" ] catalog.catalog_paths)

let test_catalog_distinguishes_empty_from_unavailable () =
  with_temp_dir (fun base ->
    catalog_git ~cwd:base [ "init"; "-b"; "main" ];
    let catalog = catalog_or_fail ~base ~path:"" in
    check (list string) "a genuine empty checkout" [] catalog.catalog_paths;
    (match W.For_testing.workspace_file_catalog ~base ~path:".env" with
     | Error W.Catalog_invalid_path -> ()
     | Ok _ | Error _ -> Alcotest.fail "confidential catalog directory was not rejected");
    (match W.For_testing.workspace_file_catalog ~base ~path:"missing" with
     | Error W.Catalog_directory_unavailable -> ()
     | Ok _ | Error _ -> Alcotest.fail "missing directory became an empty catalog");
    rm_rf (Filename.concat base ".git");
    write_file (Filename.concat base ".git") "gitdir: missing-git-dir\n";
    match W.For_testing.workspace_file_catalog ~base ~path:"" with
    | Error (W.Catalog_scan_failed _) -> ()
    | Ok _ | Error _ -> Alcotest.fail "Git failure became empty or missing checkout")

(* Use the production router and file reader: a surviving project file must
   never stand in for the selected scope after its catalog was accepted. *)
let workspace_http_response ?(meth = "GET") ?(body = "") ?token ~router target =
  let output = Buffer.create 1024 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd) in
  let authorization = match token with None -> "" | Some token -> "Authorization: Bearer " ^ token ^ "\r\n" in
  let raw = Printf.sprintf "%s %s HTTP/1.0\r\nHost: localhost\r\n%sContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
      meth target authorization (String.length body) body in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw) raw in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0
            ~len:(Bigstringaf.length input));
  let rec drain () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
        let written = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
          Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
          total + iov.len) 0 iovecs in
        Httpun.Server_connection.report_write_result connection (`Ok written);
        drain ()
    | `Yield when Buffer.length output = 0 ->
        let ready, resolve = Eio.Promise.create () in
        Httpun.Server_connection.yield_writer connection
          (fun () -> Eio.Promise.resolve resolve ());
        Eio.Promise.await ready;
        drain ()
    | `Yield | `Close _ -> ()
  in
  drain ();
  let raw = Buffer.contents output in
  let boundary = Str.search_forward (Str.regexp_string "\r\n\r\n") raw 0 in
  let status = int_of_string (List.nth (String.split_on_char ' ' raw) 1) in
  status, Yojson.Safe.from_string
    (String.sub raw (boundary + 4) (String.length raw - boundary - 4))

type lost_file_scope =
  | Repository_scope of [ `Registration | `Directory ]
  | Keeper_scope of [ `Metadata | `Directory ]

let check_workspace_http_status label expected status body =
  if status <> expected then
    failf "%s: expected HTTP %d, received HTTP %d; body: %s"
      label expected status (Yojson.Safe.to_string body)

let test_file_read_rejects_lost_scope lost () =
  let old_state = Server_auth.For_testing.snapshot_server_state () in
  let old_startup = Masc.Server_startup_state.snapshot () in
  let old_fs = Fs_compat.get_fs_opt () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state old_state;
      Masc.Server_startup_state.For_testing.restore old_startup;
      match old_fs with
      | Some fs -> Fs_compat.set_fs fs
      | None -> Fs_compat.clear_fs ())
    (fun () ->
      Masc_test_deps.with_process_env "MASC_HTTP_AUTH_STRICT" (Some "0") (fun () ->
        Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Eio_context.with_test_env ~net:(Eio.Stdenv.net env)
          ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
          (fun () -> with_temp_dir (fun base_path ->
            let valid = function Ok value -> value | Error detail -> fail detail in
            let state = Masc.Mcp_server.create_state_eio ~sw
              ~proc_mgr:(Eio.Stdenv.process_mgr env) ~fs:(Eio.Stdenv.fs env)
              ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env)
              ~net:(Eio.Stdenv.net env) ~base_path in
            let config = Masc.Mcp_server.workspace_config state in
            ignore (Masc.Workspace.init config ~agent_name:None);
          Masc.Mcp_server.For_testing.await_publication_recovery_initialization state;
            Auth.save_auth_config base_path
              { Masc_domain.default_auth_config with enabled = true; require_token = true };
            let token =
              match Auth.create_token base_path ~agent_name:"selected-file-editor"
                      ~role:Masc_domain.Admin with
              | Ok (raw, _) -> raw
              | Error _ -> fail "could not create selected scope fixture token"
            in
            Server_auth.For_testing.restore_server_state (Some state);
            (match Masc.Server_startup_state.mark_state_ready () with
             | Ok () -> ()
             | Error error -> fail (Masc.Server_startup_state.state_ready_error_to_string error));
            let path = "src/selected.ml" in
            let project_content = "let project_file = true\n" in
            let selected_content = "let selected_scope = true\n" in
            write_file (Filename.concat base_path path) project_content;
            let root, scope, withdraw =
              match lost with
              | Repository_scope removed ->
                  let root = Filename.concat base_path "checkout" in
                  mkdir_p root;
                  let repository : Repo_manager_types.repository =
                    { id = "selected"; name = "selected"; url = root; local_path = root;
                      aliases = []; default_branch = "main"; keepers = [];
                      status = Repo_manager_types.Active; auto_sync = false;
                      sync_interval = 0; created_at = Int64.zero; updated_at = Int64.zero } in
                  valid (Repo_store.save_all ~base_path [repository]);
                  let withdraw () = match removed with
                    | `Registration -> valid (Repo_store.remove ~base_path repository.id)
                    | `Directory -> rm_rf root in
                  root, "repo_id=selected", withdraw
              | Keeper_scope removed ->
                  let meta = valid (Masc_test_deps.meta_of_json_fixture
                      (`Assoc ["name", `String "selected"])) in
                  let declaration = Config_dir_resolver.keeper_toml_path_for_base_path
                      ~base_path meta.name in
                  write_file declaration
                    "[keeper]\ninstructions = \"Scoped file read fixture\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\n";
                  valid (Masc.Keeper_meta_store.replace_snapshot config meta);
                  let meta =
                    match Masc.Keeper_meta_store.read_effective_meta config meta.name with
                    | Ok (Some effective) -> effective
                    | Ok None -> fail "fixture Keeper metadata is unavailable"
                    | Error detail -> failf "fixture Keeper configuration: %s" detail in
                  let root = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
                  mkdir_p root;
                  let withdraw () = match removed with
                    | `Metadata -> valid (Masc.Keeper_meta_store.remove_snapshot config ~name:meta.name)
                    | `Directory -> rm_rf root in
                  root, "keeper=selected", withdraw
            in
            catalog_git ~cwd:root ["init"; "-b"; "main"];
            write_file (Filename.concat root path) selected_content;
            let encode = Uri.pct_encode ~component:`Query_value in
            let binding = "expected_base_path=" ^ encode (Unix.realpath base_path)
              ^ "&expected_masc_root=" ^ encode (Unix.realpath (Masc.Workspace.masc_dir config)) in
            let router = W.add_routes (Masc.Http_server_eio.Router.create ()) in
            let request route path = workspace_http_response ~token ~router
                (route ^ "?path=" ^ encode path ^ "&" ^ scope ^ "&" ^ binding) in
            let status, catalog = request "/api/v1/workspace/files" "" in
            check_workspace_http_status "selected scope catalog succeeds" 200 status catalog;
            check (list string) "catalog preserves selected file path" [path]
              Yojson.Safe.Util.(catalog |> member "files" |> to_list |> List.map to_string);
            let status, body = request "/api/v1/workspace/file" path in
            check_workspace_http_status "selected scope file succeeds" 200 status body;
            check string "reads the selected scope, not its project namesake" selected_content
              Yojson.Safe.Util.(body |> member "content" |> to_string);
            let expected_revision = Yojson.Safe.Util.(body |> member "revision" |> to_string) in
            let save content expected_revision =
              let body = Yojson.Safe.to_string (`Assoc ["path", `String path;
                "expected_revision", `String expected_revision; "content", `String content;
                "expected_workspace", `Assoc ["base_path", `String (Unix.realpath base_path);
                  "masc_root", `String (Unix.realpath (Masc.Workspace.masc_dir config))]]) in
              workspace_http_response ~meth:"POST" ~body ~token ~router ("/api/v1/workspace/file?" ^ scope) in
            let edited_content = "let selected_scope = \"edited\"\n" in
            let status, saved = save edited_content expected_revision in
            check_workspace_http_status "selected scope save succeeds" 200 status saved;
            let status, edited = request "/api/v1/workspace/file" path in
            check_workspace_http_status "saved selected file rereads" 200 status edited;
            check string "write reaches the selected scope" edited_content
              Yojson.Safe.Util.(edited |> member "content" |> to_string);
            withdraw ();
            let status, refused = save "must not reach project\n"
                Yojson.Safe.Util.(saved |> member "revision" |> to_string) in
            check_workspace_http_status "lost scope cannot write its project namesake" 404 status refused;
            let status, body = request "/api/v1/workspace/file" path in
            check_workspace_http_status "lost scope cannot read its project namesake" 404 status body;
            check bool "scope refusal carries no file content" true
              (Yojson.Safe.Util.member "content" body = `Null);
            let status, body = request "/api/v1/workspace/files" "" in
            check_workspace_http_status "catalog and selected file agree on unavailable scope" 404 status body;
            let status, body = workspace_http_response ~token ~router
                ("/api/v1/workspace/file?path=" ^ encode path ^ "&" ^ binding) in
            check_workspace_http_status "explicit project reading remains available" 200 status body;
            check string "the same-named project file really exists" project_content
              Yojson.Safe.Util.(body |> member "content" |> to_string)))))

let with_save_files f =
  let old_fs = Fs_compat.get_fs_opt () in
  Fun.protect ~finally:(fun () -> match old_fs with
    | Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ())
    (fun () -> Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      with_temp_dir (fun recovery_root ->
        Eio.Switch.run @@ fun sw ->
        let registry =
          match Fs_compat.Publication_recovery.open_registry ~sw
              ~fs:(Eio.Stdenv.fs env)
              ~registry_root:Eio.Path.(Eio.Stdenv.fs env / recovery_root) with
          | Ok registry -> registry
          | Error error -> fail (Fs_compat.Publication_recovery.registry_error_to_string error)
        in
        let publication_recovery = Masc_test_deps.publication_recovery_provider registry in
        with_temp_dir (f ~publication_recovery)))

let observed_file ~base path =
  match W.For_testing.resolve_workspace_file base path with
  | Error _ -> fail "fixture file cannot be resolved"
  | Ok file -> match W.For_testing.load_workspace_file_content file with
    | Error _ -> fail "fixture file cannot be read"
    | Ok content -> content, W.For_testing.workspace_file_revision ~base file content

let save_ok = function
  | Ok revision -> revision
  | Error _ -> fail "expected an admitted file save"

let test_file_save_revision_and_exact_bytes () = with_save_files (fun ~publication_recovery base ->
  let path = "src/program.ml" in
  let full = Filename.concat base path in
  let original = "\tlet text = \"e\204\129\"\r\n" in
  write_file full original;
  Unix.chmod full 0o755;
  let content, revision = observed_file ~base path in
  check string "original bytes remain exact" original content;
  let edited = "\tlet text = \"한글🙂\"\r\n" in
  let saved = save_ok (W.For_testing.save_workspace_file ~publication_recovery ~base ~path ~expected_revision:revision ~content:edited) in
  let actual, observed = observed_file ~base path in
  check string "committed bytes, not displayed rows" edited actual;
  check string "returned revision describes committed bytes" saved observed;
  check int "ordinary executable permissions survive" 0o755 (Unix.stat full).Unix.st_perm;
  (match W.For_testing.save_workspace_file ~publication_recovery ~base ~path ~expected_revision:revision ~content:"stale" with
   | Error W.Save_conflict -> () | Ok _ | Error _ -> fail "stale revision must conflict");
  check string "conflict preserves current file" edited (fst (observed_file ~base path));
  check string "unchanged source is idempotent" saved
    (save_ok (W.For_testing.save_workspace_file ~publication_recovery ~base ~path ~expected_revision:saved ~content:edited));
  ignore (save_ok (W.For_testing.save_workspace_file ~publication_recovery ~base ~path ~expected_revision:saved ~content:""));
  check string "an intentionally empty file saves" "" (fst (observed_file ~base path)))

let test_file_save_scope_and_path_guards () = with_save_files (fun ~publication_recovery base ->
  with_temp_dir (fun other ->
    let path = "source.ml" in
    write_file (Filename.concat base path) "original";
    write_file (Filename.concat other path) "original";
    let _, revision = observed_file ~base path in
    (match W.For_testing.save_workspace_file ~publication_recovery ~base:other ~path ~expected_revision:revision ~content:"wrong workspace" with
     | Error W.Save_conflict -> () | Ok _ | Error _ -> fail "revision cannot move between roots");
    Unix.symlink (Filename.concat other path) (Filename.concat base "escape.ml");
    write_file (Filename.concat base ".env") "secret";
    List.iter (fun path ->
      match W.For_testing.save_workspace_file ~publication_recovery ~base ~path ~expected_revision:revision ~content:"forbidden" with
      | Error W.Save_invalid_path -> () | Ok _ | Error _ -> fail "read path guards must also reject writes")
      ["escape.ml"; ".env"; "../source.ml"];
    check string "other workspace remains intact" "original" (fst (observed_file ~base:other path));
    Unix.symlink path (Filename.concat base "alias.ml");
    ignore (save_ok (W.For_testing.save_workspace_file ~publication_recovery ~base ~path:"alias.ml" ~expected_revision:revision ~content:"through alias"));
    check string "internal alias retains link identity" path (Unix.readlink (Filename.concat base "alias.ml"));
    check string "internal alias updates its permitted target" "through alias" (fst (observed_file ~base path))))

let test_file_save_competing_revisions () = with_save_files (fun ~publication_recovery base ->
  let path = "source.ml" in
  write_file (Filename.concat base path) "initial";
  let _, expected_revision = observed_file ~base path in
  let save content = W.For_testing.save_workspace_file ~publication_recovery ~base ~path ~expected_revision ~content in
  let first, second = Eio.Fiber.pair (fun () -> save "first") (fun () -> save "second") in
  let winner = match first, second with
    | Ok _, Error W.Save_conflict -> "first"
    | Error W.Save_conflict, Ok _ -> "second"
    | (Ok _ | Error _), (Ok _ | Error _) -> fail "one revision can commit only once" in
  check string "the admitted writer owns the file" winner (fst (observed_file ~base path)))

let read_test_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let check_save_after_directory_swap ~publication_recovery ~base ~path
    ~original_path ~replacement_path ~outside =
  let content = "original permitted bytes" in
  let sentinel = "outside sentinel must survive" in
  let edited = "edited permitted bytes" in
  write_file (Filename.concat base path) content;
  let outside_target = Filename.concat outside (Filename.basename path) in
  write_file outside_target sentinel;
  let outside_names () = Array.to_list (Sys.readdir outside) |> List.sort String.compare in
  let initial_outside_names = outside_names () in
  let _, expected_revision = observed_file ~base path in
  let displaced = original_path ^ ".held" in
  let before_publication_called = ref false in
  let original_moved = ref false in
  let link_installed = ref false in
  Fun.protect
    ~finally:(fun () ->
      if !link_installed then Unix.unlink original_path;
      if !original_moved then Unix.rename displaced original_path)
    (fun () ->
      let result = W.For_testing.save_workspace_file_before_publication
          ~before_publication:(fun () ->
            check bool "publication boundary occurs once" false !before_publication_called;
            before_publication_called := true;
            Unix.rename original_path displaced;
            original_moved := true;
            Unix.symlink replacement_path original_path;
            link_installed := true)
          ~publication_recovery ~base ~path ~expected_revision ~content:edited in
      check bool "swap occurs after the genuine revision comparison" true !before_publication_called;
      check string "outside target is unchanged" sentinel (read_test_file outside_target);
      check (list string) "no staging entry appears outside the permitted root"
        initial_outside_names (outside_names ());
      let original_target =
        if String.equal original_path base then Filename.concat displaced path
        else Filename.concat displaced (Filename.basename path) in
      Result.fold
        ~ok:(fun _ -> check string "success updates only the held original parent"
          edited (read_test_file original_target))
        ~error:(fun _ ->
          let actual = read_test_file original_target in
          check bool "refusal or uncertainty retains complete original or edited bytes"
            true (String.equal actual content || String.equal actual edited))
        result)

let test_file_save_parent_swap_confined () =
  with_save_files (fun ~publication_recovery base ->
    with_temp_dir (fun outside ->
      check_save_after_directory_swap ~publication_recovery ~base
        ~path:"src/source.ml" ~original_path:(Filename.concat base "src")
        ~replacement_path:outside ~outside))

let test_file_save_root_swap_confined () =
  with_save_files (fun ~publication_recovery base ->
    with_temp_dir (fun outside ->
      check_save_after_directory_swap ~publication_recovery ~base
        ~path:"source.ml" ~original_path:base ~replacement_path:outside ~outside))

let test_file_save_http_authority () =
  let old_state = Server_auth.For_testing.snapshot_server_state () in
  let old_startup = Masc.Server_startup_state.snapshot () in
  let old_fs = Fs_compat.get_fs_opt () in
  Fun.protect ~finally:(fun () ->
    Server_auth.For_testing.restore_server_state old_state;
    Masc.Server_startup_state.For_testing.restore old_startup;
    match old_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ())
    (fun () -> Masc_test_deps.with_process_env "MASC_HTTP_AUTH_STRICT" (Some "0") (fun () ->
      Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio_context.with_test_env ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
        (fun () -> with_temp_dir (fun base_path ->
          let state = Masc.Mcp_server.create_state_eio ~sw
              ~proc_mgr:(Eio.Stdenv.process_mgr env) ~fs:(Eio.Stdenv.fs env)
              ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env)
              ~net:(Eio.Stdenv.net env) ~base_path in
          let config = Masc.Mcp_server.workspace_config state in
          ignore (Masc.Workspace.init config ~agent_name:None);
          Masc.Mcp_server.For_testing.await_publication_recovery_initialization state;
          Auth.save_auth_config base_path
            { Masc_domain.default_auth_config with enabled = true; require_token = true };
          let token agent_name role = match Auth.create_token base_path ~agent_name ~role with
            | Ok (raw, _) -> raw | Error _ -> fail "could not create fixture token" in
          let admin = token "file-editor" Masc_domain.Admin in
          let worker = token "file-worker" Masc_domain.Worker in
          Server_auth.publish_server_state state;
          (match Masc.Server_startup_state.mark_state_ready () with
           | Ok () -> () | Error _ -> fail "fixture server not ready");
          let path = "program.ml" in
          write_file (Filename.concat base_path path) "initial";
          let router = W.add_routes (Masc.Http_server_eio.Router.create ()) in
          let status, document = workspace_http_response ~token:admin ~router
              ("/api/v1/workspace/file?path=" ^ path) in
          check_workspace_http_status "Admin reads revision" 200 status document;
          let revision = Yojson.Safe.Util.(document |> member "revision" |> to_string) in
          let expected_workspace = `Assoc ["base_path", `String (Unix.realpath base_path);
            "masc_root", `String (Unix.realpath (Masc.Workspace.masc_dir config))] in
          let fields = ["path", `String path; "content", `String "edited";
            "expected_revision", `String revision; "expected_workspace", expected_workspace] in
          let send ?token fields = workspace_http_response ?token ~router ~meth:"POST"
              ~body:(Yojson.Safe.to_string (`Assoc fields)) "/api/v1/workspace/file" in
          List.iter (fun (token, expected) ->
            let status, body = send ?token fields in
            check_workspace_http_status "unauthorized save is refused" expected status body;
            check string "denied writes preserve original" "initial" (fst (observed_file ~base:base_path path)))
            [None, 401; Some worker, 403];
          let status, body = send ~token:admin (List.remove_assoc "expected_workspace" fields) in
          check_workspace_http_status "save requires confirmed workspace" 400 status body;
          let wrong = `Assoc ["base_path", `String (Filename.concat (Unix.realpath base_path) "other");
            "masc_root", `String (Unix.realpath (Masc.Workspace.masc_dir config))] in
          let status, body = send ~token:admin (("expected_workspace", wrong) :: List.remove_assoc "expected_workspace" fields) in
          check_workspace_http_status "another workspace cannot write" 409 status body;
          let status, body = send ~token:admin fields in
          check_workspace_http_status "Admin saves observed revision" 200 status body;
          check string "routed write publishes candidate" "edited" (fst (observed_file ~base:base_path path));
          let status, body = send ~token:admin fields in
          check_workspace_http_status "old revision is not silently retried" 409 status body;
          check string "file conflict has typed wire code" "workspace_file_changed"
            Yojson.Safe.Util.(body |> member "code" |> to_string)))))

let () =
  run
    "workspace_file_confidentiality"
    [ ( "B1 secret denylist"
      , [ test_case "confidential reads rejected" `Quick test_confidential_reads_rejected
        ; test_case
            "confidential match is case-insensitive"
            `Quick
            test_confidential_case_insensitive
        ; test_case "normal source file allowed" `Quick test_normal_source_file_allowed
        ; test_case "parent traversal rejected" `Quick test_parent_traversal_rejected
        ] )
    ; ( "B2 symlink escape guard"
      , [ test_case "escaping symlink rejected" `Quick test_symlink_escape_rejected
        ; test_case
            "escape through symlinked dir rejected"
            `Quick
            test_symlink_escape_via_dir_rejected
        ; test_case
            "in-base symlink to confidential target rejected"
            `Quick
            test_symlink_to_confidential_target_rejected
        ; test_case "internal symlink allowed" `Quick test_internal_symlink_allowed
        ; test_case
            "file read uses resolved internal symlink target"
            `Quick
            test_read_internal_symlink_uses_resolved_target
        ; test_case
            "file read rejects post-resolution symlink swap"
            `Quick
            test_read_rejects_post_resolution_symlink_swap
        ; test_case
            "file read enforces size cap"
            `Quick
            test_read_size_cap_rejects_large_file
        ] )
    ; ( "file catalog"
      , [ test_case "whole checkout shares file read guards" `Quick
            test_catalog_lists_checkout_with_file_read_guards
        ; test_case "stops at selected workspace and retains nested scope" `Quick
            test_catalog_never_searches_above_workspace
        ; test_case "distinguishes empty checkout and unavailable directory" `Quick
            test_catalog_distinguishes_empty_from_unavailable
        ] )
    ; ( "selected file scope"
      , [ test_case "removed repository registration cannot read project file" `Quick
            (test_file_read_rejects_lost_scope (Repository_scope `Registration))
        ; test_case "removed repository directory cannot read project file" `Quick
            (test_file_read_rejects_lost_scope (Repository_scope `Directory))
        ; test_case "removed Keeper metadata cannot read project file" `Quick
            (test_file_read_rejects_lost_scope (Keeper_scope `Metadata))
        ; test_case "removed Keeper directory cannot read project file" `Quick
            (test_file_read_rejects_lost_scope (Keeper_scope `Directory))
        ] )
    ; ( "SSOT consistency"
      , [ test_case "denylist matches tree hidden" `Quick test_denylist_matches_tree_hidden
        ; test_case
            "tree does not follow escaped symlink dirs"
            `Quick
            test_tree_does_not_follow_symlinked_dir_escape
        ; test_case "noise dirs are not confidential" `Quick test_noise_dirs_not_confidential
        ; test_case
            "tree seed reaches every top-level directory"
            `Quick
            test_tree_seed_reaches_every_top_level_directory
        ] )
    ; ( "revision-bound file writes"
      , [ test_case "exact bytes, executable mode, stale revision and empty save" `Quick test_file_save_revision_and_exact_bytes
        ; test_case "workspace roots, path guards and internal aliases" `Quick test_file_save_scope_and_path_guards
        ; test_case "competing same-revision writers" `Quick test_file_save_competing_revisions
        ; test_case "parent replaced by outside symlink after comparison" `Quick test_file_save_parent_swap_confined
        ; test_case "root replaced by outside symlink after comparison" `Quick test_file_save_root_swap_confined ] )
    ; ( "file write HTTP authority"
      , [test_case "Admin, canonical workspace and observed revision" `Quick test_file_save_http_authority] )
    ]
;;

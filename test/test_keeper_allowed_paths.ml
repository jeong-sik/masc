(** Test suite for Keeper_alerting_path.effective_allowed_paths.
    Verifies single-sandbox defaults, wildcard handling, and explicit
    allowed_paths behavior. Workspace/local scope no longer grants any
    hardcoded repo-root or state paths. *)

open Alcotest
module KAP = Masc_mcp.Keeper_alerting_path
module KES = Masc_mcp.Keeper_exec_shared
module KS = Masc_mcp.Keeper_sandbox
module KT = Masc_mcp.Keeper_types
module KTU = Masc_mcp.Keeper_turn_up_args

let make_meta ?(execution_scope = "observe_only") ?(allowed_paths = [])
    ~name () =
  let json = `Assoc [
    ("name", `String name);
    ("agent_name", `String ("agent-" ^ name));
    ("trace_id", `String ("trace-" ^ name));
    ("goal", `String "test");
    ("execution_scope", `String execution_scope);
    ("allowed_paths", `List (List.map (fun s -> `String s) allowed_paths));
  ] in
  match KT.meta_of_json json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta: " ^ err)

let sandbox_roots name =
  [ KAP.sandbox_path_of_keeper name ]

(* After #6527 iter 4, `.worktrees/` is no longer a workspace default.
   New worktrees land inside the keeper's own
   `.masc/playground/<keeper>/repos/<clone>/.worktrees/...` and are
   already covered by the sandbox root above. *)
let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () ->
    let rec rm dir =
      if Sys.file_exists dir then
        if Sys.is_directory dir then begin
          Sys.readdir dir
          |> Array.iter (fun name -> rm (Filename.concat dir name));
          Unix.rmdir dir
        end else
          Sys.remove dir
    in
    rm path
  ) (fun () -> f path)

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let playground_root_of_config config keeper_name =
  Filename.concat
    (KAP.project_root_of_config config)
    (KAP.playground_path_of_keeper keeper_name)

let create_sandbox_repo ~config ~(meta : KT.keeper_meta) repo_name =
  let repo_root =
    Filename.concat (playground_root_of_config config meta.name) ("repos/" ^ repo_name)
  in
  ensure_dir repo_root;
  ensure_dir (Filename.concat repo_root ".git");
  repo_root

(* ── observe_only scope ── *)

let test_observe_only_empty_paths () =
  let meta = make_meta ~execution_scope:"observe_only" ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "observe_only + [] = sandbox root"
    (sandbox_roots "t") effective

let test_observe_only_explicit_paths () =
  let meta = make_meta ~execution_scope:"observe_only"
      ~allowed_paths:["src/"; "lib/"] ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "observe_only + explicit = sandbox root + explicit"
    (sandbox_roots "t" @ ["src/"; "lib/"]) effective

(* ── workspace scope ── *)

let test_workspace_empty_paths_playground_only () =
  let meta = make_meta ~execution_scope:"workspace"
      ~name:"sangsu" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "workspace + [] = sandbox root only"
    (sandbox_roots "sangsu") effective

let test_workspace_explicit_paths () =
  let meta = make_meta ~execution_scope:"workspace"
      ~allowed_paths:["src/"; "docs/"] ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "workspace + explicit = sandbox root + explicit"
    (sandbox_roots "t" @ ["src/"; "docs/"]) effective

let test_workspace_write_paths_playground_only () =
  let meta = make_meta ~execution_scope:"workspace"
      ~name:"sangsu" () in
  let effective = KAP.effective_write_allowed_paths ~meta in
  check (list string) "workspace write defaults are sandbox-only"
    (sandbox_roots "sangsu") effective

let test_workspace_write_paths_preserve_explicit_overrides () =
  let meta = make_meta ~execution_scope:"workspace"
      ~allowed_paths:["workspace/yousleepwhen/oas/"] ~name:"t" () in
  let effective = KAP.effective_write_allowed_paths ~meta in
  check (list string) "explicit write override preserved"
    (sandbox_roots "t" @ ["workspace/yousleepwhen/oas/"]) effective

let test_workspace_star_wildcard () =
  let meta = make_meta ~execution_scope:"workspace"
      ~allowed_paths:["*"] ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "workspace + [*] = [] (full access)" [] effective

(* ── local scope ── *)

let test_local_empty_paths () =
  let meta = make_meta ~execution_scope:"local" ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "local + [] = sandbox root"
    (sandbox_roots "t") effective

(* ── wildcard handling ── *)

let test_star_wildcard_any_scope () =
  let scopes = ["observe_only"; "workspace"; "local"; "unknown"] in
  List.iter (fun scope ->
    let meta = make_meta ~execution_scope:scope ~allowed_paths:["*"] ~name:"t" () in
    let effective = KAP.effective_allowed_paths ~meta in
    check (list string) (scope ^ " + [*] = []") [] effective
  ) scopes

let test_explicit_paths_any_scope () =
  let paths = ["lib/keeper/"; "test/"] in
  let expected = sandbox_roots "t" @ ["lib/keeper/"; "test/"] in
  List.iter (fun scope ->
    let meta = make_meta ~execution_scope:scope ~allowed_paths:paths ~name:"t" () in
    let effective = KAP.effective_allowed_paths ~meta in
    check (list string) (scope ^ " + explicit = sandbox root + explicit")
      expected effective
  ) ["observe_only"; "workspace"; "local"]

(* ── keeper name in sandbox default ── *)

let test_playground_default_uses_keeper_name () =
  let meta = make_meta ~execution_scope:"workspace"
      ~name:"cdal-formalist" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "name embedded in sandbox path"
    (sandbox_roots "cdal-formalist") effective

(* ── playground path ── *)

let test_playground_path_sanitizes_name () =
  let path = KAP.playground_path_of_keeper "my keeper/../../etc" in
  check string "special chars sanitized"
    ".masc/playground/my_keeper_.._.._etc/" path

let test_playground_always_present () =
  let scopes = ["observe_only"; "workspace"; "local"] in
  List.iter (fun scope ->
    let meta = make_meta ~execution_scope:scope ~name:"abc" () in
    let effective = KAP.effective_allowed_paths ~meta in
    check bool (scope ^ " has sandbox root")
      true (List.mem ".masc/playground/abc/" effective)
  ) scopes

let test_ensure_playground_bundle_creates_subdirs () =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "keeper_playground_bundle_%d" (Random.bits ())) in
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () ->
    let rec rm path =
      if Sys.file_exists path then
        if Sys.is_directory path then begin
          Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
          Unix.rmdir path
        end else Sys.remove path
    in
    rm dir
  ) (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Masc_mcp.Coord.default_config dir in
    let created = KAP.ensure_playground_bundle ~config ~name:"abc" in
    check int "bundle size" 3 (List.length created);
    List.iter (fun path ->
      check bool ("exists: " ^ path) true (Sys.file_exists path);
      check bool ("is_dir: " ^ path) true (Sys.is_directory path)
    ) created)

let with_temp_config f =
  with_temp_dir "keeper_default_root_" (fun dir ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    f (Masc_mcp.Coord.default_config dir))

let check_default_roots_use_playground (meta : KT.keeper_meta) =
  with_temp_config (fun config ->
    let expected =
      Filename.concat
        (KAP.project_root_of_config config)
        (KAP.playground_path_of_keeper meta.name)
    in
    let write_root = KES.keeper_default_write_root ~config ~meta in
    let read_root = KES.keeper_default_read_root ~config ~meta in
    check string "default write root is playground" expected write_root;
    check string "default read root is playground" expected read_root;
    check bool "playground dir exists" true (Sys.file_exists expected);
    check bool "playground dir is directory" true (Sys.is_directory expected))

let test_default_roots_use_playground_with_explicit_paths () =
  let meta = make_meta ~execution_scope:"workspace"
      ~allowed_paths:["workspace/yousleepwhen/oas/"] ~name:"keeper" () in
  check_default_roots_use_playground meta

let test_default_roots_use_playground_with_full_access () =
  let meta = make_meta ~execution_scope:"workspace"
      ~allowed_paths:["*"] ~name:"keeper" () in
  check_default_roots_use_playground meta

let test_sandbox_contract_reports_single_tool_root () =
  let meta = make_meta ~execution_scope:"workspace" ~name:"keeper" () in
  with_temp_config (fun config ->
    let sb = KS.of_meta ~config ~meta in
    check string "sandbox id" "keeper:keeper" sb.sandbox_id;
    check string "sandbox root arg" "." sb.root_arg;
    check string "sandbox repos arg" "repos" sb.repos_arg;
    check string "local host root rel stays on local lane"
      ".masc/playground/keeper/" sb.host_root_rel;
    check (option string) "local has no container root" None sb.container_root)

let test_sandbox_contract_reports_docker_container_root () =
  let meta =
    let json = `Assoc [
      ("name", `String "keeper");
      ("agent_name", `String "agent-keeper");
      ("trace_id", `String "trace-keeper");
      ("goal", `String "test");
      ("execution_scope", `String "workspace");
      ("sandbox_profile", `String "docker");
      ("network_mode", `String "none");
    ] in
    match KT.meta_of_json json with
    | Ok meta -> meta
    | Error err -> fail ("docker meta: " ^ err)
  in
  with_temp_config (fun config ->
    let sb = KS.of_meta ~config ~meta in
    check string "docker backend" "docker"
      (KS.backend_to_string sb.backend);
    check string "docker host root rel uses docker lane"
      ".masc/playground/docker/keeper/" sb.host_root_rel;
    check (option string) "docker has private container root"
      (Some "/home/keeper/playground/keeper") sb.container_root)

(* Error UX: rejection messages must teach the LLM why the path failed,
   not just that it failed. The relative-path case is the common one — bare
   "X not allowed" sends the keeper into a retry loop guessing alternatives.
   See memory/feedback_tool-error-messages-teach-llm.md. *)

let contains_substring ~haystack ~needle =
  let h = String.length haystack and n = String.length needle in
  if n = 0 then true
  else if n > h then false
  else
    let rec scan i =
      if i + n > h then false
      else if String.sub haystack i n = needle then true
      else scan (i + 1)
    in
    scan 0

let test_path_rejection_explains_sandbox_boundary () =
  let meta = make_meta ~execution_scope:"workspace" ~name:"ani1999" () in
  with_temp_config (fun config ->
    match KES.resolve_keeper_path ~config ~meta ~raw_path:"lib/foo.ml" with
    | Ok path -> fail ("expected rejection for lib/foo.ml, got: " ^ path)
    | Error err ->
      check bool "preserves machine-readable prefix" true
        (String.starts_with ~prefix:"path_outside_sandbox:" err);
      check bool "includes sandbox-boundary explanation" true
        (contains_substring ~haystack:err
           ~needle:"sandbox boundary");
      check bool "includes resolved candidate" true
        (contains_substring ~haystack:err ~needle:"resolved="))

let test_path_rejection_omits_resolved_for_absolute () =
  let meta = make_meta ~execution_scope:"workspace" ~name:"ani1999" () in
  with_temp_config (fun config ->
    match KES.resolve_keeper_path ~config ~meta
            ~raw_path:"/etc/passwd" with
    | Ok path -> fail ("expected absolute path rejection, got: " ^ path)
    | Error _ -> check bool "absolute path rejected" true true)

let test_resolve_keeper_path_blocks_workspace_repo_write_default () =
  let meta = make_meta ~execution_scope:"workspace" ~name:"keeper" () in
  with_temp_config (fun config ->
    match KES.resolve_keeper_path ~config ~meta ~raw_path:"lib/foo.ml" with
    | Ok path -> fail ("expected write rejection, got: " ^ path)
    | Error err ->
      check bool "rejects repo-root write outside sandbox" true
        (String.starts_with ~prefix:"path_outside_sandbox:" err))

let test_resolve_keeper_path_allows_playground_write_default () =
  let meta = make_meta ~execution_scope:"workspace" ~name:"keeper" () in
  with_temp_config (fun config ->
    let expected =
      Filename.concat
        (Filename.concat
           (KAP.project_root_of_config config)
           (KAP.playground_path_of_keeper meta.name))
        "notes.md"
    in
    match KES.resolve_keeper_path ~config ~meta ~raw_path:"notes.md" with
    | Error err -> fail ("expected playground write path, got error: " ^ err)
    | Ok path -> check string "bare file defaults into playground" expected path)

let test_repos_prefix_maps_into_playground_repos () =
  let meta = make_meta ~execution_scope:"workspace" ~name:"keeper" () in
  with_temp_config (fun config ->
    let expected =
      Filename.concat
        (Filename.concat
           (KAP.project_root_of_config config)
           (KAP.playground_path_of_keeper meta.name))
        "repos/masc-mcp/lib/foo.ml"
    in
    match KES.resolve_keeper_path ~config ~meta
            ~raw_path:"repos/masc-mcp/lib/foo.ml" with
    | Error err -> fail ("expected repos/ path to resolve into playground, got: " ^ err)
    | Ok path -> check string "repos/ goes into playground repos/" expected path)

(* ── Path doubling tests ── *)

(* Test playground_relative_unless_allowed_root directly: it must strip the
   keeper's own playground prefix from relative paths so that the downstream
   resolver doesn't double it.  E.g.
     ".masc/playground/sangsu/repos" → "repos"
   We test via resolve_keeper_path on a bare filename: if stripping works,
   a path like ".masc/playground/sangsu/notes.md" becomes "notes.md" and
   the function appends the playground root once, not twice. *)

let test_playground_prefix_stripped_relative () =
  let meta = make_meta ~execution_scope:"workspace" ~name:"sangsu" () in
  with_temp_config (fun config ->
    ignore (KAP.ensure_playground_bundle ~config ~name:"sangsu");
    let pg_root = playground_root_of_config config "sangsu" in
    let target = Filename.concat pg_root "notes.md" in
    ignore (Fs_compat.save_file_atomic target "test");
    (* Pass with redundant playground prefix — should still resolve to the
       same target (prefix stripped, then playground root prepended once). *)
    match KES.resolve_keeper_path ~config ~meta
            ~raw_path:".masc/playground/sangsu/notes.md" with
    | Error err -> fail ("expected stripped path, got error: " ^ err)
    | Ok path -> check string "prefix stripped" target path)

let test_playground_short_prefix_stripped_relative () =
  let meta = make_meta ~execution_scope:"workspace" ~name:"sangsu" () in
  with_temp_config (fun config ->
    ignore (KAP.ensure_playground_bundle ~config ~name:"sangsu");
    let pg_root = playground_root_of_config config "sangsu" in
    let target = Filename.concat pg_root "notes.md" in
    ignore (Fs_compat.save_file_atomic target "test");
    match KES.resolve_keeper_path ~config ~meta
            ~raw_path:"playground/sangsu/notes.md" with
    | Error err -> fail ("expected stripped short prefix, got error: " ^ err)
    | Ok path -> check string "short prefix stripped" target path)

let test_bare_filename_still_works () =
  let meta = make_meta ~execution_scope:"workspace" ~name:"sangsu" () in
  with_temp_config (fun config ->
    ignore (KAP.ensure_playground_bundle ~config ~name:"sangsu");
    let pg_root = playground_root_of_config config "sangsu" in
    let target = Filename.concat pg_root "hello.txt" in
    ignore (Fs_compat.save_file_atomic target "test");
    match KES.resolve_keeper_path ~config ~meta
            ~raw_path:"hello.txt" with
    | Error err -> fail ("bare filename should still work: " ^ err)
    | Ok path -> check string "bare filename" target path)

let test_single_sandbox_repo_relative_read_path_rewrites () =
  let meta = make_meta ~execution_scope:"workspace" ~name:"sangsu" () in
  with_temp_config (fun config ->
    let repo_root = create_sandbox_repo ~config ~meta "masc-mcp" in
    let target = Filename.concat repo_root "lib/foo.ml" in
    ensure_dir (Filename.dirname target);
    ignore (Fs_compat.save_file_atomic target "let x = 1\n");
    match KES.resolve_keeper_read_path ~config ~meta ~raw_path:"lib/foo.ml" with
    | Error err -> fail ("expected single-repo relative rewrite, got error: " ^ err)
    | Ok path -> check string "single repo relative read path" target path)

let test_multi_sandbox_repo_relative_path_is_ambiguous () =
  let meta = make_meta ~execution_scope:"workspace" ~name:"sangsu" () in
  with_temp_config (fun config ->
    ignore (create_sandbox_repo ~config ~meta "masc-mcp");
    ignore (create_sandbox_repo ~config ~meta "other-repo");
    match KES.resolve_keeper_path ~config ~meta ~raw_path:"lib/foo.ml" with
    | Ok path -> fail ("expected ambiguous repo-relative path, got: " ^ path)
    | Error err ->
      check bool "uses structured ambiguous prefix" true
        (String.starts_with ~prefix:"ambiguous_repo_relative_path:" err);
      check bool "mentions first candidate" true
        (contains_substring ~haystack:err ~needle:"masc-mcp");
      check bool "mentions second candidate" true
        (contains_substring ~haystack:err ~needle:"other-repo"))

let test_docker_rejects_wildcard_allowed_paths () =
  with_temp_config (fun config ->
    match
      KTU.validate_sandbox_settings
        ~config
        ~keeper_name:"sangsu"
        ~sandbox_profile:KT.Docker
        ~network_mode:KT.Network_none
        ~allowed_paths:["*"]
    with
    | Ok () -> fail "expected docker wildcard rejection"
    | Error err ->
        check bool "mentions wildcard" true
          (String_util.contains_substring err "allowed_paths=[\"*\"]"))

let test_docker_rejects_paths_outside_private_root () =
  with_temp_config (fun config ->
    match
      KTU.validate_sandbox_settings
        ~config
        ~keeper_name:"sangsu"
        ~sandbox_profile:KT.Docker
        ~network_mode:KT.Network_none
        ~allowed_paths:["workspace/other-repo"]
    with
    | Ok () -> fail "expected docker path rejection"
    | Error err ->
        check bool "mentions private playground" true
          (String_util.contains_substring err ".masc/playground/docker/sangsu"))

let test_docker_rejects_root_allowed_path () =
  with_temp_config (fun config ->
    match
      KTU.validate_sandbox_settings
        ~config
        ~keeper_name:"sangsu"
        ~sandbox_profile:KT.Docker
        ~network_mode:KT.Network_none
        ~allowed_paths:["/"]
    with
    | Ok () -> fail "expected docker root-path rejection"
    | Error err ->
        check bool "mentions private playground" true
          (String_util.contains_substring err ".masc/playground/docker/sangsu"))

let test_docker_rejects_glob_like_allowed_path () =
  with_temp_config (fun config ->
    match
      KTU.validate_sandbox_settings
        ~config
        ~keeper_name:"sangsu"
        ~sandbox_profile:KT.Docker
        ~network_mode:KT.Network_none
        ~allowed_paths:["/tmp/**"]
    with
    | Ok () -> fail "expected docker glob-like path rejection"
    | Error err ->
        check bool "mentions rejected path" true
          (String_util.contains_substring err "/tmp/**"))

let test_docker_rejects_traversal_allowed_path () =
  with_temp_config (fun config ->
    let private_root =
      KTU.private_workspace_root_rel ~sandbox_profile:KT.Docker "sangsu"
    in
    match
      KTU.validate_sandbox_settings
        ~config
        ~keeper_name:"sangsu"
        ~sandbox_profile:KT.Docker
        ~network_mode:KT.Network_none
        ~allowed_paths:
          [ private_root ^ "/repos/demo/../../../../../../etc/passwd" ]
    with
    | Ok () -> fail "expected docker traversal rejection"
    | Error err ->
        check bool "mentions private playground" true
          (String_util.contains_substring err ".masc/playground/docker/sangsu"))

let test_docker_accepts_private_root_paths () =
  with_temp_config (fun config ->
    let private_root =
      KTU.private_workspace_root_rel ~sandbox_profile:KT.Docker "sangsu"
    in
    ignore
      (KAP.ensure_sandbox_bundle_for_profile ~config ~name:"sangsu"
         ~sandbox_profile:KT.Docker);
    let target_dir =
      Filename.concat (KAP.project_root_of_config config)
        (private_root ^ "/repos/demo")
    in
    let rec ensure_dir path =
      if path <> "" && path <> "." && path <> "/" && not (Sys.file_exists path) then (
        let parent = Filename.dirname path in
        if parent <> path then ensure_dir parent;
        Unix.mkdir path 0o755)
    in
    ensure_dir target_dir;
    match
      KTU.validate_sandbox_settings
        ~config
        ~keeper_name:"sangsu"
        ~sandbox_profile:KT.Docker
        ~network_mode:KT.Network_none
        ~allowed_paths:[private_root ^ "/repos/demo"]
    with
    | Error err -> fail ("expected private-root allow path, got: " ^ err)
    | Ok () -> ())

let test_local_rejects_network_none () =
  with_temp_config (fun config ->
    match
      KTU.validate_sandbox_settings
        ~config
        ~keeper_name:"sangsu"
        ~sandbox_profile:KT.Local
        ~network_mode:KT.Network_none
        ~allowed_paths:[]
    with
    | Ok () -> fail "expected local network rejection"
    | Error err ->
        check bool "mentions docker" true
          (String_util.contains_substring err "docker"))

(* ── Runner ── *)

let () =
  run "keeper_allowed_paths"
    [
      ( "effective_allowed_paths",
        [
          test_case "observe_only + [] = [sandbox root]" `Quick
            test_observe_only_empty_paths;
          test_case "observe_only + explicit = sandbox root + explicit" `Quick
            test_observe_only_explicit_paths;
          test_case "workspace + [] = sandbox root only" `Quick
            test_workspace_empty_paths_playground_only;
          test_case "workspace + explicit = sandbox root + explicit" `Quick
            test_workspace_explicit_paths;
          test_case "workspace write defaults are sandbox-only" `Quick
            test_workspace_write_paths_playground_only;
          test_case "workspace write defaults preserve explicit overrides" `Quick
            test_workspace_write_paths_preserve_explicit_overrides;
          test_case "workspace + [*] = full access" `Quick
            test_workspace_star_wildcard;
          test_case "local + [] = [sandbox root]" `Quick
            test_local_empty_paths;
          test_case "[*] wildcard any scope" `Quick
            test_star_wildcard_any_scope;
          test_case "explicit paths any scope" `Quick
            test_explicit_paths_any_scope;
          test_case "keeper name in sandbox default" `Quick
            test_playground_default_uses_keeper_name;
        ] );
      ( "sandbox_contract",
        [
          test_case "single local sandbox root" `Quick
            test_sandbox_contract_reports_single_tool_root;
          test_case "docker backend reports container root" `Quick
            test_sandbox_contract_reports_docker_container_root;
        ] );
      ( "playground",
        [
          test_case "path sanitizes keeper name" `Quick
            test_playground_path_sanitizes_name;
          test_case "sandbox root always in allowed_paths" `Quick
            test_playground_always_present;
          test_case "ensure playground bundle creates subdirs" `Quick
            test_ensure_playground_bundle_creates_subdirs;
          test_case "default roots stay in playground with explicit paths" `Quick
            test_default_roots_use_playground_with_explicit_paths;
          test_case "default roots stay in playground with full access" `Quick
            test_default_roots_use_playground_with_full_access;
          test_case "rejection explains sandbox boundary + resolved candidate" `Quick
            test_path_rejection_explains_sandbox_boundary;
          test_case "absolute path rejection still works" `Quick
            test_path_rejection_omits_resolved_for_absolute;
          test_case "workspace repo writes blocked by default" `Quick
            test_resolve_keeper_path_blocks_workspace_repo_write_default;
          test_case "bare writes default into playground" `Quick
            test_resolve_keeper_path_allows_playground_write_default;
          test_case "repos prefix maps into playground repos" `Quick
            test_repos_prefix_maps_into_playground_repos;
        ] );
      ( "path_doubling_guard",
        [
          test_case "relative playground prefix stripped" `Quick
            test_playground_prefix_stripped_relative;
          test_case "short playground prefix stripped" `Quick
            test_playground_short_prefix_stripped_relative;
          test_case "bare filename still works after guard" `Quick
            test_bare_filename_still_works;
          test_case "single sandbox repo relative read path rewrites" `Quick
            test_single_sandbox_repo_relative_read_path_rewrites;
          test_case "multi sandbox repo relative path is ambiguous" `Quick
            test_multi_sandbox_repo_relative_path_is_ambiguous;
        ] );
      ( "sandbox_validation",
        [
          test_case "docker rejects wildcard allowed_paths" `Quick
            test_docker_rejects_wildcard_allowed_paths;
          test_case "docker rejects root allowed path" `Quick
            test_docker_rejects_root_allowed_path;
          test_case "docker rejects glob-like allowed path" `Quick
            test_docker_rejects_glob_like_allowed_path;
          test_case "docker rejects traversal allowed path" `Quick
            test_docker_rejects_traversal_allowed_path;
          test_case "docker rejects paths outside private root" `Quick
            test_docker_rejects_paths_outside_private_root;
          test_case "docker accepts private root paths" `Quick
            test_docker_accepts_private_root_paths;
          test_case "local rejects network none" `Quick
            test_local_rejects_network_none;
        ] );
    ]

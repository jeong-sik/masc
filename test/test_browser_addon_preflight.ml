open Alcotest
module P = Masc.Browser_addon_preflight

(* A workspace with a browser lane host installed and no browser Add-on
   declaration answers every native host poll with HTTP 503. The deployment
   refuses it before anything is stopped; the declaration stays the operator's
   to save. The package is the repository's own, so a package that stops being
   a browser service fails here. *)

let write path text =
  let rec make directory =
    if not (Sys.file_exists directory) then (
      make (Filename.dirname directory);
      Unix.mkdir directory 0o700)
  in
  make (Filename.dirname path);
  Out_channel.with_open_bin path (fun out -> output_string out text)

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Sys.remove path

let package_path () =
  let path = Sys.getenv "MASC_TEST_BROWSER_PACKAGE" in
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path

(* The config root comes from this workspace only. *)
let with_workspace f =
  let base = Filename.temp_dir "browser-addon-preflight-" "" in
  let previous = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.putenv "MASC_CONFIG_DIR" "";
  Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "MASC_CONFIG_DIR" (Option.value previous ~default:"");
      Config_dir_resolver.reset ();
      remove base)
    (fun () -> f base)

let install_host base =
  let script = "#!/bin/sh\nexec masc-browser-host\n" in
  write (Masc.Browser_lane_launcher.launcher_path ~base_path:base) script;
  write
    (Masc.Browser_lane_launcher.declaration_path ~base_path:base)
    (Masc.Browser_lane_launcher.declaration ~launcher_script:script)

let declaration_path base =
  List.fold_left Filename.concat base [ ".masc"; "config"; "lane-addons"; "browser.toml" ]

let save_declaration ?(extra = "") base =
  write (declaration_path base)
    (Printf.sprintf "id = \"browser\"\nrun_id = \"browser-work\"\nmanifest_path = %S\n%s\n[binding]\nsources = []\n"
       (package_path ()) extra)

let missing = function
  | P.Missing { complete; unloaded; _ } -> Some (complete, List.length unloaded)
  | P.Not_required | P.Declared _ | P.Config_root_invalid _ -> None

let test_no_host_needs_no_addon () =
  with_workspace @@ fun base ->
  check bool "a workspace without a host is not required to declare the Add-on" true
    (P.judge ~base_path:base = P.Not_required);
  save_declaration base;
  check bool "a declaration without a host changes nothing" true
    (P.judge ~base_path:base = P.Not_required)

let test_host_without_declaration_is_refused () =
  with_workspace @@ fun base ->
  install_host base;
  check bool "no declaration directory at all" true (missing (P.judge ~base_path:base) = Some (true, 0));
  check bool "the deployment is refused" true (Result.is_error (P.report (P.judge ~base_path:base)))

let test_declared_browser_addon_passes () =
  with_workspace @@ fun base ->
  install_host base;
  save_declaration base;
  (match P.judge ~base_path:base with
   | P.Declared { id } -> check string "the declaration's id" "browser" id
   | P.Not_required | P.Missing _ | P.Config_root_invalid _ -> fail "expected a declared browser Add-on");
  check bool "the deployment may proceed" true (Result.is_ok (P.report (P.judge ~base_path:base)))

let test_a_disabled_declaration_is_not_a_browser_addon () =
  with_workspace @@ fun base ->
  install_host base;
  save_declaration ~extra:"enabled = false" base;
  check bool "disabled" true (missing (P.judge ~base_path:base) = Some (true, 0))

let test_a_declaration_that_does_not_load_is_named () =
  with_workspace @@ fun base ->
  install_host base;
  write (declaration_path base) "id = \"browser\"\nmanifest_path = \"/nonexistent/lane.toml\"\n";
  check bool "the declaration that did not load is listed" true
    (match missing (P.judge ~base_path:base) with Some (_, unloaded) -> unloaded >= 1 | None -> false)

(* The declaration directory is the one the server reconciles. *)
let test_the_directory_is_the_one_the_server_reads () =
  with_workspace @@ fun base ->
  install_host base;
  match P.judge ~base_path:base with
  | P.Missing { directory; _ } ->
    check string "same directory as the server's"
      (Masc.Lane_addon_runtime.configuration_directory (Masc.Workspace.default_config base))
      directory
  | P.Not_required | P.Declared _ | P.Config_root_invalid _ -> fail "expected a missing declaration"

let () =
  run "browser addon preflight"
    [ ( "verdict"
      , [ test_case "no host needs no Add-on" `Quick test_no_host_needs_no_addon
        ; test_case "a host without a declaration is refused" `Quick
            test_host_without_declaration_is_refused
        ; test_case "a declared browser Add-on passes" `Quick test_declared_browser_addon_passes
        ; test_case "a disabled declaration is not a browser Add-on" `Quick
            test_a_disabled_declaration_is_not_a_browser_addon
        ; test_case "a declaration that does not load is named" `Quick
            test_a_declaration_that_does_not_load_is_named
        ; test_case "the directory is the one the server reads" `Quick
            test_the_directory_is_the_one_the_server_reads
        ] )
    ]

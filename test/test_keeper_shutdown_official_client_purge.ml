(* The dashboard Keeper purge removes every artifact a same-name successor
   could read as its own. The official-client owner homes hash the Keeper name
   with an OAuth source (Antigravity) or account home (Muse), so they were
   never in the typed plan's name-only entries and survived the purge: the
   Antigravity HOME keeps its managed OAuth token copy and the sibling prepare
   lock, and the Muse identity directory keeps the managed workspace. *)

open Alcotest

module Workspace = Masc.Workspace
module Shutdown = Masc.Keeper_shutdown_types

let keeper_name = "official-purge-keeper"

let runtime_toml ~oauth_source ~account_home ~assignment =
  Printf.sprintf
    {|
[runtime]
default = "agy.gemini"

[providers.agy]
protocol = "antigravity-cli"
command = "/fixture/agy"
is-non-interactive = true
timeout-s = 10.0
credentials = { type = "file", path = "%s" }

[models.gemini]
api-name = "gemini-fixture"
max-context = 128000

[agy.gemini]

[providers.muse]
protocol = "muse-serve"
command = "/fixture/muse"
account-home = "%s"
is-non-interactive = true

[models.muse-spark]
api-name = "muse-spark-1.3"
max-context = 100000

[muse.muse-spark]

[runtime.assignments]%s
|}
    oauth_source
    account_home
    assignment
;;

let with_base_path f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Eio_main.run @@ fun _env ->
  let base_path = Filename.temp_dir "official-client-purge-" "" in
  Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () ->
      Config_dir_resolver.reset ();
      Fs_compat.remove_tree base_path)
    (fun () ->
      let config = Workspace.default_config base_path in
      let (_ : string) = Workspace.init config ~agent_name:None in
      f config base_path)
;;

let write_runtime_toml base_path text =
  let path =
    Config_dir_resolver.runtime_toml_path_for_base_path ~base_path
  in
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text)
;;

let purge config =
  match
    Server_dashboard_http_delete_actions.For_testing.purge_keeper_artifacts
      config
      ~keeper_name
      ~remove_configuration:false
      { Shutdown.requested_name = keeper_name }
  with
  | Ok () -> ()
  | Error detail -> failf "artifact purge: %s" detail
;;

let antigravity_paths base_path ~oauth_source =
  let runtime_root = Common.masc_dir_from_base_path ~base_path in
  let owner_leaf =
    Runtime_antigravity_home.keeper_owner_leaf ~keeper_name ~oauth_source
  in
  ( Runtime_antigravity_home.keeper_home_dir ~runtime_root ~owner_leaf
  , Runtime_antigravity_home.keeper_prepare_lock_path ~runtime_root ~owner_leaf
  )
;;

let plant_file path bytes =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel bytes)
;;

let test_purge_removes_antigravity_home_and_lock () =
  with_base_path @@ fun config base_path ->
  let oauth_source = Filename.concat base_path "operator-oauth.json" in
  plant_file oauth_source {|{"access_token":"fixture"}|};
  let account_home = Filename.concat base_path "muse-account" in
  write_runtime_toml
    base_path
    (runtime_toml ~oauth_source ~account_home
       ~assignment:(Printf.sprintf "\n%s = %S" keeper_name "agy.gemini"));
  let home, lock = antigravity_paths base_path ~oauth_source in
  plant_file
    (Filename.concat home ".gemini/antigravity-cli/antigravity-oauth-token")
    "managed token copy";
  plant_file lock "";
  check bool "fixture home exists" true (Sys.file_exists home);
  check bool "fixture lock exists" true (Sys.file_exists lock);
  purge config;
  check bool "purge removes the Antigravity owner HOME" false (Sys.file_exists home);
  check bool "purge removes the sibling prepare lock" false (Sys.file_exists lock)
;;

let test_purge_removes_muse_identity_directory () =
  with_base_path @@ fun config base_path ->
  let oauth_source = Filename.concat base_path "operator-oauth.json" in
  let account_home = Filename.concat base_path "muse-account" in
  write_runtime_toml
    base_path
    (runtime_toml ~oauth_source ~account_home
       ~assignment:(Printf.sprintf "\n%s = %S" keeper_name "muse.muse-spark"));
  let runtime_root = Common.masc_dir_from_base_path ~base_path in
  let identity_dir =
    Runtime_muse_home.keeper_identity_dir ~runtime_root ~keeper_name ~account_home
  in
  plant_file (Filename.concat identity_dir "workspace/native-state") "fixture";
  check bool "fixture identity directory exists" true (Sys.file_exists identity_dir);
  purge config;
  check bool "purge removes the Muse identity directory" false
    (Sys.file_exists identity_dir)
;;

(* A home whose derivation inputs are gone (the runtime configuration no
   longer assigns this Keeper) cannot be named by the purge either. The purge
   stays complete, and the entry is omitted rather than failing. *)
let test_purge_omits_home_it_cannot_derive () =
  with_base_path @@ fun config base_path ->
  let oauth_source = Filename.concat base_path "operator-oauth.json" in
  let account_home = Filename.concat base_path "muse-account" in
  write_runtime_toml
    base_path
    (runtime_toml ~oauth_source ~account_home ~assignment:"");
  let home, lock = antigravity_paths base_path ~oauth_source in
  plant_file (Filename.concat home "generation/token") "managed token copy";
  plant_file lock "";
  purge config;
  check bool "an underivable home is left in place" true (Sys.file_exists home);
  check bool "an underivable lock is left in place" true (Sys.file_exists lock)
;;

let () =
  run "Keeper shutdown official-client purge"
    [ ( "official-client homes"
      , [ test_case "purge removes the Antigravity HOME and prepare lock" `Quick
            test_purge_removes_antigravity_home_and_lock
        ; test_case "purge removes the Muse identity directory" `Quick
            test_purge_removes_muse_identity_directory
        ; test_case "purge omits a home it can no longer derive" `Quick
            test_purge_omits_home_it_cannot_derive
        ] )
    ]
;;

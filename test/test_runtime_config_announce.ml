(* RFC-0480 §3.4: a committed runtime.toml text tells the workspace's
   readers that the file changed. A catalogue publication that writes no
   text (startup, setup-required) says nothing. The fixture is the one
   test_exact_output_runtime_deadline uses, since a save validates its
   exact-output lanes. *)

open Alcotest
open Masc

let lane_id = "librarian_exact"

let runtime_toml () =
  Printf.sprintf {|[runtime]
default = "openai-responses.probe"
%s
[providers.openai-responses]
protocol = "openai-compatible-http"
endpoint = "https://api.openai.com"
[providers.openai-responses.credentials]
type = "env"
key = "OPENAI_API_KEY"
[models.probe]
api-name = "gpt-5.6-luna"
[openai-responses.probe]
|}
    (String.concat "\n"
       (List.map
          (fun lane -> Printf.sprintf "[runtime.exact_output_lanes.%s]\nslots = [\"openai-responses.probe\"]\nmax_output_tokens = 4096" lane)
          (List.sort_uniq String.compare (lane_id :: Standalone_lane.required_ids))))

(* Long enough for the daemon to wake on an idle machine; a signal that does
   not come in this time is reported as missing. *)
let signal_wait_s = 5.0

(* Long enough for a woken daemon to have sent what it was going to send. *)
let quiet_wait_s = 0.3

let test_committed_text_announces_and_publications_do_not () =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env "OPENAI_API_KEY" (Some "synthetic-no-network") @@ fun () ->
  let root = Filename.temp_dir "runtime-config-announce-" "" in
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some root) @@ fun () ->
  Config_dir_resolver.reset ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  let previous_runtime = Runtime.For_testing.snapshot () in
  let previous_startup = Runtime_startup_state.get () in
  let previous_catalog = Llm_provider.Catalog_snapshot.current () in
  Fun.protect ~finally:(fun () ->
    Runtime.unpublish_exact_output_registry () |> ignore;
    Runtime.For_testing.restore previous_runtime;
    Runtime_startup_state.set previous_startup;
    Llm_provider.Catalog_snapshot.publish previous_catalog;
    Config_dir_resolver.reset ();
    Fs_compat.remove_tree root) @@ fun () ->
  Llm_provider.Catalog_snapshot.reset ();
  let path = Filename.concat root "runtime.toml" in
  let heard = Eio.Stream.create max_int in
  let id = "runtime-config-announce" in
  Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path:root) ~id
    ~callback:(fun (event : Sse.external_event) ->
      match Json_util.assoc_string_opt "type" event.ext_payload with
      | Some kind when String.equal kind Runtime_config_changed_event.event_type ->
        Eio.Stream.add heard ()
      | Some _ | None -> ())
    ();
  Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  Server_runtime_config_broadcast.install ~sw ~base_path:root;
  let expect_change label =
    match Eio.Time.with_timeout clock signal_wait_s (fun () -> Ok (Eio.Stream.take heard)) with
    | Ok () -> ()
    | Error `Timeout -> failf "%s: no runtime config change" label
  in
  let expect_quiet label =
    Eio.Time.sleep clock quiet_wait_s;
    check int label 0 (Eio.Stream.length heard)
  in
  Fs_compat.save_file path (runtime_toml ());
  (match Runtime.init_default ~config_path:path with
   | Ok () -> ()
   | Error detail -> failf "runtime initialization: %s" detail);
  Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:root ();
  expect_quiet "a startup load writes no text";
  (match Runtime.save_config_text ~runtime_config_path:path (runtime_toml ()) with
   | Ok _ -> ()
   | Error detail -> failf "save: %s" detail);
  expect_change "a committed text";
  (* RFC-0482 §3.1: a terminal reader's pick goes through the same commit,
     and the same pick again leaves the text and the readers alone. *)
  let pick () =
    match
      Runtime.edit_config_text_if_changed ~runtime_config_path:path
        (Tui_preference.edit (Tui_preference.Theme_chosen (Some "ayu-dark")))
    with
    | Ok (Runtime.Config_text_committed _) -> `Committed
    | Ok (Runtime.Config_text_unchanged _) -> `Unchanged
    | Error detail -> failf "tui preference: %s" detail
  in
  check bool "a new pick commits" true (pick () = `Committed);
  expect_change "a TUI preference";
  check bool "the same pick again commits nothing" true (pick () = `Unchanged);
  expect_quiet "an unchanged pick";
  Runtime.enter_setup_required ~reason:Runtime_startup_state.Config_missing ();
  expect_quiet "setup-required writes no text"

let () =
  run "runtime_config_announce"
    [ ( "text"
      , [ test_case "a committed text announces and a bare publication does not" `Quick
            test_committed_text_announces_and_publications_do_not ] )
    ]

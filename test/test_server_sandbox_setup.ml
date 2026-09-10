open Alcotest
open Masc
module Setup = Server_sandbox_setup
let contents = "# preserve\n[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nnetwork_mode = \"inherit\"\ninstructions = \"Keep history.\"\n"
let save path contents = Out_channel.with_open_bin path (fun out -> output_string out contents)
let fixture f = Eio_main.run (fun _ ->
  let base=Filename.temp_dir "sandbox-web-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    let path=Keeper_sandbox_config.keeper_toml_path ~base_path:base ~agent_name:"imp" in
    Fs_compat.mkdir_p (Filename.dirname path); save path contents; f base path))
let run = function
  | ["uname";"-s"] -> Ok "Linux"
  | ["uname";"-m"] -> Ok "aarch64"
  | ["docker";"info";"--format";"{{json .}}"] -> Ok {|{"OSType":"linux","SecurityOptions":["name=rootless","name=userns"]}|}
  | _ -> Error Sandbox_readiness.Missing_command
let request base text = `Assoc ["backend",`String "docker";"network_mode",`String "none";
  "revision",`String (Setup.For_testing.revision base text)]
let prepared_receipt () = fixture (fun base path ->
  let count=ref 0 in
  let image _ = incr count; check string "image preparation precedes publication" contents (In_channel.with_open_bin path In_channel.input_all); Ok () in
  let receipt=Setup.For_testing.prepare ~base_path:base ~run ~image (request base contents) |> Result.get_ok in
  check int "exactly one image operation" 1 !count;
  let stored=In_channel.with_open_bin path In_channel.input_all in
  check bool "comments/history fields remain" true (String.starts_with ~prefix:"# preserve" stored);
  let declaration=Keeper_types_profile.materialization_defaults_of_content ~path stored |> Result.get_ok in
  check bool "selected network is persisted" true (declaration.network_mode=Some Keeper_types_profile_sandbox.Network_none);
  let open Yojson.Safe.Util in
  check string "no fabricated guest proof" "not_run" (receipt |> member "guest_verification" |> to_string);
  check string "no fabricated model verification" "not_run" (receipt |> member "model_verification" |> to_string))
let concurrent_change () = fixture (fun base path ->
  let changed=contents ^ "# another owner edit\n" in
  let image _ = save path changed; Ok () in
  check bool "changed declaration prevents publication" true
    (Setup.For_testing.prepare ~base_path:base ~run ~image (request base contents)=Error Setup.Commit_unconfirmed);
  check string "concurrent declaration retained" changed (In_channel.with_open_bin path In_channel.input_all))
let lifecycle_guard () = fixture (fun base path ->
  let token=Keeper_lifecycle_reservation.acquire ~base_path:base ~keeper_name:"imp" ~purpose:Keepalive_launch |> Result.get_ok in
  Fun.protect ~finally:(fun () -> ignore (Keeper_lifecycle_reservation.release token)) (fun () ->
    let called=ref false in
    let image _ = called:=true; Ok () in
    check bool "active launch reservation refused" true
      (Setup.For_testing.prepare ~base_path:base ~run ~image (request base contents)=Error Setup.Lifecycle_busy);
    check bool "no image work under conflicting launch" false !called;
    check string "no configuration change" contents (In_channel.with_open_bin path In_channel.input_all)))
let failed_image () = fixture (fun base path ->
  check bool "failed image not published" true
    (Setup.For_testing.prepare ~base_path:base ~run ~image:(fun _ -> Error Setup.Image_failed) (request base contents)=Error Setup.Image_failed);
  check string "original survives failed preparation" contents (In_channel.with_open_bin path In_channel.input_all))
let settled_keeper () = fixture (fun base path ->
  let meta=Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String "imp";"trace_id",`String "fixture-trace";"activation_mode",`String "manual"]) |> Result.get_ok in
  let entry=Keeper_registry.For_testing.register ~base_path:base "imp" meta in
  Fun.protect ~finally:(fun () -> Keeper_registry.For_testing.unregister ~base_path:base "imp") (fun () ->
    let image _ = Ok () in
    check bool "live keeper settings are preserved" true
      (Setup.For_testing.prepare ~base_path:base ~run ~image (request base contents)=Error Setup.Existing_keeper);
    let conditions={Keeper_state_machine.default_conditions with stop_requested=true;drain_complete=true} in
    let stopped={entry with phase=Keeper_state_machine.Stopped;conditions} in
    Keeper_registry.For_testing.unsafe_put_entry ~base_path:base "imp" stopped;
    check bool "stopped phase alone is not settled" true
      (Setup.For_testing.prepare ~base_path:base ~run ~image (request base contents)=Error Setup.Existing_keeper);
    ignore (Keeper_lane.reject_before_start stopped.lane ~reason:(Failure "fixture settled lane"));
    ignore (Setup.For_testing.prepare ~base_path:base ~run ~image (request base contents) |> Result.get_ok);
    let stored=In_channel.with_open_bin path In_channel.input_all in
    let defaults=Keeper_types_profile.materialization_defaults_of_content ~path stored |> Result.get_ok in
    check bool "settled existing keeper receives new declaration" true (defaults.network_mode=Some Keeper_types_profile_sandbox.Network_none);
    let retained=Keeper_registry.get_with_health ~base_path:base "imp" |> Option.get |> fst in
    check string "existing keeper trace/history identity retained" (Keeper_id.Trace_id.to_string meta.trace_id) (Keeper_id.Trace_id.to_string retained.meta.trace_id)))
let () = Alcotest.run "web sandbox preparation" ["publication",[
  test_case "image before CAS and honest receipt" `Quick prepared_receipt;
  test_case "concurrent edit is retained" `Quick concurrent_change;
  test_case "lifecycle reservation blocks publication" `Quick lifecycle_guard;
  test_case "image failure preserves original" `Quick failed_image;
  test_case "settled existing keeper can change without history deletion" `Quick settled_keeper]]

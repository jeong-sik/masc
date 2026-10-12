(** Worker-only stdio proof using a synthetic COM program. *)
open Alcotest
module Transport = Mcp_protocol_eio.Stdio_transport
module Client = Mcp_protocol_eio.Generic_client.Make (Transport)
module S = Mcp_protocol.Mcp_types
module C = Machine_controller_contract
let unwrap = function Ok value -> value | Error message -> fail message
let data result = Option.value ~default:`Null result.S.structured_content
let member name result = Yojson.Safe.Util.member name (data result)

let live_observation result =
  let open Yojson.Safe.Util in
  let packet = data result in
  let row = packet |> member "rows" |> to_list |> List.hd in
  let reference = row |> member "fields" |> member "machine_live" in
  check bool "model context contains a reference, not screen pixels" true
    (match reference with `Assoc fields -> List.sort String.compare (List.map fst fields) = ["sha256"; "uri"] | _ -> false);
  let artifact_id = row |> member "evidence" |> to_list |> List.hd |> member "artifact_id" |> to_string in
  let artifact = packet |> member "artifacts" |> to_list
    |> List.find (fun artifact -> artifact |> member "id" |> to_string = artifact_id) in
  check string "live artifact is JSON" "application/json" (artifact |> member "mime_type" |> to_string);
  let bytes = artifact |> member "data_base64" |> to_string |> Base64.decode_exn in
  let digest = Digestif.SHA256.(to_hex (digest_string bytes)) in
  check string "context digest identifies the screen artifact" digest (reference |> member "sha256" |> to_string);
  check string "context URI identifies the screen artifact" ("lane-evidence:" ^ digest) (reference |> member "uri" |> to_string);
  Yojson.Safe.from_string bytes

let rec remove_owned_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun child -> remove_owned_tree (Filename.concat path child)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let test_stdio_controller () =
  let base_path = Filename.temp_dir "dos-addon-worker-" "" in
  let masc = Common.masc_dir_from_base_path ~base_path in
  Unix.mkdir masc 0o700;
  let dos = Filename.concat masc "dos" in
  Unix.mkdir dos 0o700;
  let programs = Filename.concat dos "programs" in
  Unix.mkdir programs 0o700;
  Out_channel.with_open_bin (Filename.concat programs "hello.com") (fun ch ->
    output_string ch "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$");
  let pads = Filename.concat dos "pads" in
  Unix.mkdir pads 0o700;
  Out_channel.with_open_bin (Filename.concat pads "hello.com.toml") (fun ch ->
    output_string ch "[BTN_SOUTH]\nkeys = [\"enter\"]\nlabel = \"Confirm\"\n");
  Dos_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
  Fun.protect ~finally:(fun () ->
    Dos_lane.install_activity_observer None;
    remove_owned_tree base_path) (fun () ->
    Eio_main.run (fun env ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () ->
        Eio.Switch.run (fun sw ->
          let request_source, request_sink = Eio_unix.pipe sw in
          let response_source, response_sink = Eio_unix.pipe sw in
          Eio.Fiber.first
            (fun () -> Mcp_protocol_eio.Server.run (Dos_addon_worker.create ~base_path ())
              ~stdin:request_source ~stdout:response_sink ~clock:(Eio.Stdenv.clock env) ())
            (fun () ->
              (* Match the DOS package reply envelope, which includes RGB artifacts. *)
              let transport = Transport.create ~stdin:response_source ~stdout:request_sink
                ~max_size:4194304 () in
              let client = Client.create ~transport ~clock:(Eio.Stdenv.clock env) () in
              ignore (unwrap (Client.initialize client ~client_name:"worker-fixture" ~client_version:"1"));
              let tools = unwrap (Client.list_tools_all client) in
              check int "machine tools and private control ports" 18 (List.length tools);
              let raw name arguments = unwrap (Client.call_tool client ~name ~arguments ()) in
              let call ?controller ?(principal=Lane_addon_call_context.Keeper "fixture") name arguments =
                raw Lane_addon_call_context.tool_name
                  (Lane_addon_call_context.to_json_with_controller ~controller ~principal ~tool:name ~arguments) in
              let snapshot () = member "holder" (raw C.snapshot_tool (`Assoc [])) in
              let admission ?release ?handoff_target observed_holder =
                {C.observed_holder;release;handoff_target} in
              let core = member "core" (call "masc_dos_meta" (`Assoc [])) in
              check bool "worker reports its linked core before loading a machine" true
                (core = Dos_lane.core_to_yojson Dos_lane.core);
              check int "worker core source digest is present" 32
                (Yojson.Safe.Util.(core |> member "source_digest" |> to_string |> String.length));
              check bool "worker reports whether its core matches the pin" true
                (match Yojson.Safe.Util.member "matches_pin" core with `Bool _ -> true | _ -> false);
              let load_args = `Assoc ["program", `String "hello.com"] in
              check bool "direct machine call refused" true
                ((raw "masc_dos_load" load_args).is_error = Some true);
              check bool "caller alone cannot authorize controller mutation" true
                ((call "masc_dos_load" load_args).is_error = Some true);
              check bool "failed admission did not create machine" true (snapshot () = `Null);
              let loaded = call ~controller:(admission None) "masc_dos_load" load_args in
              check bool "host admitted load" false (loaded.is_error = Some true);
              check bool "verified caller owns controller" true (snapshot () = `String "fixture");
              let observed = raw "lane_observe" (`Assoc ["binding", `Assoc []; "sources", `List []]) in
              check bool "loaded observation retains screen pixels in its artifact" true
                (Yojson.Safe.Util.(live_observation observed |> member "screen" |> member "rgb_base64" |> to_string |> String.length) > 0);
              let screen = call ~principal:Lane_addon_call_context.Anonymous "masc_dos_screen" (`Assoc []) in
              check bool "pad detail remains opt-in" true (member "pad" screen = `Null);
              check bool "seat saves name comes from worker observation" true
                (member "saves_name" screen = `String "hello.com");
              let pad_screen = call "masc_dos_screen" (`Assoc ["include_pad", `Bool true]) in
              let pad = member "pad" pad_screen in
              check bool "worker reads its current program pad" true
                (Yojson.Safe.Util.member "kind" pad = `String "ready");
              let saved_name, source, layout = unwrap
                (Machine_pad_layout.of_json (Yojson.Safe.Util.member "layout" pad)) in
              check string "pad is bound to loaded saved program" "hello.com" saved_name;
              check bool "pad comes from worker storage" true (source = Machine_pad_layout.Workspace);
              check bool "button keys survive worker projection" true
                (match Machine_pad_layout.binding layout Machine_pad_layout.South with
                 | Some {keys=["enter"];label="Confirm"} -> true | _ -> false);
              check bool "screen read preserves PNG" true
                (List.exists (function S.ImageContent {mime_type="image/png";data;_} ->
                  String.starts_with ~prefix:"\137PNG\r\n\026\n" (Base64.decode_exn data)
                  | _ -> false) screen.content);
              let input_history = Yojson.Safe.Util.(data observed |> member "rows" |> to_list |> List.hd
                |> member "fields" |> member "input_history") in
              let count = Yojson.Safe.Util.(input_history |> member "entry_count" |> to_int) in
              let history_page = raw "lane_machine_inputs" (`Assoc [
                "incarnation", Yojson.Safe.Util.member "incarnation" input_history;
                "entry_count", `Int count; "before", `Int count; "max_bytes", `Int 4194304]) in
              check bool "DOS history port preserves the captured input prefix" true
                (Yojson.Safe.Util.(data history_page |> member "entries" |> to_list)
                  = List.map Dos_lane.entry_json (List.rev (Dos_lane.ledger ())));
              let step_args = `Assoc ["steps", `Int 1] in
              let stale_pad = call ~controller:(admission (Some "fixture"))
                "masc_dos_press" (`Assoc ["keys", `List [`String "enter"];
                  "expected_program", `String "different-program"] ) in
              check bool "stale pad program rejected inside worker" true (stale_pad.is_error = Some true);
              let after_stale_pad = call "masc_dos_screen" (`Assoc []) in
              check bool "stale pad cannot advance the machine" true
                (member "steps" after_stale_pad = member "steps" screen);
              check bool "stale admission rejected" true
                ((call ~controller:(admission None) "masc_dos_step" step_args).is_error = Some true);
              check bool "stale admission keeps owner" true (snapshot () = `String "fixture");
              let human = call ~principal:(Lane_addon_call_context.Host_actor "fixture")
                ~controller:(admission (Some "fixture")) "masc_dos_step" step_args in
              check bool "host-admitted HTTP identity can move its controller" false (human.is_error = Some true);
              let denied = call ~controller:(admission ~handoff_target:"allowed" (Some "fixture"))
                "masc_dos_pass" (`Assoc ["to", `String "forged"]) in
              check bool "handoff cannot change admitted recipient" true (denied.is_error = Some true);
              check bool "denied handoff keeps owner" true (snapshot () = `String "fixture");
              let passed = call ~controller:(admission ~handoff_target:"next" (Some "fixture"))
                "masc_dos_pass" (`Assoc ["to", `String "next"]) in
              check bool "admitted handoff succeeds" false (passed.is_error = Some true);
              check bool "recipient owns controller" true (snapshot () = `String "next");
              let recovered = call ~controller:(admission ~release:C.Keeper_stopped (Some "next"))
                "masc_dos_step" step_args in
              check bool "host can release departed holder and move" false (recovered.is_error = Some true);
              check bool "moving caller takes released controller" true (snapshot () = `String "fixture");
              ignore (call ~controller:(admission ~handoff_target:"next" (Some "fixture"))
                "masc_dos_pass" (`Assoc ["to", `String "next"]));
              let partial = call ~controller:(admission ~release:C.Keeper_stopped (Some "next"))
                "masc_dos_load" (`Assoc ["program", `String "missing.com"]) in
              check bool "missing media is refused after admitted holder recovery" true (partial.is_error=Some true);
              check bool "holder release remains committed despite the load refusal" true (snapshot () = `Null);
              check bool "a committed release cannot be reported as pre-effect" true
                (Lane_addon_tool_result.failure partial =
                  (Tool_result.Workflow_rejection, Tool_result.Proven_post_effect));
              ignore (call ~controller:(admission None) "masc_dos_step" step_args);
              let release holder = raw C.release_tool
                (Lane_addon_call_context.to_json_with_controller
                  ~controller:(Some (admission ~release:C.No_credential (Some holder)))
                  ~principal:(Lane_addon_call_context.Host_actor "operator")
                  ~tool:C.release_tool ~arguments:(`Assoc [])) in
              check bool "lifecycle release cannot displace another holder" true
                (member "released" (release "other-player") = `Bool false);
              check bool "mismatched release retains controller" true (snapshot () = `String "fixture");
              check bool "lifecycle release frees only its named holder" true
                (member "released" (release "fixture") = `Bool true);
              check bool "lifecycle release leaves controller free" true (snapshot () = `Null);
              ignore (call ~controller:(admission None) "masc_dos_step" step_args);
              let ejected = call ~controller:(admission (Some "fixture")) "masc_dos_eject" (`Assoc []) in
              check bool "eject succeeds" false (ejected.is_error = Some true);
              let empty_screen = call "masc_dos_screen" (`Assoc []) in
              check bool "empty screen refuses before any effect" true
                (Lane_addon_tool_result.failure empty_screen =
                  (Tool_result.Workflow_rejection, Tool_result.Proven_pre_effect));
              check bool "screen preserves explicit no-machine status for HTTP" true
                (match empty_screen._meta with
                 | Some (`Assoc fields) ->
                     List.assoc_opt "io.github.jeong-sik/masc.machine.screenError" fields = Some (`String "no_machine")
                 | _ -> false);
              let observed = raw "lane_observe" (`Assoc ["binding", `Assoc []; "sources", `List []]) in
              check bool "eject removes context" true (Yojson.Safe.Util.(live_observation observed |> member "state") = `String "no_machine"))))))

let () = run "DOS standalone Add-on worker"
  ["stdio", [test_case "host admission, handoff, recovery and PNG" `Quick test_stdio_controller]]

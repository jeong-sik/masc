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
  let digest = Agent_core_sha256.(to_hex (digest_string bytes)) in
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
              check int "machine tools and private control ports" 19 (List.length tools);
              let raw name arguments = unwrap (Client.call_tool client ~name ~arguments ()) in
              let call ?controller ?(principal=Lane_addon_call_context.Keeper "fixture") name arguments =
                raw Lane_addon_call_context.tool_name
                  (Lane_addon_call_context.to_json_with_controller ~companion:None ~controller ~principal ~tool:name ~arguments) in
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
              let state_only = call ~principal:Lane_addon_call_context.Anonymous "masc_dos_screen"
                (`Assoc ["include_frame", `Bool false]) in
              check bool "a state-only read carries no image" false
                (List.exists (function S.ImageContent _ -> true | _ -> false) state_only.content);
              check bool "and keeps the seat facts" true
                (member "saves_name" state_only = `String "hello.com"
                 && member "controller" state_only = `String "fixture");
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
                (Lane_addon_call_context.to_json_with_controller ~companion:None
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
                (C.screen_error_of_meta empty_screen._meta = Some C.Screen_no_machine);
              check bool "a state-only read reports no machine the same way" true
                (C.screen_error_of_meta
                   (call "masc_dos_screen" (`Assoc ["include_frame", `Bool false]))._meta
                 = Some C.Screen_no_machine);
              let observed = raw "lane_observe" (`Assoc ["binding", `Assoc []; "sources", `List []]) in
              check bool "eject removes context" true (Yojson.Safe.Util.(live_observation observed |> member "state") = `String "no_machine"))))))

(* The machine is process-global: a test must not hand its machine to the next. *)
let eject_whoever_holds ~default =
  let holder =
    match Dos_lane.screen () with
    | Ok {Dos_lane.controller = Some holder; _} -> holder
    | Ok _ | Error _ -> default in
  ignore (Dos_lane.eject ~who:holder ~announce:ignore () : (unit, Dos_lane.error) result)

(* ---------- exceptions the lane does not type ----------

   An exception the lane does not type -- one the core raises while a call
   runs the guest -- reaches the worker edge. On its way out a call must give
   back the controller it took and release the machine's lock, or the caller
   told "that failed" still holds the pad and the next player is refused. At
   the edge the worker answers with an error result and keeps serving.

   The trigger is real: a guest that EXECs a companion file which is an MZ
   image with a header longer than the file makes the pinned core raise
   Invalid_argument from inside the run (Dos_dos.load_exe, child path). If a
   pin bump makes the core answer that EXEC with a DOS error instead, the
   tests say so and need another trigger. *)

let owner = "owner"

(* Polls the BIOS key read until a key arrives, then EXECs BAD.EXE.
   org 0x100: wait: mov ah,0 / int 16h / or ax,ax / jz wait
              mov ax,cs / mov ds,ax / mov es,ax
              mov dx,name / mov bx,epb / mov ax,4B00h / int 21h / int 20h
   name: "BAD.EXE",0 at 0x11B; epb: 14 zero bytes at 0x123 *)
let exec_after_a_key_com =
  "\xb4\x00\xcd\x16\x09\xc0\x74\xf8\x8c\xc8\x8e\xd8\x8e\xc0\xba\x1b\x01\xbb\x23\x01\
   \xb8\x00\x4b\xcd\x21\xcd\x20BAD.EXE\000"
  ^ String.make 14 '\000'
;;

(* The same EXEC with no key wait first, so it runs during the boot.
   org 0x100: mov ax,cs / mov ds,ax / mov es,ax / mov dx,name / mov bx,epb
              mov ax,4B00h / int 21h / int 20h
   name: "BAD.EXE",0 at 0x113; epb: 14 zero bytes at 0x11B *)
let exec_at_boot_com =
  "\x8c\xc8\x8e\xd8\x8e\xc0\xba\x13\x01\xbb\x1b\x01\xb8\x00\x4b\xcd\x21\xcd\x20BAD.EXE\000"
  ^ String.make 14 '\000'
;;

(* "MZ", a header of 0x1000 paragraphs, and a file of 28 bytes. *)
let malformed_child =
  let image = Bytes.make 28 '\000' in
  Bytes.blit_string "MZ" 0 image 0 2;
  Bytes.set image 9 '\x10';
  Bytes.to_string image
;;

let with_lane run =
  let directory = Filename.temp_dir "masc-dos-fault-" "" in
  Dos_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
  Fun.protect
    ~finally:(fun () ->
      eject_whoever_holds ~default:owner;
      Dos_lane.install_activity_observer None;
      remove_owned_tree directory)
    (fun () -> run directory)
;;

let require = function
  | Ok value -> value
  | Error error -> fail (Dos_lane.error_to_string error)
;;

let controller () = (require (Dos_lane.screen ())).Dos_lane.controller

let test_a_raising_call_gives_the_pad_back () =
  with_lane (fun directory ->
    ignore
      (require
         (Dos_lane.load ~who:owner ~ledger_dir:directory
            ~saves_dir:(Filename.concat directory "saves")
            ~checkpoint_dir:(Filename.concat directory "checkpoints")
            ~previous_autosave:Dos_lane.Keep_previous_autosave ~program_name:"game.com"
            ~program_bytes:exec_after_a_key_com
            ~files:[ "BAD.EXE", malformed_child ]
            ~announce:ignore));
    ignore (require (Dos_lane.pass ~who:owner ~to_:None ~announce:ignore));
    check (option string) "the pad is free before the call" None (controller ());
    (match Dos_lane.press ~who:"alice" ~keys:[ "a" ] ~steps:100_000 ~until_ready:true with
     | exception Invalid_argument _ -> ()
     | Ok _ | Error _ ->
       fail
         "the core no longer raises on a malformed EXEC child: this test needs another \
          trigger for an exception inside a run");
    check (option string) "the caller told it failed does not hold the pad" None (controller ());
    (* The lock was released and nobody holds the pad, so another player moves
       the machine instead of being refused for alice. *)
    match Dos_lane.step ~who:"bob" ~steps:1_000 ~until_ready:false with
    | Ok _ -> check (option string) "bob took the free pad" (Some "bob") (controller ())
    | Error error -> fail (Dos_lane.error_to_string error))
;;

(* The core raises while the program boots. The machine is installed and the
   loader holds it, so the load answers Ok with a faulted boot, and the
   machine's change is announced exactly once. It used to escape as an
   exception with the machine installed, the pad taken and no announcement. *)
let test_a_core_exception_while_booting_is_a_faulted_boot () =
  with_lane (fun directory ->
    let announced = ref 0 in
    (match
       Dos_lane.load ~who:owner ~ledger_dir:directory
         ~saves_dir:(Filename.concat directory "saves")
         ~checkpoint_dir:(Filename.concat directory "checkpoints")
         ~previous_autosave:Dos_lane.Keep_previous_autosave ~program_name:"boom.com"
         ~program_bytes:exec_at_boot_com
         ~files:[ "BAD.EXE", malformed_child ]
         ~announce:(fun () -> incr announced)
     with
     | Ok (_, Dos_lane.Boot_faulted (Dos_lane.Core_exception _)) -> ()
     | Ok (_, Dos_lane.Boot_faulted (Dos_lane.Unimplemented_instruction _)) ->
       fail "the core raised; it did not meet an unimplemented instruction"
     | Ok (_, Dos_lane.Booted _) ->
       fail
         "the core no longer raises on a malformed EXEC child: this test needs another \
          trigger for an exception inside a boot"
     | Error error -> fail (Dos_lane.error_to_string error));
    check int "announced once" 1 !announced;
    let screen = require (Dos_lane.screen ()) in
    check (option string) "the machine is installed" (Some "boom.com") screen.Dos_lane.program;
    check (option string) "and the loader holds it" (Some owner) screen.Dos_lane.controller;
    match Dos_lane.step ~who:owner ~steps:1_000 ~until_ready:false with
    | Ok _ -> ()
    | Error error -> fail (Dos_lane.error_to_string error))
;;

let test_a_typed_outcome_still_keeps_the_pad () =
  (* The restore applies to exceptions only. A typed fault means the call ran,
     and the existing contract keeps the caller as the holder. *)
  with_lane (fun directory ->
    ignore
      (require
         (Dos_lane.load ~who:owner ~ledger_dir:directory
            ~saves_dir:(Filename.concat directory "saves")
            ~checkpoint_dir:(Filename.concat directory "checkpoints")
            ~previous_autosave:Dos_lane.Keep_previous_autosave ~program_name:"game.com"
            ~program_bytes:"\xb4\x00\xcd\x16\x09\xc0\x74\xf8\x8d\xc0" ~files:[]
            ~announce:ignore));
    ignore (require (Dos_lane.pass ~who:owner ~to_:None ~announce:ignore));
    (match Dos_lane.press ~who:"alice" ~keys:[ "a" ] ~steps:100_000 ~until_ready:true with
     | Error (Dos_lane.Guest_fault _) -> ()
     | Error error -> fail (Dos_lane.error_to_string error)
     | Ok _ -> fail "the program should have faulted on lea ax,ax");
    check (option string) "alice ran the guest, so she holds the pad" (Some "alice") (controller ()))
;;

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700
  end

let write_file path contents =
  Out_channel.with_open_bin path (fun channel -> output_string channel contents)

(* The worker over in-process pipes, as the host sees it. [setup] runs first,
   inside the same cleanup, so whatever it leaves behind -- a held machine, the
   activity observer, the workspace -- is removed even when it fails. *)
let with_worker_after ~base_path setup run_client =
  Dos_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
  Fun.protect ~finally:(fun () ->
    eject_whoever_holds ~default:"fixture";
    Dos_lane.install_activity_observer None;
    remove_owned_tree base_path) (fun () ->
    let prepared = setup () in
    Eio_main.run (fun env ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () ->
        Eio.Switch.run (fun sw ->
          let request_source, request_sink = Eio_unix.pipe sw in
          let response_source, response_sink = Eio_unix.pipe sw in
          Eio.Fiber.first
            (fun () -> Mcp_protocol_eio.Server.run (Dos_addon_worker.create ~base_path ())
              ~stdin:request_source ~stdout:response_sink ~clock:(Eio.Stdenv.clock env) ())
            (fun () ->
              let transport = Transport.create ~stdin:response_source ~stdout:request_sink
                ~max_size:4194304 () in
              let client = Client.create ~transport ~clock:(Eio.Stdenv.clock env) () in
              ignore (unwrap (Client.initialize client ~client_name:"worker-fixture"
                ~client_version:"1"));
              run_client client prepared)))))

let with_worker ~base_path run_client =
  with_worker_after ~base_path (fun () -> ()) (fun client () -> run_client client)

let test_contained_turns_an_exception_into_an_error_result () =
  let result = Dos_addon_worker.contained ~tool_name:"masc_dos_step"
    (fun () -> failwith "injected") in
  (match result with
   | Ok answer ->
       check bool "the answer is an error" true (answer.S.is_error = Some true);
       check bool "the exception is in the structured content" true
         (Yojson.Safe.Util.member "exception" (data answer) = `String "Failure(\"injected\")");
       check bool "typed as a runtime failure whose effect is unknown" true
         (Lane_addon_tool_result.failure answer =
           (Tool_result.Runtime_failure, Tool_result.Effect_outcome_unknown))
   | Error message -> fail message);
  let passes = Dos_addon_worker.contained ~tool_name:"masc_dos_step" (fun () ->
    Error "a handler's own error stays its own") in
  check bool "an error the handler returns is not rewritten" true
    (passes = Error "a handler's own error stays its own");
  check_raises "cancellation keeps unwinding" (Eio.Cancel.Cancelled Exit) (fun () ->
    ignore (Dos_addon_worker.contained ~tool_name:"masc_dos_step"
      (fun () -> raise (Eio.Cancel.Cancelled Exit))))

(* Through the worker: a boot that makes the core raise is a completed load
   whose boot says so, and its announcement rides in the call's events. *)
let test_a_core_exception_while_booting_is_a_completed_load () =
  let base_path = Filename.temp_dir "dos-addon-worker-boot-" "" in
  let game = Filename.concat (Filename.concat (Filename.concat
    (Common.masc_dir_from_base_path ~base_path) "dos") "programs") "bad-boot" in
  mkdir_p game;
  write_file (Filename.concat game "GAME.COM") exec_at_boot_com;
  write_file (Filename.concat game "BAD.EXE") malformed_child;
  with_worker ~base_path (fun client ->
    let raw name arguments = unwrap (Client.call_tool client ~name ~arguments ()) in
    let admission = {C.observed_holder=None; release=None; handoff_target=None} in
    let loaded = raw Lane_addon_call_context.tool_name
      (Lane_addon_call_context.to_json_with_controller ~companion:None ~controller:(Some admission)
         ~principal:(Lane_addon_call_context.Keeper "fixture") ~tool:"masc_dos_load"
         ~arguments:(`Assoc ["program", `String "bad-boot"; "boot", `String "GAME.COM"])) in
    check bool "the load completes" false (loaded.S.is_error = Some true);
    let boot = member "boot" loaded in
    check bool "and its boot says the core raised" true
      (Yojson.Safe.Util.member "status" boot = `String "faulted"
       && Yojson.Safe.Util.member "kind" boot = `String "core_exception");
    check bool "the machine's announcement rides in the call's events" true
      (match loaded._meta with
       | Some (`Assoc fields) ->
           (match List.assoc_opt "io.github.jeong-sik/masc.machine.events" fields with
            | Some (`List [ _ ]) -> true
            | _ -> false)
       | _ -> false);
    check bool "the loader holds the controller" true
      (member "holder" (raw C.snapshot_tool (`Assoc [])) = `String "fixture"))

let test_a_handler_exception_does_not_end_the_worker () =
  let base_path = Filename.temp_dir "dos-addon-worker-fault-" "" in
  let game = Filename.concat (Filename.concat (Filename.concat
    (Common.masc_dir_from_base_path ~base_path) "dos") "programs") "bad-child" in
  mkdir_p game;
  write_file (Filename.concat game "GAME.COM") exec_after_a_key_com;
  write_file (Filename.concat game "BAD.EXE") malformed_child;
  with_worker ~base_path (fun client ->
    let raw name arguments = unwrap (Client.call_tool client ~name ~arguments ()) in
    let call ?controller name arguments =
      raw Lane_addon_call_context.tool_name
        (Lane_addon_call_context.to_json_with_controller ~companion:None ~controller
           ~principal:(Lane_addon_call_context.Keeper "fixture") ~tool:name ~arguments) in
    let admission observed_holder = {C.observed_holder; release=None; handoff_target=None} in
    let snapshot () = member "holder" (raw C.snapshot_tool (`Assoc [])) in
    let loaded = call ~controller:(admission None) "masc_dos_load"
      (`Assoc ["program", `String "bad-child"; "boot", `String "GAME.COM"]) in
    check bool "the game loads" false (loaded.is_error = Some true);
    let pressed = call ~controller:(admission (Some "fixture")) "masc_dos_press"
      (`Assoc ["keys", `List [`String "a"]]) in
    check bool "the press that raised inside the core is an error result" true
      (pressed.is_error = Some true);
    check bool "typed as a runtime failure whose effect is unknown" true
      (Lane_addon_tool_result.failure pressed =
        (Tool_result.Runtime_failure, Tool_result.Effect_outcome_unknown));
    check bool "the exception rides in the result" true
      (Yojson.Safe.Util.member "exception" (data pressed) <> `Null);
    (* The worker answers the next call: its process did not end. *)
    check bool "the controller is where it was" true (snapshot () = `String "fixture");
    let screen = call "masc_dos_screen" (`Assoc []) in
    check bool "the next call works" false (screen.is_error = Some true);
    let stepped = call ~controller:(admission (Some "fixture")) "masc_dos_step"
      (`Assoc ["steps", `Int 10]) in
    check bool "and so does a call that moves the machine" false (stepped.is_error = Some true))

(* Prints HI, then polls the BIOS key read: a boot settles and autosaves. *)
let hello_com = "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"

let dos_of ~base_path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "dos"
let checkpoints_of ~base_path = Filename.concat (dos_of ~base_path) "checkpoints"

(* The worker before a restart, and the files it leaves when its process stops
   while the machine runs: it booted hello.com, whose boot autosaved and
   marked the autosave as the running machine's. In one process the machine
   can only be dropped with an eject, which removes that mark, so the
   checkpoint files are put back as the eject found them. It runs as
   [with_worker_after]'s setup, inside the cleanup. *)
let boot_then_stop_the_process ~base_path () =
  let dos = dos_of ~base_path and checkpoints = checkpoints_of ~base_path in
  mkdir_p dos;
  let booted, _boot =
    require
      (Dos_lane.load ~who:"before-restart" ~ledger_dir:dos
         ~saves_dir:(Filename.concat (Filename.concat dos "saves") "hello.com")
         ~checkpoint_dir:checkpoints ~previous_autosave:Dos_lane.Keep_previous_autosave
         ~program_name:"hello.com" ~program_bytes:hello_com ~files:[] ~announce:ignore)
  in
  let files =
    Sys.readdir checkpoints |> Array.to_list |> List.map (Filename.concat checkpoints)
    |> List.map (fun path -> (path, In_channel.with_open_bin path In_channel.input_all))
  in
  require (Dos_lane.eject ~who:"before-restart" ~announce:ignore ());
  List.iter (fun (path, contents) -> write_file path contents) files;
  booted

let worker_call client =
  let raw name arguments = unwrap (Client.call_tool client ~name ~arguments ()) in
  let call ?controller name arguments =
    raw Lane_addon_call_context.tool_name
      (Lane_addon_call_context.to_json_with_controller ~companion:None ~controller
         ~principal:(Lane_addon_call_context.Keeper "fixture") ~tool:name ~arguments) in
  let snapshot () = member "holder" (raw C.snapshot_tool (`Assoc [])) in
  call, snapshot

let free = {C.observed_holder=None; release=None; handoff_target=None}

(* A worker that replaces another one, after a server restart or an image
   upgrade, resumes the autosave before its first call. Guests are not left
   with a no_machine refusal only a controller holder could answer: the screen
   is the autosave's, nobody holds the controller, and the first caller to
   move takes it. *)
let test_a_worker_start_resumes_the_autosave () =
  let base_path = Filename.temp_dir "dos-addon-worker-resume-" "" in
  with_worker_after ~base_path (boot_then_stop_the_process ~base_path) (fun client booted ->
    let call, snapshot = worker_call client in
    let screen = call "masc_dos_screen" (`Assoc ["include_frame", `Bool false]) in
    check bool "the first call finds a machine" false (screen.is_error = Some true);
    check bool "the autosave's program" true (member "saves_name" screen = `String "hello.com");
    check bool "at the autosave's steps" true (member "steps" screen = `Int booted.Dos_lane.steps);
    check bool "with the controller free" true (member "controller" screen = `Null);
    check bool "the lane holds the resumed machine" true
      (match Dos_lane.screen () with
       | Ok o -> o.Dos_lane.program = Some "hello.com" && o.Dos_lane.steps = booted.Dos_lane.steps
       | Error _ -> false);
    check bool "and the host's controller snapshot says nobody holds it" true (snapshot () = `Null);
    let stepped = call ~controller:free "masc_dos_step" (`Assoc ["steps", `Int 10]) in
    check bool "a host-admitted caller moves it" false (stepped.is_error = Some true);
    check bool "and takes the free controller" true (snapshot () = `String "fixture"))

(* An autosave the core accepts far enough to fail while decoding it: a valid
   checkpoint and snapshot header, and the payload cut in half with its MD5
   recomputed, so the checksums pass and only the decoding can refuse it.
   The snapshot layout is the core's (Dos_snapshot): magic, format version,
   core digest, payload MD5, payload. *)
let cut_the_autosave_payload ~checkpoints =
  let slot = Dos_lane.autosave_slot in
  match Machine_checkpoint.read ~dir:checkpoints slot ~machine:Machine_checkpoint.Dos
          ~format:Dos_lane.checkpoint_format with
  | Error error -> fail (Machine_checkpoint.error_to_string error)
  | Ok { Machine_checkpoint.header; meta; machine_bytes } ->
    let digest_at = String.length "OCAML-DOS-SNAPSHOT\000" + 8 + 32 in
    let payload_at = digest_at + 16 in
    let payload = String.sub machine_bytes payload_at (String.length machine_bytes - payload_at) in
    let cut = String.sub payload 0 (String.length payload / 2) in
    (match Machine_checkpoint.write ~dir:checkpoints slot header ~meta
             ~machine_bytes:(String.sub machine_bytes 0 digest_at ^ Digest.string cut ^ cut) with
     | Ok () -> ()
     | Error message -> fail message)

let text_of (result : S.tool_result) =
  match result.S.content with
  | S.TextContent { text; _ } :: _ -> text
  | _ -> fail "the answer has no text"

let mentions needle haystack =
  let rec from i =
    i + String.length needle <= String.length haystack
    && (String.sub haystack i (String.length needle) = needle || from (i + 1)) in
  from 0

(* The worker's start must survive an autosave that will not restore: it
   comes up with no machine, keeps serving, and says why where a caller
   looks, since its container keeps no log. It does not send the caller back
   to the restore that just failed. *)
let test_a_worker_start_survives_an_autosave_that_will_not_restore () =
  let base_path = Filename.temp_dir "dos-addon-worker-bad-autosave-" "" in
  let setup () =
    ignore (boot_then_stop_the_process ~base_path () : Dos_lane.observation);
    cut_the_autosave_payload ~checkpoints:(checkpoints_of ~base_path);
    let programs = Filename.concat (dos_of ~base_path) "programs" in
    mkdir_p programs;
    write_file (Filename.concat programs "hello.com") hello_com
  in
  with_worker_after ~base_path setup (fun client () ->
    let call, snapshot = worker_call client in
    let screen = call "masc_dos_screen" (`Assoc ["include_frame", `Bool false]) in
    check bool "the worker answers with no machine" true
      (C.screen_error_of_meta screen._meta = Some C.Screen_no_machine);
    let autosave = member "autosave" screen in
    let reason = match Yojson.Safe.Util.member "restore_failed_at_start" autosave with
      | `String reason -> reason
      | _ -> fail "the autosave is not named with why the start could not restore it" in
    (* Which way the decoder refused the file, for whoever reads the log. *)
    Printf.printf "start-up restore of the cut autosave failed with: %s\n%!" reason;
    check bool "and not offered back with the command that just failed" true
      (Yojson.Safe.Util.member "resume" autosave = `Null);
    check bool "nor in the message" false (mentions "masc_dos_restore slot=autosave" (text_of screen));
    check bool "the activity feed carries the reason" true
      (match Dos_lane.recent_activity () with
       | newest :: _ -> String.ends_with ~suffix:reason newest.Machine_action_feed.action
       | [] -> false);
    check bool "nobody holds a controller" true (snapshot () = `Null);
    let loaded = call ~controller:free "masc_dos_load" (`Assoc ["program", `String "hello.com"]) in
    check bool "the worker keeps serving: a load goes through" false (loaded.is_error = Some true);
    check bool "and the loader holds the new machine" true (snapshot () = `String "fixture"))

(* The worker declares, on its private effect port, which tools leave its
   observation as it was; the host skips the observation after a successful
   call to one of them. The MCP readOnlyHint it lists comes from the same
   classification, so both say the same thing for every machine tool. *)
let test_the_listing_declares_the_reads () =
  let base_path = Filename.temp_dir "dos-addon-worker-listing-" "" in
  with_worker ~base_path (fun client ->
    let tools = unwrap (Client.list_tools_all client) in
    check bool "the worker opts in to effect negotiation" true
      (List.exists (fun (tool : S.tool) -> tool.name = Lane_addon_call_context.effects_tool
        && Lane_addon_call_context.supports_effects_tool tool.input_schema) tools);
    let declared = unwrap (Client.call_tool client ~name:Lane_addon_call_context.effects_tool
        ~arguments:(`Assoc []) ())
      |> data
      |> Lane_addon_call_context.effects_of_json ~listed:(List.map (fun (tool : S.tool) -> tool.name) tools)
      |> unwrap in
    let reads = List.filter_map (fun (name, effect_of_call) -> match effect_of_call with
      | Lane_addon_call_context.Reads_only -> Some name
      | Lane_addon_call_context.May_change -> None) declared in
    check (list string) "the worker declares exactly the four reads"
      ["masc_dos_inventory"; "masc_dos_meta"; "masc_dos_peek"; "masc_dos_screen"]
      (List.sort String.compare reads);
    List.iter (fun tool ->
      let name = C.dos_tool_name tool in
      check bool (name ^ " has a declared effect") true (List.mem_assoc name declared);
      match List.find_opt (fun (listed : S.tool) -> String.equal listed.name name) tools with
      | None -> fail (name ^ " is not listed")
      | Some listed ->
          check (option bool) (name ^ " lists a readOnlyHint matching its declaration")
            (Some (List.mem name reads))
            (Option.bind listed.annotations (fun annotations -> annotations.S.read_only_hint)))
      C.all_of_dos_tool)

let () = run "DOS standalone Add-on worker"
  ["stdio", [test_case "host admission, handoff, recovery and PNG" `Quick test_stdio_controller;
             test_case "the listing declares the reads" `Quick test_the_listing_declares_the_reads;
             test_case "a handler exception does not end the worker" `Quick
               test_a_handler_exception_does_not_end_the_worker;
             test_case "a core exception while booting is a completed load" `Quick
               test_a_core_exception_while_booting_is_a_completed_load;
             test_case "a worker start resumes the autosave" `Quick
               test_a_worker_start_resumes_the_autosave;
             test_case "a worker start survives an autosave that will not restore" `Quick
               test_a_worker_start_survives_an_autosave_that_will_not_restore];
   "edge", [test_case "contained turns an exception into an error result" `Quick
              test_contained_turns_an_exception_into_an_error_result];
   "lane exceptions", [test_case "a raising call gives the pad back" `Quick
                         test_a_raising_call_gives_the_pad_back;
                       test_case "a core exception while booting is a faulted boot" `Quick
                         test_a_core_exception_while_booting_is_a_faulted_boot;
                       test_case "a typed fault still keeps the pad" `Quick
                         test_a_typed_outcome_still_keeps_the_pad]]

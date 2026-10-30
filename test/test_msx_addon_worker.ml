(** The standalone worker's SDK stdio path, using an empty synthetic machine.
    No MASC server, Docker daemon, BIOS image or copyrighted media is needed. *)
open Alcotest
module Client = Mcp_protocol_eio.Client
module S = Mcp_protocol.Mcp_types
let unwrap = function Ok value -> value | Error message -> fail message
let data result = Option.value ~default:`Null result.S.structured_content
let frame result = Yojson.Safe.Util.(data result |> member "frame" |> to_int)


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

let test_stdio_machine_lifecycle () =
  let base_path = Filename.temp_dir "msx-addon-worker-" "" in
  let masc = Common.masc_dir_from_base_path ~base_path in
  Unix.mkdir masc 0o700;
  let msx = Filename.concat masc "msx" in
  Unix.mkdir msx 0o700;
  let carts = Filename.concat msx "carts" in
  Unix.mkdir carts 0o700;
  Out_channel.with_open_bin (Filename.concat carts "fixture.rom") (fun channel ->
    output_string channel "inventory-only fixture");
  (* The worker takes its C-BIOS from the volume's bios/ inventory: three
     zero-filled ROMs stand in for it. A host MSX_ROMS would override the
     inventory, so it is emptied for the run. *)
  let bios = Filename.concat msx "bios" in
  Unix.mkdir bios 0o700;
  List.iter (fun (name, size) ->
    Out_channel.with_open_bin (Filename.concat bios name) (fun channel ->
      output_string channel (String.make size '\000')))
    ["cbios_main_msx2.rom", 32768; "cbios_logo_msx2.rom", 16384; "cbios_sub.rom", 16384];
  let host_roms = Sys.getenv_opt "MSX_ROMS" in
  Unix.putenv "MSX_ROMS" "";
  Msx_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
  Fun.protect ~finally:(fun () ->
    Unix.putenv "MSX_ROMS" (Option.value host_roms ~default:"");
    ignore (Msx_lane.eject ());
    Msx_lane.install_activity_observer None;
    remove_owned_tree base_path) (fun () ->
    Eio_main.run (fun env ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () ->
        Eio.Switch.run (fun sw ->
          let request_source, request_sink = Eio_unix.pipe sw in
          let response_source, response_sink = Eio_unix.pipe sw in
          Eio.Fiber.first
            (fun () -> Mcp_protocol_eio.Server.run (Msx_addon_worker.create ~base_path ())
              ~stdin:request_source ~stdout:response_sink ~clock:(Eio.Stdenv.clock env) ())
            (fun () ->
              let client = Client.create ~stdin:response_source ~stdout:request_sink
                ~clock:(Eio.Stdenv.clock env) () in
              ignore (unwrap (Client.initialize client ~client_name:"worker-fixture" ~client_version:"1"));
              let tools = unwrap (Client.list_tools_all client) in
              check int "machine tools and private control ports" 17 (List.length tools);
              check bool "disk export is discovered through the worker protocol" true
                (List.exists (fun (tool : S.tool) -> tool.name = "masc_msx_export_disk") tools);
              let call name arguments =
                let name, arguments = if String.equal name "lane_observe" then name, arguments
                  else Lane_addon_call_context.tool_name,
                    Lane_addon_call_context.to_json ~tool:name ~arguments
                      ~principal:(Lane_addon_call_context.Keeper "fixture") in
                unwrap (Client.call_tool client ~name ~arguments ()) in
              let direct = unwrap (Client.call_tool client ~name:"masc_msx_load" ~arguments:(`Assoc []) ()) in
              check bool "direct calls cannot omit caller context" true (direct.is_error = Some true);
              let observe () = call "lane_observe" (`Assoc ["binding", `Assoc []; "sources", `List []]) in
              check bool "unloaded worker has no screen context" true
                (Yojson.Safe.Util.(live_observation (observe ()) |> member "state") = `String "no_machine");
              let meta = call "masc_msx_meta" (`Assoc ["include_inventory", `Bool true]) in
              check bool "worker metadata does not impersonate host activity policy" true
                (Yojson.Safe.Util.member "activity" (data meta) = `Null);
              let inventory = Yojson.Safe.Util.member "inventory" (data meta) in
              check bool "inventory is read from worker-owned storage" true
                (Yojson.Safe.Util.member "carts" inventory = `List [`String "fixture.rom"]);
              check bool "inventory read does not load a machine" true
                (Yojson.Safe.Util.member "loaded" inventory = `Bool false);
              let absent_export = call "masc_msx_export_disk" (`Assoc ["filename", `String "new-data.dsk"]) in
              check bool "export before loading is refused through caller-context port" true
                (absent_export.is_error = Some true);
              check bool "refused export creates no file" false
                (Sys.file_exists (Filename.concat carts "new-data.dsk"));
              let refused = call "masc_msx_load" (`Assoc ["roms_dir", `String ""]) in
              check bool "a load that names no image is refused" true (refused.is_error = Some true);
              check bool "and loads no machine" true
                (Yojson.Safe.Util.(live_observation (observe ()) |> member "state") = `String "no_machine");
              let loaded = call "masc_msx_load" (`Assoc ["roms_dir", `String ""; "cart", `String "fixture"]) in
              check bool "load succeeds with an inventory image" false (loaded.is_error = Some true);
              let before = frame loaded in
              let overflow = call "masc_msx_peek" (`Assoc ["address", `String "3fffffffffffffff";
                "length", `Int 16]) in
              check bool "an address beyond 16 bits is refused" true (overflow.is_error = Some true);
              check int "the worker still answers after the refusal" before
                (frame (call "masc_msx_screen" (`Assoc [])));
              let digits = call "masc_msx_peek" (`Assoc ["address", `String "4096"; "length", `Int 4]) in
              check string "bare digits are a hex address, answered as four hex digits" "4096"
                Yojson.Safe.Util.(data digits |> member "address" |> to_string);
              check bool "loaded observation retains screen pixels in its artifact" true
                (Yojson.Safe.Util.(live_observation (observe ()) |> member "screen" |> member "rgb_base64" |> to_string |> String.length) > 0);
              let invalid = call "masc_msx_step" (`Assoc ["frames", `Int 301]) in
              check bool "worker enforces the same declared frame bound" true (invalid.is_error = Some true);
              let screen = call "masc_msx_screen" (`Assoc ["sprites", `Bool true]) in
              check int "invalid step has no machine effect" before (frame screen);
              check bool "screen carries actual PNG bytes" true
                (List.exists (function S.ImageContent {mime_type="image/png";data;_} ->
                  let bytes = Base64.decode_exn data in
                  String.starts_with ~prefix:"\137PNG\r\n\026\n" bytes | _ -> false) screen.content);
              check bool "sprite option survives worker projection" true
                (match Yojson.Safe.Util.member "sprites" (data screen) with `List _ -> true | _ -> false);
              let ordinary_screen = call "masc_msx_screen" (`Assoc []) in
              check bool "sprite detail remains opt-in" true
                (Yojson.Safe.Util.member "sprites" (data ordinary_screen) = `Null);
              let saved = call "masc_msx_save" (`Assoc ["slot", `String "fixture"]) in
              check bool "checkpoint saved" false (saved.is_error = Some true);
              ignore (call "masc_msx_step" (`Assoc ["frames", `Int 1]));
              let restored = call "masc_msx_restore" (`Assoc ["slot", `String "fixture"]) in
              check int "restore returns to the persisted frame" before (frame restored);
              let pressed = call "masc_msx_press" (`Assoc ["keys", `List [`String "space"];
                "hold_frames", `Int 1; "frames", `Int 1]) in
              check bool "host-named press succeeds" false (pressed.is_error = Some true);
              check bool "input ledger preserves the host's named principal" true
                (List.exists (fun (entry : Msx_lane.entry) -> entry.who = "fixture") (Msx_lane.ledger ()));
              ignore (call "masc_msx_press" (`Assoc ["keys", `List [`String "space"];
                "hold_frames", `Int 1; "frames", `Int 1]));
              let captured = data (observe ()) in
              let history = Yojson.Safe.Util.(captured |> member "rows" |> to_list |> List.hd
                |> member "fields" |> member "input_history") in
              let count = Yojson.Safe.Util.(history |> member "entry_count" |> to_int) in
              let incarnation = Yojson.Safe.Util.member "incarnation" history in
              let read_history ~before ~max_bytes = Client.call_tool client ~name:"lane_machine_inputs"
                ~arguments:(`Assoc ["incarnation",incarnation;"entry_count",`Int count;
                  "before",`Int before;"max_bytes",`Int max_bytes]) () in
              let all = data (unwrap (read_history ~before:count ~max_bytes:4194304)) in
              let entries = Yojson.Safe.Util.(all |> member "entries" |> to_list) in
              check bool "history matches the frame's captured prefix" true
                (entries = List.map Msx_lane.entry_json (List.rev (Msx_lane.ledger ())));
              check bool "fixture has multiple input records" true (count >= 2);
              let first = `Assoc ["incarnation",incarnation;"entry_count",`Int count;
                "before",`Int count;"next_before",`Int (count-1);"entries",`List [List.hd entries]] in
              let max_bytes = String.length (Yojson.Safe.to_string first) in
              let first_page = data (unwrap (read_history ~before:count ~max_bytes)) in
              check bool "byte envelope produces an exact first page" true (first_page = first);
              let rest = data (unwrap (read_history ~before:(count-1) ~max_bytes:4194304)) in
              check bool "next cursor neither duplicates nor omits inputs" true
                (Yojson.Safe.Util.(rest |> member "entries" |> to_list) = List.tl entries);
              let tiny = read_history ~before:count ~max_bytes:1 in
              check bool "insufficient envelope is an explicit refusal" true
                (match tiny with Error _ -> true | Ok result -> result.is_error = Some true);
              ignore (call "masc_msx_press" (`Assoc ["keys", `List [`String "space"];
                "hold_frames", `Int 1; "frames", `Int 1]));
              check bool "live input cannot change a published prefix" true
                (data (unwrap (read_history ~before:count ~max_bytes:4194304)) = all);
              ignore (observe ());
              check bool "superseded capture cannot serve an old cursor" true
                (match read_history ~before:count ~max_bytes:4194304 with
                 | Error _ -> true | Ok result -> result.is_error = Some true);
              let tick = call "masc_msx_step" (`Assoc ["frames", `Int 1;
                "include_frame", `Bool true; "pixel_response", `String "retained"]) in
              check bool "atomic frame tick succeeds" false (tick.is_error = Some true);
              let pixels = Yojson.Safe.Util.member "pixels" (data tick) in
              check bool "first tick carries inline pixels" true
                (Yojson.Safe.Util.member "kind" pixels = `String "inline");
              let known = `Assoc (List.map (fun name -> name, Yojson.Safe.Util.member name pixels)
                ["revision"; "width"; "height"]) in
              let next = call "masc_msx_step" (`Assoc ["frames", `Int 1;
                "include_frame", `Bool true; "pixel_response", `String "retained"; "known_pixels", known]) in
              let n result = Yojson.Safe.Util.(data result |> member "number" |> to_int) in
              check int "tick advances exactly once" (n tick + 1) (n next);
              check bool "unchanged pixels can be retained" true
                (Yojson.Safe.Util.(data next |> member "pixels" |> member "kind") = `String "retained");
              let invalid_pixels = call "masc_msx_step" (`Assoc ["frames", `Int 1;
                "pixel_response", `String "retained"]) in
              check bool "pixel options require explicit frame mode" true (invalid_pixels.is_error = Some true);
              check int "invalid frame options cannot advance machine" (n next) (frame (call "masc_msx_screen" (`Assoc [])));
              check int "worker exposes one owned screen context" 1
                Yojson.Safe.Util.(data (observe ()) |> member "rows" |> to_list |> List.length);
              ignore (call "masc_msx_eject" (`Assoc []));
              check bool "eject removes screen context" true
                (Yojson.Safe.Util.(live_observation (observe ()) |> member "state") = `String "no_machine"))))))

(* The exception boundary every machine call passes through. *)
let test_exception_boundary () =
  let tool_name = "masc_msx_screen" in
  let contain run = Msx_addon_worker.contain ~tool_name ~start_time:(Tool_timing.start ()) run in
  let completed = {S.content = []; is_error = Some false; structured_content = None; _meta = None} in
  check bool "a completed call passes through unchanged" true (contain (fun () -> completed) == completed);
  List.iter (fun (label, raise_it) ->
    let result = contain raise_it in
    check bool (label ^ " becomes an error result") true (result.S.is_error = Some true);
    check bool (label ^ " is an unknown-effect runtime failure") true
      (Lane_addon_tool_result.failure result
       = (Tool_result.Runtime_failure, Tool_result.Effect_outcome_unknown)))
    ["Sys_error", (fun () -> raise (Sys_error "disk full"));
     "Invalid_argument", (fun () -> raise (Invalid_argument "index out of bounds"));
     "Not_found", (fun () -> raise Not_found);
     "Failure", (fun () -> failwith "defect")];
  check_raises "cancellation is not a failure" (Eio.Cancel.Cancelled Exit)
    (fun () -> ignore (contain (fun () -> raise (Eio.Cancel.Cancelled Exit))))

(* The result names the exception; the log keeps where it was raised. *)
let test_exception_boundary_logs_the_raise_site () =
  Printexc.record_backtrace true;
  let marker = "boundary-log-marker-7f3a" in
  let contains text needle =
    let n = String.length needle in
    let rec go i = i + n <= String.length text && (String.sub text i n = needle || go (i + 1)) in
    go 0 in
  ignore (Msx_addon_worker.contain ~tool_name:"masc_msx_screen"
    ~start_time:(Tool_timing.start ()) (fun () -> failwith marker));
  let logged =
    Log.Ring.recent ~limit:50 ~module_filter:"Msx" ()
    |> List.filter (fun (entry : Log.Ring.entry) -> contains entry.message marker) in
  match logged with
  | [ entry ] ->
      check bool "it is an error line" true (entry.level = Log.Error);
      check bool "it carries the raise site" true (contains entry.message "Raised at")
  | entries ->
      fail (Printf.sprintf "expected one log line for the exception, got %d" (List.length entries))

let () = run "MSX standalone Add-on worker"
  ["stdio", [test_case "tool validation, screen and checkpoint lifecycle" `Quick test_stdio_machine_lifecycle];
   "boundary", [test_case "an escaped exception becomes a result" `Quick test_exception_boundary;
                test_case "an escaped exception is logged with its raise site" `Quick
                  test_exception_boundary_logs_the_raise_site]]

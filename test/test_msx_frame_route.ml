(* The MSX frame serializer (RFC-0439 §3.7): no machine -> loaded:false; a
   loaded machine -> a base64 RGB frame the width*height says it is. Drives the
   real Msx_lane, no ROM needed (the bus reads 0xFF). *)

open Alcotest
module Lane = Msx_lane
module Route = Server_routes_http_routes_msx
module Lane2 = Msx_lane

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let with_tick_machine f =
  let dir = Filename.temp_dir "msx-tick-route-" "" in
  Fun.protect
    ~finally:(fun () ->
      (match Lane.eject () with Ok () | Error Lane.No_machine -> ()
       | Error e -> fail (Lane.error_to_string e));
      Array.iter (fun name -> Sys.remove (Filename.concat dir name)) (Sys.readdir dir);
      Unix.rmdir dir)
    (fun () ->
      (match Lane.load ~ledger_dir:dir ~roms_dir:"" ~cart_path:None ~disk_path:None with
       | Ok _ -> () | Error e -> fail (Lane.error_to_string e));
      f ())

let frame_number json =
  match member "number" json with
  | Some (`Int n) -> n | _ -> fail "missing frame number"

let pixels_object json =
  match member "pixels" json with Some (`Assoc fields) -> fields | _ -> fail "missing pixels"

let retained_request ?(frames = 1) json =
  let fields = pixels_object json in
  let reference = List.map (fun name -> name, List.assoc name fields)
      ["revision"; "width"; "height"] in
  Yojson.Safe.to_string (`Assoc ["frames", `Int frames;
    "pixel_response", `String "retained"; "known_pixels", `Assoc reference])

let assert_pixels_kind expected json =
  check (option string) "pixel representation" (Some expected)
    (match List.assoc_opt "kind" (pixels_object json) with Some (`String s) -> Some s | _ -> None)

let test_retained_tick () =
  with_tick_machine (fun () ->
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      let pool = Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
      Executor_pool_ref.For_testing.with_pool pool (fun () ->
        let first_status, first = Route.tick_response
            ~body:{|{"frames":1,"pixel_response":"retained"}|} in
        check bool "first tick succeeds" true (first_status = `OK);
        assert_pixels_kind "inline" first;
        let before = frame_number first in
        let status, next = Route.tick_response ~body:(retained_request first) in
        check bool "retained tick succeeds" true (status = `OK);
        assert_pixels_kind "retained" next;
        check int "retention still advances exactly once" (before + 1) (frame_number next);
        check bool "retained response carries no encoded pixels" false
          (List.mem_assoc "rgb_base64" (pixels_object next));
        (match Lane.step_frame ~frames:1 with
         | Error error -> fail (Lane.error_to_string error)
         | Ok (snapshot, ledger) ->
             ignore (Lane.step ~frames:1);
             check int "captured frame remains at its own atomic step" (before + 2) snapshot.number;
             check bool "captured ledger is immutable" true (ledger = []));
        ignore (Lane.press ~who:"bob" ~keys:[Result.get_ok (Lane.key_of_string "space")] ~hold_frames:1 ~step_frames:1 ~sequence:false);
        let _, after_press = Route.tick_response ~body:(retained_request next) in
        assert_pixels_kind "retained" after_press;
        check bool "fresh players survive retained pixels" true
          (match member "players" after_press with Some (`List players) ->
            List.exists (fun json -> member "who" json = Some (`String "bob")) players | _ -> false);
        ignore (Lane.eject ());
        let status, empty = Route.tick_response ~body:(retained_request next) in
        check bool "missing machine remains a successful empty observation" true
          (status = `OK && member "loaded" empty = Some (`Bool false));
        check bool "empty machine never advertises stale pixels" true (member "pixels" empty = None)))))

let test_tick_validation_precedes_mutation () =
  with_tick_machine (fun () ->
    let before = frame_number (Route.frame_json ()) in
    Executor_pool_ref.For_testing.with_pool_option None (fun () ->
      List.iter (fun body ->
        let status, response = Route.tick_response ~body in
        check bool "invalid tick is a bad request" true (status = `Bad_request);
        check bool "invalid tick carries failure" true (member "ok" response = Some (`Bool false));
        check int "invalid tick never advances the loaded machine" before
          (frame_number (Route.frame_json ())))
        [ ""; "{"; "null"; "[]"; "18"; {|{"frames":"18"}|}
        ; {|{"frames":1.5}|}; {|{"frames":true}|}; {|{"frames":null}|}
        ; {|{"frames":1,"frames":2}|}; {|{"frames":1,"unexpected":true}|}
        ; {|{"unexpected":18}|}
        ; {|{"pixel_response":"unknown"}|}; {|{"pixel_response":null}|}
        ; {|{"known_pixels":{}}|}; {|{"pixel_response":"retained","known_pixels":{}}|}
        ; {|{"pixel_response":"retained","pixel_response":"retained"}|}
        ; {|{"pixel_response":"retained","known_pixels":{"revision":"bad","width":1,"height":1}}|} ];
      let status, _ = Route.tick_response ~body:"{}" in
      check bool "missing executor cannot fall back to inline mutation" true
        (status = `Service_unavailable);
      check int "missing executor preserves machine" before
        (frame_number (Route.frame_json ()))))

let test_tick_worker_advances_and_returns_frame () =
  with_tick_machine (fun () ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let pool = Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
        Executor_pool_ref.For_testing.with_pool pool (fun () ->
          List.iter (fun (body, frames) ->
            let before = frame_number (Route.frame_json ()) in
            let status, response = Route.tick_response ~body in
            check bool "accepted tick succeeds through executor" true (status = `OK);
            check int "response includes exactly the accepted advance" frames
              (frame_number response - before);
            check int "returned frame matches current machine" (frame_number response)
              (frame_number (Route.frame_json ())))
            [ "{}", Route.msx_tick_default_frames
            ; {|{"frames":0}|}, 1
            ; {|{"frames":999999}|}, Lane.max_frames_per_call ]))))

let test_checkpoint_route () =
  with_tick_machine (fun () ->
    let base_path = Filename.temp_dir "msx-checkpoint-route-" "" in
    let before = frame_number (Route.frame_json ()) in
    Executor_pool_ref.For_testing.with_pool_option None (fun () ->
      List.iter (fun body ->
        let status, _ = Route.checkpoint_response ~base_path ~restore:false ~body in
        check bool "checkpoint validates before requesting worker" true (status = `Bad_request))
        ["[]"; {|{"slot":3}|}; {|{"slot":"../escape"}|}; {|{"slot":"x","slot":"y"}|}; {|{"extra":true}|}];
      let status, _ = Route.checkpoint_response ~base_path ~restore:false ~body:"{}" in
      check bool "checkpoint never runs inline without a worker" true (status = `Service_unavailable));
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      let pool = Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
      Executor_pool_ref.For_testing.with_pool pool (fun () ->
        let status, _ = Route.checkpoint_response ~base_path ~restore:false ~body:"{}" in
        check bool "save through executor succeeds" true (status = `OK);
        ignore (Lane.step ~frames:12 : (Lane.observation, Lane.error) result);
        let status, _ = Route.checkpoint_response ~base_path ~restore:true ~body:"{}" in
        check bool "restore through executor succeeds" true (status = `OK);
        check int "saved clock restored" before (frame_number (Route.frame_json ()));
        let destination = Filename.concat base_path ".masc/msx/saves/quick.json" in
        Sys.remove destination; Sys.mkdir destination 0o700;
        let status, response = Route.checkpoint_response ~base_path ~restore:false ~body:"{}" in
        check bool "storage failure is server error" true (status = `Internal_server_error);
        check bool "storage error carries failure" true (member "ok" response = Some (`Bool false));
        check int "storage failure preserves machine" before (frame_number (Route.frame_json ()))))))

let test_encoded_pixel_snapshot () =
  let base_path = Filename.temp_dir "msx-encoded-frame-" "" in
  Fun.protect
    ~finally:(fun () ->
      ignore (Lane.eject () : (unit, Lane.error) result);
      let rec remove_tree path =
        if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
          Array.iter (fun name -> remove_tree (Filename.concat path name))
            (Sys.readdir path);
          Unix.rmdir path
        end else Unix.unlink path
      in
      remove_tree base_path)
    (fun () ->
  let ledger_dir = Filename.concat base_path "ledger" in
  let require = function Ok value -> value | Error e -> fail (Lane.error_to_string e) in
  let pixels json = match member "rgb_base64" json with
    | Some (`String encoded) -> encoded | _ -> fail "missing encoded pixels" in
  (* Original synthetic firmware jumps into an original 16 KiB cartridge.
     The guest enables text display and changes R7 between palette colors 2
     and 3 once per VBlank. Thus advancing one frame changes actual pixels,
     rather than merely allocating another all-black buffer. *)
  let roms_dir = Filename.concat base_path "pixel-bios" in
  Sys.mkdir roms_dir 0o755;
  let write_code bytes offset code =
    List.iteri (fun i n -> Bytes.set bytes (offset + i) (Char.chr n)) code in
  let bios = Bytes.make 32768 '\000' in
  write_code bios 0 [0xc3; 0x10; 0x40]; (* JP 4010; cartridge page is slot 2 *)
  Out_channel.with_open_bin (Filename.concat roms_dir "cbios_main_msx2.rom")
    (fun oc -> output_bytes oc bios);
  let cart = Bytes.make 16384 '\000' in
  write_code cart 0 [0x41; 0x42; 0x10; 0x40];
  write_code cart 0x10 [
    0xf3; 0x06; 0x02;                 (* DI; LD B,2 *)
    0x3e; 0x50; 0xd3; 0x99;           (* text mode, display enabled *)
    0x3e; 0x81; 0xd3; 0x99;           (* write VDP register 1 *)
    0xdb; 0x99; 0xe6; 0x80; 0x28; 0xfa; (* 401B: wait for VBlank *)
    0x78; 0xee; 0x01; 0x47;           (* toggle color 2 / 3 *)
    0xd3; 0x99; 0x3e; 0x87; 0xd3; 0x99; (* write VDP register 7 *)
    0xc3; 0x1b; 0x40 ];
  let cart_path = Filename.concat base_path "pixel-toggle.rom" in
  Out_channel.with_open_bin cart_path (fun oc -> output_bytes oc cart);
  ignore (require (Msx_lane.load ~ledger_dir ~roms_dir
                     ~cart_path:(Some cart_path) ~disk_path:None));
    let first = Route.frame_json () in
    let encoded = pixels first in
    let allocated = Gc.allocated_bytes () in
    for _ = 1 to 100 do
      let again = Route.frame_json () in
      check bool "unchanged route reuses encoded pixels" true (encoded == pixels again)
    done;
    let allocation = Gc.allocated_bytes () -. allocated in
    Printf.printf "MSX 100 unchanged route reads allocate %.0f bytes (Base64=%d bytes)\n%!"
      allocation (String.length encoded);
    check bool "no full encoded buffer per observation" true
      (allocation < float_of_int (100 * String.length encoded));
    let save_path = Filename.concat base_path "before.json" in
    ignore (require (Lane.save ~path:save_path));
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      let pool = Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
      Executor_pool_ref.For_testing.with_pool pool (fun () ->
        let status, first_tick = Route.tick_response
            ~body:{|{"frames":2,"pixel_response":"retained"}|} in
        check bool "real guest tick succeeds" true (status = `OK);
        assert_pixels_kind "inline" first_tick;
        let _, same_pixels = Route.tick_response ~body:(retained_request ~frames:2 first_tick) in
        assert_pixels_kind "retained" same_pixels;
        let _, changed_pixels = Route.tick_response ~body:(retained_request same_pixels) in
        assert_pixels_kind "inline" changed_pixels;
        let pixel_fields = pixels_object changed_pixels in
        let rgb = match List.assoc "rgb_base64" pixel_fields with
          | `String encoded -> Base64.decode_exn encoded | _ -> fail "missing inline bytes" in
        (match Lane.frame () with Some actual -> check string "changed tick pixels match guest" actual.rgb rgb
         | None -> fail "guest disappeared");
        check bool "changed pixels have exact SHA256" true
          (List.assoc "revision" pixel_fields = `String Digestif.SHA256.(to_hex (digest_string rgb))))));
    ignore (require (Lane.restore ~path:save_path ~ledger_dir));
    ignore (require (Lane.step ~frames:1));
    let advanced = Route.frame_json () in
    check int "clock remains live" (frame_number first + 1) (frame_number advanced);
    check bool "changed pixels replace encoded snapshot" false
      (String.equal encoded (pixels advanced));
    (match Lane.frame () with
     | Some frame -> check string "encoding agrees with current RGB" frame.rgb
         (Base64.decode_exn (pixels advanced))
     | None -> fail "machine disappeared");
    ignore (require (Lane.restore ~path:save_path ~ledger_dir));
    let restored = Route.frame_json () in
    check int "restored clock" (frame_number first) (frame_number restored);
    check string "restore does not retain future pixels" encoded (pixels restored);
    ignore (require (Lane.eject ()));
    check bool "eject does not expose cached pixels" true
      (member "rgb_base64" (Route.frame_json ()) = None);
    ignore (require (Lane.load ~ledger_dir ~roms_dir:"" ~cart_path:None ~disk_path:None));
    let replacement = Route.frame_json () in
    check bool "replacement machine does not inherit cached pixels" false
      (String.equal encoded (pixels replacement)))

let () =
  run "msx frame route"
    [ ( "checkpoint", [test_case "validation, worker, restore and storage failure" `Quick test_checkpoint_route])
    ; ( "frame_json"
      , [ test_case "encoded snapshots follow real guest changes and restore" `Quick test_encoded_pixel_snapshot
        ; test_case "no machine is loaded:false" `Quick (fun () ->
            ignore (Lane.eject () : (unit, Lane.error) result);
            let j = Route.frame_json () in
            check (option bool) "loaded is false" (Some false)
              (match member "loaded" j with Some (`Bool b) -> Some b | _ -> None);
            check bool "no pixels when unloaded" true (member "rgb_base64" j = None))
        ; test_case "a loaded machine yields a decodable frame" `Quick (fun () ->
            let dir = Filename.temp_dir "msx-frame-route-" "" in
            (match Lane.load ~ledger_dir:dir ~roms_dir:"" ~cart_path:None ~disk_path:None with
             | Ok _ -> ()
             | Error e -> fail (Lane.error_to_string e));
            let j = Route.frame_json () in
            check (option bool) "loaded is true" (Some true)
              (match member "loaded" j with Some (`Bool b) -> Some b | _ -> None);
            let field n = match member n j with Some (`Int v) -> v | _ -> fail (n ^ " missing") in
            let w = field "width" and h = field "height" in
            check bool "width and height are positive" true (w > 0 && h > 0);
            check bool "frame number is the boot count" true (field "number" = Lane.boot_frames);
            (match member "rgb_base64" j with
             | Some (`String b64) ->
               let rgb = Base64.decode_exn b64 in
               check int "decoded RGB is width*height*3" (w * h * 3) (String.length rgb)
             | _ -> fail "no rgb_base64");
            check bool "mode is named" true
              (match member "mode" j with Some (`String s) -> String.length s > 0 | _ -> false);
            ignore (Lane.eject () : (unit, Lane.error) result))
        ] )
    ; ( "press_json"
      , [ test_case "press result carries ok and the new frame" `Quick (fun () ->
            let dir = Filename.temp_dir "msx-press-route-" "" in
            (match Lane.load ~ledger_dir:dir ~roms_dir:"" ~cart_path:None ~disk_path:None with
             | Ok _ -> () | Error e -> fail (Lane.error_to_string e));
            (match Lane.press ~who:"operator" ~keys:[ Result.get_ok (Lane.key_of_string "space") ]
                     ~hold_frames:2 ~step_frames:6 ~sequence:false with
             | Ok obs ->
               let j = Route.press_result_json ~ok:true (Some obs) in
               check (option bool) "ok true" (Some true)
                 (match member "ok" j with Some (`Bool b) -> Some b | _ -> None);
               check bool "frame advanced past boot" true
                 (match member "frame" j with Some (`Int n) -> n > Lane.boot_frames | _ -> false);
               (* the press landed in the ledger under the operator *)
               check bool "operator edge recorded" true
                 (List.exists (fun (e : Lane.entry) -> e.who = "operator") (Lane.ledger ()))
             | Error e -> fail (Lane.error_to_string e));
            let j = Route.press_result_json ~ok:false ~message:"nope" None in
            check (option bool) "failure is ok:false" (Some false)
              (match member "ok" j with Some (`Bool b) -> Some b | _ -> None);
            check (option string) "failure carries the message" (Some "nope")
              (match member "message" j with Some (`String m) -> Some m | _ -> None);
            ignore (Lane.eject () : (unit, Lane.error) result))
        ] )
    ; ( "carts_json"
      , [ test_case "the inventory lists the cartridges under carts/" `Quick (fun () ->
            ignore (Lane.eject () : (unit, Lane.error) result);
            let base = Filename.temp_dir "msx-carts-route-" "" in
            let mk d = if not (Sys.file_exists d) then Sys.mkdir d 0o755 in
            let masc = Filename.concat base ".masc" in
            let msx = Filename.concat masc "msx" in
            let carts = Filename.concat msx "carts" in
            mk masc; mk msx; mk carts;
            let touch name =
              Out_channel.with_open_bin (Filename.concat carts name)
                (fun oc -> output_string oc "\xff")
            in
            touch "dig-dug.rom";
            touch "pac-man.rom";
            let j = Route.carts_json ~base_path:base in
            let names =
              match member "carts" j with
              | Some (`List items) ->
                List.filter_map (function `String s -> Some s | _ -> None) items
              | _ -> []
            in
            check bool "both cartridges are listed" true
              (List.mem "dig-dug.rom" names && List.mem "pac-man.rom" names);
            check (option bool) "nothing is loaded yet" (Some false)
              (match member "loaded" j with Some (`Bool b) -> Some b | _ -> None))
        ] )
    ; ( "load_result_json"
      , [ test_case "ok and refusal carry the shape the TUI reads" `Quick (fun () ->
            let ok = Route.load_result_json ~ok:true ~message:"loaded xspelunker" in
            check (option bool) "ok is true" (Some true)
              (match member "ok" ok with Some (`Bool b) -> Some b | _ -> None);
            let bad = Route.load_result_json ~ok:false ~message:"unknown cartridge" in
            check (option bool) "a refusal is ok:false" (Some false)
              (match member "ok" bad with Some (`Bool b) -> Some b | _ -> None);
            check (option string) "and carries the message" (Some "unknown cartridge")
              (match member "message" bad with Some (`String m) -> Some m | _ -> None))
        ] )
    ; ( "tick"
      , [ test_case "retained pixels keep atomic advancement and fresh metadata" `Quick test_retained_tick
        ; test_case "invalid ticks never mutate and missing workers refuse" `Quick
            test_tick_validation_precedes_mutation
        ; test_case "accepted ticks advance once on the worker and return pixels" `Quick
            test_tick_worker_advances_and_returns_frame
        ] )
    ]
;;

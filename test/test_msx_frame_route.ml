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
        ; {|{"unexpected":18}|} ];
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

let () =
  run "msx frame route"
    [ ( "checkpoint", [test_case "validation, worker, restore and storage failure" `Quick test_checkpoint_route])
    ; ( "frame_json"
      , [ test_case "no machine is loaded:false" `Quick (fun () ->
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
                     ~hold_frames:2 ~step_frames:6 with
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
      , [ test_case "invalid ticks never mutate and missing workers refuse" `Quick
            test_tick_validation_precedes_mutation
        ; test_case "accepted ticks advance once on the worker and return pixels" `Quick
            test_tick_worker_advances_and_returns_frame
        ] )
    ]
;;

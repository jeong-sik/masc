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

let () =
  run "msx frame route"
    [ ( "frame_json"
      , [ test_case "no machine is loaded:false" `Quick (fun () ->
            ignore (Lane.eject () : (unit, Lane.error) result);
            let j = Route.frame_json () in
            check (option bool) "loaded is false" (Some false)
              (match member "loaded" j with Some (`Bool b) -> Some b | _ -> None);
            check bool "no pixels when unloaded" true (member "rgb_base64" j = None))
        ; test_case "a loaded machine yields a decodable frame" `Quick (fun () ->
            let dir = Filename.temp_dir "msx-frame-route-" "" in
            (match Lane.load ~ledger_dir:dir ~roms_dir:"" ~cart_path:None with
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
            (match Lane.load ~ledger_dir:dir ~roms_dir:"" ~cart_path:None with
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
      , [ test_case "a tick's frame count stays in 1..cap" `Quick (fun () ->
            check int "zero clamps up to one" 1 (Route.clamp_tick_frames 0);
            check int "the default passes through" Route.msx_tick_default_frames
              (Route.clamp_tick_frames Route.msx_tick_default_frames);
            check int "an overrun clamps to the cap" Lane.max_frames_per_call
              (Route.clamp_tick_frames (Lane.max_frames_per_call * 10)))
        ; test_case "a tick advances the machine by the clamped frames" `Quick
            (fun () ->
              let dir = Filename.temp_dir "msx-tick-route-" "" in
              (match Lane.load ~ledger_dir:dir ~roms_dir:"" ~cart_path:None with
               | Ok _ -> () | Error e -> fail (Lane.error_to_string e));
              let number () =
                match member "number" (Route.frame_json ()) with
                | Some (`Int n) -> n | _ -> -1
              in
              let before = number () in
              (match
                 Lane.step ~frames:(Route.clamp_tick_frames Route.msx_tick_default_frames)
               with
               | Ok _ -> () | Error e -> fail (Lane.error_to_string e));
              check int "the frame advanced by the tick size"
                Route.msx_tick_default_frames (number () - before);
              ignore (Lane.eject () : (unit, Lane.error) result))
        ] )
    ]
;;

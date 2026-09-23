(* The DOS frame route (#38424): no machine -> loaded:false; a loaded COM
   image -> its frame as base64 RGB of the size it says, with the controller
   and step count beside it; reading it any number of times never moves the
   machine's time; a spectator that names the frame it holds gets the
   metadata without the pixels. Drives the real Dos_lane. *)

open Alcotest
module Route = Server_routes_http_routes_dos

(* Prints HI and loops on INT 16h until a key arrives: a text-mode program
   that settles on its first request (the same image test_dos_vision boots). *)
let hello_com =
  "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"
;;

let loader = "dos-route-player"

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let int_member name json =
  match member name json with Some (`Int n) -> n | _ -> failf "missing int %s" name
;;

let string_member name json =
  match member name json with Some (`String s) -> s | _ -> failf "missing string %s" name
;;

(* The machine is process-global: eject as whoever holds it so one case does
   not hand its machine to the next. *)
let eject_held () =
  let who =
    match Dos_lane.screen () with
    | Ok { Dos_lane.controller = Some holder; _ } -> holder
    | Ok _ | Error _ -> loader
  in
  match Dos_lane.eject ~who ~announce:ignore () with
  | Ok () | Error Dos_lane.No_machine -> ()
  | Error e -> fail (Dos_lane.error_to_string e)
;;

let with_machine f =
  let dir = Filename.temp_dir "dos-frame-route-" "" in
  Fun.protect
    ~finally:(fun () ->
      eject_held ();
      Fs_compat.remove_tree dir)
    (fun () ->
      eject_held ();
      (match
         Dos_lane.load ~who:loader ~ledger_dir:(Filename.concat dir "ledger")
           ~saves_dir:(Filename.concat dir "saves") ~program_name:"HELLO.COM"
           ~program_bytes:hello_com ~files:[] ~announce:ignore
       with
       | Ok _ -> ()
       | Error e -> fail (Dos_lane.error_to_string e));
      f ())
;;

let steps_now () =
  match Dos_lane.screen () with
  | Ok o -> o.Dos_lane.steps
  | Error e -> fail (Dos_lane.error_to_string e)
;;

let test_no_machine_is_loaded_false () =
  eject_held ();
  let status, json = Route.frame_response ~incarnation:None ~steps:None () in
  check bool "a successful answer" true (status = `OK);
  check bool "says nothing is loaded" true (member "loaded" json = Some (`Bool false));
  check bool "and carries no pixels" true (member "rgb_base64" json = None)
;;

let test_a_loaded_com_image_is_served_without_moving_time () =
  with_machine (fun () ->
    let before = steps_now () in
    let status, json = Route.frame_response ~incarnation:None ~steps:None () in
    check bool "a successful answer" true (status = `OK);
    check bool "loaded" true (member "loaded" json = Some (`Bool true));
    let width = int_member "width" json and height = int_member "height" json in
    check bool "a frame with a size" true (width > 0 && height > 0);
    check string "inline pixels" "inline" (string_member "pixels" json);
    let rgb = Base64.decode_exn (string_member "rgb_base64" json) in
    check int "three bytes per pixel of the size it says" (width * height * 3)
      (String.length rgb);
    check string "the program it booted" "HELLO.COM" (string_member "program" json);
    check (option string) "the loader holds the controller" (Some loader)
      (match member "controller" json with Some (`String s) -> Some s | _ -> None);
    check int "the step count is the machine's" before (int_member "steps" json);
    check bool "the video mode is named" true
      (match member "video_mode" json with Some (`Int _) -> true | _ -> false);
    (* Spectating must not move time: DOS time moves only by tool calls. *)
    for _ = 1 to 5 do
      ignore (Route.frame_response ~incarnation:None ~steps:None ())
    done;
    check int "six reads later the machine has not advanced" before (steps_now ());
    check int "and the ledger holds no input" 0 (List.length (Dos_lane.ledger ())))
;;

let test_a_known_frame_is_answered_without_pixels () =
  with_machine (fun () ->
    let _, first = Route.frame_response ~incarnation:None ~steps:None () in
    let incarnation = string_member "incarnation" first in
    let steps = int_member "steps" first in
    let status, again =
      Route.frame_response ~incarnation:(Some incarnation)
        ~steps:(Some (string_of_int steps))
        ~capture:(fun () -> fail "an unchanged frame must not be rendered")
        ()
    in
    check bool "a successful answer" true (status = `OK);
    check string "the held frame is still current" "unchanged"
      (string_member "pixels" again);
    check bool "so no pixels travel" true (member "rgb_base64" again = None);
    check (option string) "the controller is still reported" (Some loader)
      (match member "controller" again with Some (`String s) -> Some s | _ -> None);
    (* Time moved by a tool call: the held frame is stale and the whole frame
       comes back. *)
    (match Dos_lane.step ~who:loader ~steps:1 ~until_ready:false with
     | Ok _ -> ()
     | Error e -> fail (Dos_lane.error_to_string e));
    let _, moved =
      Route.frame_response ~incarnation:(Some incarnation)
        ~steps:(Some (string_of_int steps))
        ()
    in
    check string "a moved machine sends its frame" "inline" (string_member "pixels" moved);
    check bool "with the step it reached" true (int_member "steps" moved > steps);
    (* Another machine at the same step count is another frame. *)
    let _, other =
      Route.frame_response ~incarnation:(Some "another-incarnation")
        ~steps:(Some (string_of_int (int_member "steps" moved)))
        ()
    in
    check string "another incarnation sends its frame" "inline"
      (string_member "pixels" other))
;;

let test_a_half_named_frame_is_refused () =
  List.iter
    (fun (label, incarnation, steps) ->
      let status, json = Route.frame_response ~incarnation ~steps () in
      check bool (label ^ ": 400") true (status = `Bad_request);
      check bool (label ^ ": says why") true
        (match member "message" json with Some (`String _) -> true | _ -> false))
    [ "incarnation alone", Some "x", None
    ; "steps alone", None, Some "3"
    ; "steps not a number", Some "x", Some "three"
    ; "negative steps", Some "x", Some "-1"
    ]
;;

let test_the_frame_is_public_read_like_the_msx_frame () =
  check bool "MSX frame is public read" true
    (Server_auth.is_public_read_path "/api/v1/msx/frame");
  check bool "DOS frame gets the same treatment" true
    (Server_auth.is_public_read_path "/api/v1/dos/frame")
;;

let () =
  run "dos frame route"
    [ ( "frame"
      , [ test_case "no machine is loaded:false" `Quick test_no_machine_is_loaded_false
        ; test_case "a loaded COM image is served without moving time" `Quick
            test_a_loaded_com_image_is_served_without_moving_time
        ; test_case "a known frame is answered without pixels" `Quick
            test_a_known_frame_is_answered_without_pixels
        ; test_case "a half-named frame is refused" `Quick
            test_a_half_named_frame_is_refused
        ; test_case "the frame is public read like the MSX frame" `Quick
            test_the_frame_is_public_read_like_the_msx_frame
        ] )
    ]
;;

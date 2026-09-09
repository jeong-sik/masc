(* The contract is what later panes (DOS, a VM console, a browser surface)
   will be written against, and what the focus model and the real-time
   ticker will hang off. So the cases pin the contract, not the MSX
   backend's looks: a frame fetched becomes pixels untouched, an escape
   hands focus back, a game key is pressed and consumed, a key the machine
   has no place for falls through to the host, and a refused press is not
   consumed — delivery failure must not eat the key. *)

open Alcotest

module Types = Masc_tui_types

let fake_frame () =
  Types.
    { msx_number = 42
    ; msx_width = 256
    ; msx_height = 192
    ; msx_rgb = String.make (256 * 192 * 3) '\128'
    ; msx_mode = "GRAPHIC1"
    ; msx_cartridge = Some "test.rom"
    ; msx_disk = None
    ; msx_players = []
    }
;;

let () =
  let pressed = ref [] in
  let deliver_ok key =
    pressed := !pressed @ [ key ];
    true
  in
  let module M = (val Masc_tui_interactive.msx ~fetch:(fun () -> Some (fake_frame ())) ~press:deliver_ok) in
  run "tui_interactive"
    [ ( "frame"
      , [ test_case "the fetched frame arrives as pixels, untouched" `Quick
            (fun () ->
              match M.current () with
              | Some (Masc_tui_interactive.Pixels { width; height; rgb }) ->
                check int "width" 256 width;
                check int "height" 192 height;
                check int "the buffer rides whole" (256 * 192 * 3)
                  (String.length rgb)
              | _ -> failf "expected pixels")
        ; test_case "no frame fetched means nothing to draw" `Quick (fun () ->
              let module N =
                (val
                  Masc_tui_interactive.msx
                    ~fetch:(fun () -> None)
                    ~press:(fun _ -> true))
              in
              check bool "current is None" true (Option.is_none (N.current ()))) ] )
    ; ( "input"
      , [ test_case "escape hands the key back and closes nothing itself" `Quick
            (fun () -> check bool "not consumed" false (M.handle_input "esc"))
        ; test_case "a machine key is pressed and consumed" `Quick (fun () ->
              check bool "consumed" true (M.handle_input "right");
              check bool "consumed" true (M.handle_input "space");
              check (list string) "both reached the machine" [ "right"; "space" ]
                !pressed)
        ; test_case "one printable character is a machine key" `Quick (fun () ->
              check bool "consumed" true (M.handle_input "1"))
        ; test_case "a host binding falls through unconsumed" `Quick (fun () ->
              check bool "not consumed" false (M.handle_input "ctrl-]"))
        ; test_case "a press the machine refuses is not consumed" `Quick
            (fun () ->
              let module R =
                (val
                  Masc_tui_interactive.msx
                    ~fetch:(fun () -> None)
                    ~press:(fun _ -> false))
              in
              check bool "refusal falls back to the host" false
                (R.handle_input "space")) ] )
    ]
;;

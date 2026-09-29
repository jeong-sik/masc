open Alcotest

let test_render_preserves_square_width () =
  let link = "https://play.example.test/play#fixture-secret" in
  match Masc_tui_play_qr.render ~available_cells:160 link with
  | Error _ -> fail "a short play link should fit"
  | Ok qr ->
      let lines = String.split_on_char '\n' qr in
      let widths =
        List.filter (fun line -> not (String.equal line "")) lines
        |> List.map Masc_tui_message_layout.display_width
      in
      (match widths with
       | [] -> fail "QR had no rows"
       | width :: rest ->
           check bool "every QR row keeps its square width" true
             (List.for_all (( = ) width) rest);
           check bool "QR fits the body" true (width <= 160);
           match Masc_tui_play_qr.render ~available_cells:(width - 1) link with
           | Error (Masc_tui_play_qr.Pane_too_narrow _) -> ()
           | Ok _ | Error Masc_tui_play_qr.Too_large ->
               fail "a narrow pane must refuse the QR")

let () =
  run "tui play QR"
    [ "layout", [ test_case "square rows or refusal" `Quick test_render_preserves_square_width ] ]

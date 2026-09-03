open Alcotest

module Preview = Masc_tui_image_preview
module Chat = Masc_tui_keeper_chat_projection

(* The chooser reads order and presence only, so the attachments here are
   shells: a name to recognise them by, the rest filler. *)
let attachment name =
  { Chat.attachment_id = "tui-att-" ^ name
  ; name
  ; mime_type = "image/png"
  ; size = 0
  ; data = ""
  }
;;

let test_a_named_path_wins_over_anything_staged () =
  match
    Preview.choose_preview ~named:(Some "evidence/shot.png")
      ~staged:[ attachment "image-1.png" ]
  with
  | Preview.Named_path path ->
    check string "the named path" "evidence/shot.png" path
  | _ -> fail "a named path must win over a staged attachment"
;;

let test_nothing_named_shows_the_newest_staged () =
  match
    Preview.choose_preview ~named:None
      ~staged:[ attachment "image-1.png"; attachment "image-2.png" ]
  with
  | Preview.Staged staged ->
    check string "the newest staged" "image-2.png" staged.Chat.name
  | _ -> fail "staged attachments with nothing named must show the newest"
;;

let test_neither_is_its_own_answer () =
  match Preview.choose_preview ~named:None ~staged:[] with
  | Preview.No_image -> ()
  | _ -> fail "nothing named and nothing staged is No_image"
;;

let () =
  run
    "tui_image_preview"
    [ ( "choose_preview"
      , [ test_case "a named path wins over anything staged" `Quick
            test_a_named_path_wins_over_anything_staged
        ; test_case "nothing named shows the newest staged" `Quick
            test_nothing_named_shows_the_newest_staged
        ; test_case "neither is its own answer" `Quick test_neither_is_its_own_answer
        ] )
    ]
;;

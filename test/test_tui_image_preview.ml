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

let test_a_named_path_wins_when_its_message_is_the_newer_one () =
  match
    Preview.choose_preview ~named:(Some "evidence/shot.png")
      ~staged:[ attachment "image-1.png" ] ~order:Preview.Named_is_newer
  with
  | Preview.Named_path path ->
    check string "the named path" "evidence/shot.png" path
  | _ -> fail "a path named after the staging must win"
;;

let test_a_staged_attachment_wins_when_it_is_the_newer_one () =
  match
    Preview.choose_preview ~named:(Some "evidence/shot.png")
      ~staged:[ attachment "image-1.png"; attachment "image-2.png" ]
      ~order:Preview.Staged_is_newer
  with
  | Preview.Staged staged ->
    check string "the newest staged" "image-2.png" staged.Chat.name
  | _ -> fail "an attachment staged after the naming message must win"
;;

let test_a_named_path_wins_when_recency_cannot_be_established () =
  match
    Preview.choose_preview ~named:(Some "evidence/shot.png")
      ~staged:[ attachment "image-1.png" ] ~order:Preview.Unordered
  with
  | Preview.Named_path path ->
    check string "the named path" "evidence/shot.png" path
  | _ -> fail "an unordered race keeps the answer the key gave before"
;;

let test_nothing_named_shows_the_newest_staged () =
  match
    Preview.choose_preview ~named:None
      ~staged:[ attachment "image-1.png"; attachment "image-2.png" ]
      ~order:Preview.Unordered
  with
  | Preview.Staged staged ->
    check string "the newest staged" "image-2.png" staged.Chat.name
  | _ -> fail "staged attachments with nothing named must show the newest"
;;

let test_nothing_staged_shows_the_named_path () =
  match
    Preview.choose_preview ~named:(Some "evidence/shot.png") ~staged:[]
      ~order:Preview.Unordered
  with
  | Preview.Named_path path ->
    check string "the named path" "evidence/shot.png" path
  | _ -> fail "a named path with nothing staged must be shown"
;;

let test_neither_is_its_own_answer () =
  match
    Preview.choose_preview ~named:None ~staged:[] ~order:Preview.Unordered
  with
  | Preview.No_image -> ()
  | _ -> fail "nothing named and nothing staged is No_image"
;;

let () =
  run
    "tui_image_preview"
    [ ( "choose_preview"
      , [ test_case "a named path wins when its message is the newer one" `Quick
            test_a_named_path_wins_when_its_message_is_the_newer_one
        ; test_case "a staged attachment wins when it is the newer one" `Quick
            test_a_staged_attachment_wins_when_it_is_the_newer_one
        ; test_case "a named path wins when recency cannot be established" `Quick
            test_a_named_path_wins_when_recency_cannot_be_established
        ; test_case "nothing named shows the newest staged" `Quick
            test_nothing_named_shows_the_newest_staged
        ; test_case "nothing staged shows the named path" `Quick
            test_nothing_staged_shows_the_named_path
        ; test_case "neither is its own answer" `Quick test_neither_is_its_own_answer
        ] )
    ]
;;

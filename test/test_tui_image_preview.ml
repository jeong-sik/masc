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
    Preview.choose_preview ~conversation:(Preview.Named_path "evidence/shot.png")
      ~staged:[ attachment "image-1.png" ] ~order:Preview.Named_is_newer
  with
  | Preview.Named_path path ->
    check string "the named path" "evidence/shot.png" path
  | _ -> fail "a path named after the staging must win"
;;

let test_a_staged_attachment_wins_when_it_is_the_newer_one () =
  match
    Preview.choose_preview ~conversation:(Preview.Named_path "evidence/shot.png")
      ~staged:[ attachment "image-1.png"; attachment "image-2.png" ]
      ~order:Preview.Staged_is_newer
  with
  | Preview.Staged staged ->
    check string "the newest staged" "image-2.png" staged.Chat.name
  | _ -> fail "an attachment staged after the naming message must win"
;;

let test_a_named_path_wins_when_recency_cannot_be_established () =
  match
    Preview.choose_preview ~conversation:(Preview.Named_path "evidence/shot.png")
      ~staged:[ attachment "image-1.png" ] ~order:Preview.Unordered
  with
  | Preview.Named_path path ->
    check string "the named path" "evidence/shot.png" path
  | _ -> fail "an unordered race keeps the answer the key gave before"
;;

let test_nothing_named_shows_the_newest_staged () =
  match
    Preview.choose_preview ~conversation:Preview.No_image
      ~staged:[ attachment "image-1.png"; attachment "image-2.png" ]
      ~order:Preview.Unordered
  with
  | Preview.Staged staged ->
    check string "the newest staged" "image-2.png" staged.Chat.name
  | _ -> fail "staged attachments with nothing named must show the newest"
;;

let test_nothing_staged_shows_the_named_path () =
  match
    Preview.choose_preview ~conversation:(Preview.Named_path "evidence/shot.png") ~staged:[]
      ~order:Preview.Unordered
  with
  | Preview.Named_path path ->
    check string "the named path" "evidence/shot.png" path
  | _ -> fail "a named path with nothing staged must be shown"
;;

let test_neither_is_its_own_answer () =
  match
    Preview.choose_preview ~conversation:Preview.No_image ~staged:[] ~order:Preview.Unordered
  with
  | Preview.No_image -> ()
  | _ -> fail "nothing named and nothing staged is No_image"
;;

let stored name =
  match Tool_output.make_artifact_ref ~sha256:(String.make 64 'a')
          ~bytes:4 ~mime:"text/plain" ~preview:"attachment payload" with
  | Error error -> fail (Tool_output.make_error_to_string error)
  | Ok reference ->
      Preview.persisted_attachment ~name ~mime:"image/png"
        ~data:(Some (Tool_output.encode_for_agent_core (Tool_output.Stored reference)))

let test_sent_image_keeps_reference_not_filename () =
  let image = Preview.in_message ~text:"look"
      ~attachments:[stored "../../wrong.png"] in
  match Preview.choose_preview ~conversation:image ~staged:[] ~order:Preview.Unordered with
  | Preview.Stored_attachment { name; reference } ->
      check string "name remains a label" "../../wrong.png" name;
      check string "only validated digest locates payload" (String.make 64 'a') reference.sha256
  | _ -> fail "sent image must keep its actual payload reference"

let test_missing_and_malformed_payloads_do_not_open_labels () =
  List.iter (fun data ->
    let image = Preview.persisted_attachment ~name:"image-1.png" ~mime:"image/png" ~data in
    match Preview.in_message ~text:"older.png" ~attachments:[image] with
    | Preview.Unavailable_attachment "image-1.png" -> ()
    | _ -> fail "unavailable sent image must not turn its label into a path")
    [None; Some "masc://attachment/att/hash"; Some "[masc:blob sha256=../../other]"]

let test_new_staging_and_new_paths_order_against_sent_images () =
  let sent = stored "sent.png" in
  (match Preview.choose_preview ~conversation:sent ~staged:[attachment "new.png"]
           ~order:Preview.Staged_is_newer with
   | Preview.Staged a -> check string "new paste wins" "new.png" a.Chat.name
   | _ -> fail "new staging must beat sent image");
  (match Preview.choose_preview ~conversation:sent ~staged:[attachment "old.png"]
           ~order:Preview.Named_is_newer with
   | Preview.Stored_attachment _ -> ()
   | _ -> fail "new sent image must beat old staging");
  match Preview.in_message ~text:"newer/path.png" ~attachments:[] with
  | Preview.Named_path "newer/path.png" -> ()
  | _ -> fail "later message paths remain previewable"

let test_retained_wire_payload_decode () =
  List.iter (fun payload ->
    check (result string string) "bare and data URI payloads decode"
      (Ok "PNG") (Preview.decode_payload payload))
    ["UE5H"; "data:image/png;base64,UE5H"];
  check bool "non-base64 data URI rejected" true
    (Result.is_error (Preview.decode_payload "data:image/png,UE5H"));
  check bool "invalid base64 rejected" true
    (Result.is_error (Preview.decode_payload "%%%%"))

let () =
  run
    "tui_image_preview"
    [ ( "choose_preview"
      , [ test_case "sent image uses durable reference, never its label" `Quick
            test_sent_image_keeps_reference_not_filename
        ; test_case "missing or malformed payload is unavailable" `Quick
            test_missing_and_malformed_payloads_do_not_open_labels
        ; test_case "sent images preserve staging and path order" `Quick
            test_new_staging_and_new_paths_order_against_sent_images
        ; test_case "retained wire payload decoding" `Quick test_retained_wire_payload_decode
        ; test_case "a named path wins when its message is the newer one" `Quick
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

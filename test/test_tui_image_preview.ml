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
  | Preview.Stored_attachment { name; reference; _ } ->
      check string "name remains a label" "../../wrong.png" name;
      check string "only validated digest locates payload" (String.make 64 'a') reference.sha256
  | _ -> fail "sent image must keep its actual payload reference"

let test_missing_and_malformed_payloads_do_not_open_labels () =
  List.iter (fun data ->
    let image = Preview.persisted_attachment ~name:"image-1.png" ~mime:"image/png" ~data in
    match Preview.in_message ~text:"older.png" ~attachments:[image] with
    | Preview.Unavailable_image { name = "image-1.png"; _ } -> ()
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

let artifact_reference content =
  let sha256 = Digestif.SHA256.(to_hex (digest_string content)) in
  match Tool_output.make_artifact_ref ~sha256 ~bytes:(String.length content)
          ~mime:"text/plain" ~preview:"attachment payload" with
  | Ok reference -> reference
  | Error error -> fail (Tool_output.make_error_to_string error)

let artifact_envelope (reference : Tool_output.artifact_ref) content =
  [ "sha256", `String reference.sha256
  ; "bytes", `Int reference.bytes
  ; "content", `String content
  ]

let test_artifact_checks_the_retained_wire_content () =
  List.iter (fun content ->
    let reference = artifact_reference content in
    check (result string string) "verified wire payload decodes to image bytes"
      (Ok "PNG")
      (Preview.decode_artifact reference (`Assoc (artifact_envelope reference content))))
    ["UE5H"; "data:image/png;base64,UE5H"]

let test_artifact_rejects_missing_or_wrongly_typed_envelope_fields () =
  let content = "UE5H" in
  let reference = artifact_reference content in
  let fields = artifact_envelope reference content in
  List.iter (fun field ->
    let without = List.remove_assoc field fields in
    List.iter (fun json ->
      check bool ("required field: " ^ field) true
        (Result.is_error (Preview.decode_artifact reference json)))
      [`Assoc without; `Assoc ((field, `Null) :: without)])
    ["sha256"; "bytes"; "content"];
  check bool "non-object response rejected" true
    (Result.is_error (Preview.decode_artifact reference (`String content)))

let test_artifact_rejects_substitution_or_corruption () =
  let content = "UE5H" in
  let reference = artifact_reference content in
  let fields = artifact_envelope reference content in
  let replace field value = `Assoc ((field, value) :: List.remove_assoc field fields) in
  List.iter (fun (label, json) ->
    check bool label true (Result.is_error (Preview.decode_artifact reference json)))
    [ "different artifact", replace "sha256" (`String (String.make 64 'a'))
    ; "recorded byte count differs", replace "bytes" (`Int (reference.bytes + 1))
    ; "content length differs", replace "content" (`String "UE5HUE5H")
    ; "same-length content was replaced", replace "content" (`String "SlBH")
    ];
  let longer_reference = artifact_reference "UE5HUE5H" in
  let forged_fields =
    ["sha256", `String longer_reference.sha256; "bytes", `Int 4; "content", `String content]
  in
  check bool "internally consistent envelope must also match recorded bytes" true
    (Result.is_error (Preview.decode_artifact longer_reference (`Assoc forged_fields)))

let test_diagram_preview_selection () =
  let source = "pie\n  \"완료\": 8\n  \"대기\": 2" in
  let text = "```mermaid\nflowchart TD\n A --> B\n```\n~~~mermaid\n"
    ^ source ^ "\n~~~\n```mermaid\nunfinished" in
  let preview = Preview.in_message ~text ~attachments:[] in
  (match preview with
   | Preview.Output_image { source = Preview.Inline_mermaid actual; _ } ->
       check string "last completed source selected without parsing" source actual
   | _ -> fail "closed chart was not offered to Pele");
  (match Preview.in_message ~text ~attachments:[Preview.Named_path "capture.png"] with
   | Preview.Named_path "capture.png" -> ()
   | _ -> fail "diagram displaced an explicit attachment");
  (match Preview.choose_preview ~conversation:preview ~staged:[attachment "draft.png"]
      ~order:Preview.Staged_is_newer with
   | Preview.Staged _ -> ()
   | _ -> fail "diagram displaced a newer staged draft");
  match Preview.in_message ~text:"```mermaid\npie\n" ~attachments:[] with
  | Preview.No_image -> ()
  | _ -> fail "incomplete stream was sent to the renderer"

let test_all_visual_sources_remain_selectable () =
  let first = "flowchart TD\n\tA[한글] --> B" in
  let second = "pie\n  \"대기\": 2" in
  let text = "shot1.png shot2.png\n```mermaid\n" ^ first
    ^ "\n```\n~~~mermaid\n" ^ second ^ "\n~~~\n```mermaid\nincomplete" in
  let supplied = [stored "retained.png"; Preview.mermaid ~name:"caption" second] in
  let catalog = Preview.in_message_previews ~text ~attachments:supplied in
  match catalog with
  | [Preview.Named_path "shot1.png"; Named_path "shot2.png";
     Output_image {source=Inline_mermaid one;_}; Stored_attachment _;
     Output_image {name="caption";source=Inline_mermaid two}] ->
      check string "earlier diagram keeps original tabs and unicode" first one;
      check string "structured and prose copies name one diagram" second two
  | _ -> fail "a visual source was dropped, duplicated or replaced by an unfinished fence"

let test_catalog_preserves_explicit_preview_priority () =
  let conversation = [Preview.Named_path "first.png"; stored "retained.png"] in
  let staged = [attachment "draft1.png";attachment "draft2.png"] in
  List.iter (fun order ->
    let catalog = Preview.newest_first ~conversation ~staged ~order in
    check int "both conversation and staged sources are selectable" 4 (List.length catalog);
    let selected = Preview.choose_preview ~conversation:(Preview.newest conversation) ~staged ~order in
    check bool "number one matches Ctrl-O's explicit priority" true
      (List.hd catalog = selected))
    [Preview.Named_is_newer; Staged_is_newer; Unordered];
  let unavailable = Preview.Unavailable_image {name="missing.png";reason="not retained"} in
  match Preview.newest_first ~conversation:[List.hd conversation;unavailable;Preview.No_image]
      ~staged:[] ~order:Preview.Unordered with
  | [Unavailable_image _; Named_path "first.png"] -> ()
  | _ -> fail "unavailable producer source must retain its selection identity"

let test_current_source_beats_an_older_queued_suffix () =
  let old = Preview.Named_path "queued-before-staging.png" in
  let current = Preview.mermaid ~name:"live" "flowchart TD\n A --> B" in
  let sources,order = Preview.prioritize_sources
      ~newly_observed:(String.equal "current-turn")
      ["current-turn",[current];"old-queued",[old]] in
  let catalog = Preview.newest_first ~conversation:(List.concat_map snd sources)
      ~staged:[attachment "draft.png"] ~order in
  check bool "current source selected ahead of staged and earlier queued sources" true
    (List.hd catalog = current);
  check int "every occurrence remains selectable" 3 (List.length catalog);
  let sources,order = Preview.prioritize_sources
      ~newly_observed:(String.equal "current-turn")
      ["current-turn",[];"old-queued",[old]] in
  match Preview.newest_first ~conversation:(List.concat_map snd sources)
      ~staged:[attachment "draft.png"] ~order with
  | Preview.Staged _ :: _ -> ()
  | _ -> fail "an unfinished current source displaced a staged attachment"

let () =
  run
    "tui_image_preview"
    [ ( "choose_preview"
      , [ test_case "every original visual source remains selectable" `Quick
            test_all_visual_sources_remain_selectable
        ; test_case "new live source beats an earlier queued suffix" `Quick
            test_current_source_beats_an_older_queued_suffix
        ; test_case "catalog preserves explicit preview priority" `Quick
            test_catalog_preserves_explicit_preview_priority
        ; test_case "closed diagrams preserve source and draft priority" `Quick
            test_diagram_preview_selection
        ; test_case "sent image uses durable reference, never its label" `Quick
            test_sent_image_keeps_reference_not_filename
        ; test_case "missing or malformed payload is unavailable" `Quick
            test_missing_and_malformed_payloads_do_not_open_labels
        ; test_case "sent images preserve staging and path order" `Quick
            test_new_staging_and_new_paths_order_against_sent_images
        ; test_case "artifact validates wire bytes before base64 decoding" `Quick
            test_artifact_checks_the_retained_wire_content
        ; test_case "artifact requires typed envelope fields" `Quick
            test_artifact_rejects_missing_or_wrongly_typed_envelope_fields
        ; test_case "artifact rejects substitution and corruption" `Quick
            test_artifact_rejects_substitution_or_corruption
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

module Picture = Masc_tui_evidence_picture
module Message_layout = Masc_tui_message_layout
module Keeper_chat = Masc_tui_keeper_chat_projection
module Failure = Masc_tui_types.Verification_evidence_read
module Ansi = Masc_tui_ansi.Ansi
module Terminal_text = Masc_tui_ansi.Terminal_text

(* Complete judgement metadata is a physical document. Rows that fit keep
   their field alignment; longer rows remain literal and reachable by scroll. *)
let wrap_rows ~width lines =
  List.concat_map
    (fun (style, text) ->
       if Message_layout.display_width text <= width then [style, text]
       else Message_layout.wrap_words ~max_cells:(max 1 width) text
            |> List.map (fun row -> style, row)) lines

let section ~evidence ~task_id ~width ~content_height ~display =
  let wrap ~prefix text =
    Message_layout.wrap_body ~max_cells:(max 1 (width - 6))
      ~sanitize:Keeper_chat.terminal_safe_text text
    |> List.mapi (fun index line ->
           Ansi.reset, (if index = 0 then prefix else "      ") ^ line)
  in
  (* The links an item carries, one row each under it. Printed as text: an
     OSC 8 hyperlink would be counted as printable cells by the wrap and
     truncation code, which treats only CSI as zero-width. *)
  let link_rows item =
    Masc_tui_evidence_link.of_item item
    |> List.concat_map (fun link ->
           wrap ~prefix:"      link: " (Masc_tui_evidence_link.text link))
  in
  let text_item_rows (item : Masc.Tui_decode.verification_evidence_item) =
    (match item with
     | Masc.Tui_decode.Ev_collaboration {ev_reference; ev_content; ev_sha256} ->
         ((Ansi.reset, Printf.sprintf "    - submitted source %s (sha256 %s)"
             (Terminal_text.single_line ev_reference) ev_sha256)
          :: wrap ~prefix:"      " ev_content)
     | Masc.Tui_decode.Ev_note note -> wrap ~prefix:"    - note: " note
     | Masc.Tui_decode.Ev_artifact
         { ev_reference; ev_content; ev_bytes; ev_truncated } ->
         (( Ansi.reset
          , Printf.sprintf "    - artifact %s (%dB%s)"
              (Terminal_text.single_line ev_reference) ev_bytes
              (if ev_truncated then ", truncated" else "") )
          :: wrap ~prefix:"      " ev_content)
     | Masc.Tui_decode.Ev_binary
         { ev_b_reference; ev_b_bytes; ev_b_sha256; ev_b_format; ev_b_preview } ->
         (* Not prepared: only a bundle that skipped the loader reaches this. *)
         wrap ~prefix:"    - "
           (Picture.caption_of_preview ~reference:ev_b_reference ~bytes:ev_b_bytes
              ~sha256:ev_b_sha256 ~format:ev_b_format ev_b_preview)
     | Masc.Tui_decode.Ev_artifact_unreadable { ev_u_reference; ev_u_reason } ->
         wrap
           ~prefix:"    - artifact unreadable: "
           (Printf.sprintf "%s %s"
              (Option.value ev_u_reference ~default:"(no reference)")
              ev_u_reason))
    @ link_rows item
  in
  let binary_item_rows ~reference ~bytes ~sha256 ~format picture =
    let caption =
      wrap ~prefix:"    - " (Picture.caption ~reference ~bytes ~sha256 ~format picture)
      |> wrap_rows ~width
    in
    match
      Picture.block display picture ~width ~caption_rows:(List.length caption)
        ~content_height
    with
    | Picture.Caption_only -> caption, None
    | Picture.Picture box -> (
        match picture with
        | Picture.Drawable pixels ->
            ( caption @ List.init box.rows (fun _ -> Ansi.reset, "")
            , Some ({ Picture.first = List.length caption; box }, pixels) )
        | Picture.Binary_only | Picture.Unshown _ -> caption, None)
  in
  let message rows = wrap_rows ~width rows, [] in
  let rows, pictures =
    match evidence with
    | Some (id, result) when String.equal id task_id -> (
        match result with
        | Ok (Picture.Items []) -> message [ Ansi.dim, "    (no inspectable evidence)" ]
        | Ok (Picture.Items items) ->
            let _offset, rev_rows, rev_pictures =
              List.fold_left
                (fun (offset, rev_rows, rev_pictures) item ->
                   let item_rows, picture =
                     match item with
                     | Picture.Text_item text ->
                         wrap_rows ~width (text_item_rows text), None
                     | Picture.Binary_item { reference; bytes; sha256; format; picture } ->
                         binary_item_rows ~reference ~bytes ~sha256 ~format picture
                   in
                   let rev_pictures =
                     match picture with
                     | Some (slot, pixels) ->
                         ({ slot with Picture.first = offset + slot.Picture.first }, pixels)
                         :: rev_pictures
                     | None -> rev_pictures
                   in
                   ( offset + List.length item_rows
                   , List.rev_append item_rows rev_rows
                   , rev_pictures ))
                (0, [], []) items
            in
            List.rev rev_rows, List.rev rev_pictures
        | Ok (Picture.Access_unavailable reason) ->
            (* The producer's reason is already the evidence access verdict. *)
            message (wrap ~prefix:"    " reason)
        | Error (Failure.Transport detail) ->
            (* The transport boundary already says "GET failed". *)
            message (wrap ~prefix:"    " detail)
        | Error (Failure.Http_error detail) -> message (wrap ~prefix:"    Read failed: " detail)
        | Error (Failure.Invalid_json detail) -> message (wrap ~prefix:"    Invalid JSON: " detail)
        | Error (Failure.Invalid_payload detail) ->
            message (wrap ~prefix:"    Decode failed: " detail)
        | Error (Failure.Launch_failure detail) -> message (wrap ~prefix:"    Read failed: " detail))
    | Some _ | None -> message [ Ansi.dim, "    loading..." ]
  in
  let heading = wrap_rows ~width [ (Ansi.dim, ""); (Ansi.bold, "  EVIDENCE CONTENT") ] in
  let heading_rows = List.length heading in
  ( heading @ rows
  , List.map
      (fun ((slot : Picture.slot), pixels) ->
         { slot with first = heading_rows + slot.first }, pixels)
      pictures )

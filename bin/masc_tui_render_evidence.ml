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

let section ~evidence ~in_flight ~workspace_confirmed ~width ~content_height ~display =
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
        | Picture.Undrawn_image _ | Picture.Binary_only | Picture.Unshown _ -> caption, None)
  in
  let message rows = wrap_rows ~width rows, [] in
  let failure_rows = function
    | Failure.Transport detail -> wrap ~prefix:"    " detail
    | Http_error detail -> wrap ~prefix:"    Read failed: " detail
    | Invalid_json detail -> wrap ~prefix:"    Invalid JSON: " detail
    | Invalid_payload detail -> wrap ~prefix:"    Decode failed: " detail
    | Launch_failure detail -> wrap ~prefix:"    Read did not complete: " detail
    | Workspace_unconfirmed detail -> wrap ~prefix:"    Workspace unconfirmed: " detail
    | Interrupted detail -> wrap ~prefix:"    Read interrupted: " detail in
  let contents = function
        | Picture.Items [] -> message [ Ansi.dim, "    (no inspectable evidence)" ]
        | Picture.Items items ->
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
        | Picture.Access_unavailable reason ->
            (* The producer's reason is already the evidence access verdict. *)
            message (wrap ~prefix:"    " reason)
  in
  let rows, pictures = match evidence with
    | Masc_tui_fetched.Absent -> message (wrap ~prefix:"    "
        (if workspace_confirmed then "Evidence not read; press r to refresh."
         else "Workspace identity unconfirmed; evidence not read."))
    | Loading -> message (wrap ~prefix:"    "
        (if workspace_confirmed then "Reading the original verification evidence…"
         else "Workspace unconfirmed; the evidence read is unconfirmed."))
    | Failed failure -> message
        ((if in_flight then wrap ~prefix:"    " "Retrying evidence read…" else []) @ failure_rows failure)
    | Ready evidence ->
      let rows,pictures = contents evidence in
      let notes = if not workspace_confirmed then
        wrap ~prefix:"    " "Workspace unconfirmed; showing the last observed evidence."
        else if in_flight then wrap ~prefix:"    " "Refreshing; showing the previous evidence." else [] in
      let notes = wrap_rows ~width notes in
      notes @ rows,List.map (fun ((slot : Picture.slot),pixels) ->
        {slot with first=List.length notes+slot.first},pixels) pictures
    | Stale (evidence,failure) ->
      let rows,pictures = contents evidence in
      let notes = wrap_rows ~width
        (wrap ~prefix:"    " (if in_flight then "Retrying; showing the previous evidence."
          else "Showing the last observed evidence.") @ failure_rows failure) in
      notes @ rows,List.map (fun ((slot : Picture.slot),pixels) ->
        {slot with first=List.length notes+slot.first},pixels) pictures
  in
  let heading = wrap_rows ~width [ (Ansi.dim, ""); (Ansi.bold, "  EVIDENCE CONTENT") ] in
  let heading_rows = List.length heading in
  ( heading @ rows
  , List.map
      (fun ((slot : Picture.slot), pixels) ->
         { slot with first = heading_rows + slot.first }, pixels)
      pictures )

type request =
  | Show of Masc_tui_portrait_view.png_placement
  | Hold of { image_id : int; key : string }

(* What the frame asks the terminal for each picture of the section. A picture
   with a row in the window is shown cropped to those rows; one wholly
   outside it is held, so its pixels stay with the terminal and scrolling
   back is a placement, not a transfer. *)
let requests ~pictures ~evidence_first ~scroll ~content_height ~content_origin =
  List.map
    (fun ((slot : Picture.slot), (pixels : Picture.pixels)) ->
       match
         Picture.plan { slot with first = evidence_first + slot.first } ~scroll
           ~content_height ~content_origin
       with
       | Picture.Place { row; column; cut_top; shown_rows } ->
           Show (Picture.png_placement pixels slot.box ~row ~column ~cut_top ~shown_rows)
       | Picture.Hidden ->
           Hold { image_id = Masc_tui_graphics.image_id pixels.slot; key = pixels.key })
    pictures

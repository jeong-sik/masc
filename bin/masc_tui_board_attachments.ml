(** The read pane's one-line label for a board post's attachment.

    Kind naming and the label's shape live here and nowhere else: the
    renderer prints what {!label} returns. The label follows
    {!Masc_tui_chat_media}'s "File · name · src" one-line convention -- the
    kind's word, then the name or a stand-in for it, then a stored file's
    size. *)

open Masc_tui_types

(* Enough of the digest to tell two artifacts apart by eye -- the length
   [masc_tui_execute_result] shows for one -- with an ellipsis so a prefix
   does not read as the whole digest. *)
let short_sha256_bytes = 12

let short_sha256 sha256 =
  if String.length sha256 <= short_sha256_bytes then sha256
  else String_util.utf8_prefix ~max_bytes:short_sha256_bytes sha256 ^ "\xe2\x80\xa6"
;;

let join = String.concat " \xc2\xb7 "

let label (entry : board_attachment_entry) =
  match entry with
  | Error reason -> join [ "깨진 첨부"; reason ]
  | Ok attachment ->
      (* A link's url is its substance, so it stays in the label beside the
         name; an artifact's digest is what the store keys on, not something
         a reader acts on, so it yields to the name and only stands in when
         there is none. *)
      let name =
        match attachment.ba_name with
        | Some name when not (String.equal name "") -> Some name
        | Some _ | None -> None
      in
      let segments =
        match attachment.ba_source, name with
        | As_url url, Some name -> [ name; url ]
        | As_url url, None -> [ url ]
        | As_artifact { bytes; _ }, Some name ->
            [ name; Masc_tui_context_inspector.format_bytes bytes ]
        | As_artifact { sha256; bytes }, None ->
            [ short_sha256 sha256; Masc_tui_context_inspector.format_bytes bytes ]
      in
      let labelled word = join (word :: segments) in
      (match attachment.ba_kind with
       | Ak_image -> labelled "Image"
       | Ak_video -> labelled "Video"
       | Ak_audio -> labelled "Audio"
       | Ak_score -> labelled "Score"
       | Ak_midi -> labelled "MIDI"
       | Ak_file -> labelled "File"
       | Ak_youtube -> labelled "YouTube"
       | Ak_external_link -> labelled "Link"
       (* The wire's own word for the kind, and still the name and where it
          is: two entries of a kind this build does not know are not the
          same line. *)
       | Ak_unknown kind -> labelled ("미지원 kind: " ^ kind))
;;

(* The open key's resolution: the number a reader sees is 1-based and counts
   every entry, a broken one included, so [attachment_at_index entries n]
   is the entry the [n] on the pane names. *)
let attachment_at_index (entries : board_attachment_entry list) nth =
  if nth < 1 then None else List.nth_opt entries (nth - 1)
;;

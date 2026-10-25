type t =
  | Web_url of string
  | Masc_reference of { kind : Masc_tui_link.kind; id : string }

(* ASCII sentence punctuation that follows an address in prose. The scanner
   does not stop at it, so "see https://x.y/z." hands over the full stop. *)
let is_sentence_punctuation = function
  | '.' | ',' | ';' | ':' | '!' | '?' -> true
  | _ -> false

let rec without_trailing_punctuation url =
  let length = String.length url in
  if length > 0 && is_sentence_punctuation url.[length - 1]
  then without_trailing_punctuation (String.sub url 0 (length - 1))
  else url

(* A scanned run is an address only with a host: "http://" alone, or
   "https://." after the punctuation is cut, names nothing. *)
let web_url_of_candidate candidate =
  let url = without_trailing_punctuation candidate in
  match Uri.host (Uri.of_string url) with
  | Some host when String.length host > 0 -> Some (Web_url url)
  | Some _ | None -> None

(* Where an address that starts at [start] stops. The shared scanner of the
   chat pane stops at whitespace, quotes and brackets; this one also stops at
   the first non-ASCII byte, because an address is ASCII and the text around
   one here is often Korean ("https://x.example/d를 참고" is not a link to a
   path ending in "를"), and it keeps a parenthesis that closes one opened
   inside the address ("Foo_(bar)") while a closing one with nothing to close
   ends it ("(see https://x.example/a)"). *)
let first_non_ascii_byte = 0x7f

let address_end text start =
  let length = String.length text in
  let rec go index open_parens =
    if index >= length then index
    else
      match text.[index] with
      | '(' -> go (index + 1) (open_parens + 1)
      | ')' -> if open_parens > 0 then go (index + 1) (open_parens - 1) else index
      | ch ->
          if Masc_tui_message_layout.url_ends_at ch || Char.code ch >= first_non_ascii_byte
          then index
          else go (index + 1) open_parens
  in
  go start 0

let bare_addresses text =
  let length = String.length text in
  let rec loop index found =
    if index >= length then List.rev found
    else if Masc_tui_message_layout.url_begins_at text index then
      let stop = address_end text index in
      loop stop (String.sub text index (stop - index) :: found)
    else loop (index + 1) found
  in
  loop 0 []

let web_urls text = bare_addresses text |> List.filter_map web_url_of_candidate

(* Every string a JSON document holds, so a URL is read from the text the
   author wrote and not from the document's escaped form, where a line break
   after it would be the two characters backslash and n. *)
let rec json_strings = function
  | `String text -> [ text ]
  | `Assoc fields -> List.concat_map (fun (_, value) -> json_strings value) fields
  | `List values -> List.concat_map json_strings values
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ -> []

let source_urls content =
  match Yojson.Safe.from_string content with
  | json -> List.concat_map web_urls (json_strings json)
  | exception Yojson.Json_error _ -> web_urls content

let masc_reference_of_source reference =
  match Workspace_verification_store.collaboration_reference reference with
  | Some (Workspace_verification_store.Board_source, id) ->
      [ Masc_reference { kind = Masc_tui_link.Board_post; id } ]
  | Some (Workspace_verification_store.Fusion_source, id) ->
      [ Masc_reference { kind = Masc_tui_link.Fusion_run; id } ]
  | Some (Workspace_verification_store.Task_source, id) ->
      [ Masc_reference { kind = Masc_tui_link.Task; id } ]
  | None -> []

let without_repeats links =
  List.fold_left
    (fun seen link -> if List.mem link seen then seen else link :: seen)
    [] links
  |> List.rev

let of_item (item : Masc.Tui_decode.verification_evidence_item) =
  without_repeats
    (match item with
     | Masc.Tui_decode.Ev_collaboration { ev_reference; ev_content; _ } ->
         masc_reference_of_source ev_reference @ source_urls ev_content
     | Masc.Tui_decode.Ev_note note -> web_urls note
     | Masc.Tui_decode.Ev_artifact { ev_content; _ } -> web_urls ev_content
     | Masc.Tui_decode.Ev_artifact_unreadable _ | Masc.Tui_decode.Ev_binary _ -> [])

let text = function
  | Web_url url -> url
  | Masc_reference { kind; id } -> Masc_tui_link.reference kind id

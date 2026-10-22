(** See [lsp_uri.mli]. *)

let path_of_file_uri uri =
  let parsed = Uri.of_string uri in
  (* RFC 3986 section 3.1: schemes compare case-insensitively. *)
  match Option.map String.lowercase_ascii (Uri.scheme parsed) with
  | Some "file" ->
    (match Uri.host parsed with
     | None | Some "" | Some "localhost" -> Uri.path parsed |> Uri.pct_decode
     | Some _ -> uri)
  | _ -> uri
;;

let file_uri_of_path path =
  (* [Uri.make] takes an encoded path; protect literal percent sequences before
     its parser decodes each segment. Keep directory separators unchanged. *)
  let path =
    String.split_on_char '/' path
    |> List.map Uri.pct_encode
    |> String.concat "/"
  in
  Uri.make ~scheme:"file" ~host:"" ~path () |> Uri.to_string
;;

let local_document_path raw =
  let uri = Uri.of_string raw in
  match Option.map String.lowercase_ascii (Uri.scheme uri),
        Option.map String.lowercase_ascii (Uri.host uri),
        Uri.userinfo uri, Uri.port uri, Uri.verbatim_query uri, Uri.fragment uri with
  | Some "file", (None | Some "" | Some "localhost"), None, None, None, None ->
    let path = Uri.path uri |> Uri.pct_decode in
    if String.length path > 0 && Char.equal path.[0] '/' then Some path else None
  | _ -> None
;;

let same_local_document left right =
  match local_document_path left, local_document_path right with
  | Some left, Some right -> String.equal left right
  | (Some _ | None), (Some _ | None) -> false
;;

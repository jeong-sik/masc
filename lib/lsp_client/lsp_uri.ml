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
  Uri.make ~scheme:"file" ~path () |> Uri.to_string
;;

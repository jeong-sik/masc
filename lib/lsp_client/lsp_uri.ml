(** See [lsp_uri.mli]. *)

let path_of_file_uri uri =
  let parsed = Uri.of_string uri in
  match Uri.scheme parsed with
  | Some "file" ->
    (match Uri.host parsed with
     | None | Some "" | Some "localhost" -> Uri.path parsed |> Uri.pct_decode
     | Some _ -> uri)
  | _ -> uri
;;

let file_uri_of_path path = Uri.make ~scheme:"file" ~path () |> Uri.to_string

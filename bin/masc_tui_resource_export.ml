module Catalog = Masc_tui_resource_catalog
type t = { report : Catalog.report; source : string }

let create ~report ~source =
  let body = report.Catalog.revision.body in
  if String.length source <> body.bytes
     || not (String.equal Digestif.SHA256.(to_hex (digest_string source)) body.sha256)
  then Error "The retained source does not match this report revision"
  else Ok { report; source }

let label t = Printf.sprintf "%s v%d" t.report.id t.report.revision.revision
let suggested_name t =
  label t ^ (match t.report.revision.format with
    | Masc.Published_artifact.Markdown -> ".md" | Html -> ".html")
let same left right =
  Catalog.equal_key (Catalog.Report_revision left.report) (Catalog.Report_revision right.report)
  && String.equal left.source right.source

let dashboard_url ~host ~port t =
  Uri.to_string (Uri.make ~scheme:"http" ~host ~port ())
  ^ Masc.Published_artifact.url ~revision:t.report.revision.revision t.report.id

let path_input path =
  if not (String.is_valid_utf_8 path) then Error "The destination must be valid UTF-8"
  else if String.exists (function '\000'..'\031' | '\127' -> true | _ -> false) path then
    Error "The destination contains control characters; paste one file path"
  else Ok path

let save ~fs ~path t =
  let ( let* ) = Result.bind in
  let* path = path_input path in
  if String.equal path "" then Error "Enter a destination file path"
  else
    try
      Eio.Path.with_open_dir Eio.Path.(fs / Filename.dirname path) (fun parent ->
        Fs_compat.create_capability_file_exclusive ~parent ~leaf:(Filename.basename path)
          ~permissions:0o600 t.source)
      |> Result.map_error Fs_compat.capability_write_error_to_string
      |> Result.map (fun () -> Printf.sprintf "Saved %s · %d bytes · sha256 %s · %s"
        (label t) (String.length t.source) t.report.revision.body.sha256 path)
    with
    | Eio.Io _ as ex -> Error (Format.asprintf "%a" Eio.Exn.pp ex)
    | Sys_error detail -> Error detail
    | Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)

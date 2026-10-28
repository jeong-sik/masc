module Catalog = Masc_tui_resource_catalog
type t = { report : Catalog.report; source : string }

let create ~report ~source =
  let body = report.Catalog.revision.body in
  if String.length source <> body.bytes
     || not (String.equal Agent_core_sha256.(to_hex (digest_string source)) body.sha256)
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

let external_host host =
  let host = if String.ends_with ~suffix:"." host
    then String.sub host 0 (String.length host - 1) else host in
  let noncanonical_numeric = match List.rev (String.split_on_char '.' host) with
    | last :: _ when
        (last <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) last)
        || (String.length last >= 2 && Char.equal last.[0] '0'
            && (Char.equal last.[1] 'x' || Char.equal last.[1] 'X')
            && String.for_all (function '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false)
                 (String.sub last 2 (String.length last - 2))) ->
        Result.is_error (Ipaddr.of_string host)
    | _ :: _ | [] -> false in
  not (Masc_network_defaults.is_loopback_host host
       || Masc_network_defaults.is_unspecified_host host || noncanonical_numeric)

let public_url ~base_url ~(report : Catalog.report) =
  match base_url with
  | None -> Error "Set MASC_HTTP_BASE_URL to the reachable Dashboard origin"
  | Some base ->
    let base = Masc_network_defaults.trim_trailing_slashes (String.trim base) in
    if not (Masc.Play_invite.is_http_public_base_url base) then
      Error "MASC_HTTP_BASE_URL must be an HTTP(S) origin without credentials or a path"
    else
      match Uri.host (Uri.of_string base) with
      | Some host when external_host host ->
        Ok (base ^ Masc.Published_artifact.url ~revision:report.revision.revision report.id)
      | Some _ | None ->
        Error "MASC_HTTP_BASE_URL names a local, wildcard or noncanonical numeric host"

let path_input path =
  if not (String.is_valid_utf_8 path) then Error "The destination must be valid UTF-8"
  else if String.exists (function '\000'..'\031' | '\127' -> true | _ -> false) path then
    Error "The destination contains control characters; paste one file path"
  else Ok path

let save ~fs ~path t =
  let open Result.Syntax in
  let* path = path_input path in
  if String.equal path "" then Error "Enter a destination file path"
  else
    try
      Fs_compat.create_file_exclusive ~fs ~owner:"tui-report-export"
        ~path ~permissions:0o600 t.source
      |> Result.map (fun () -> Printf.sprintf "Saved %s · %d bytes · sha256 %s · %s"
        (label t) (String.length t.source) t.report.revision.body.sha256 path)
    with
    | Eio.Io _ as ex -> Error (Format.asprintf "%a" Eio.Exn.pp ex)
    | Sys_error detail -> Error detail
    | Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)

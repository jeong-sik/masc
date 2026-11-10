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
let key t = Catalog.Report_revision t.report
let matches_key t requested = Catalog.equal_key (key t) requested

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

type save_error =
  | Invalid_destination of string
  | Create_failed of Fs_compat.create_file_error

let error_target_effect = function
  | Invalid_destination _ -> Some Fs_compat.Target_unchanged
  | Create_failed error -> Fs_compat.create_file_error_target_effect error

let publication_refused_existing_target (error : Fs_compat.capability_write_error) =
  error.target_effect = Fs_compat.Target_unchanged
  && match error.primary_failure with
     | Fs_compat.Write_primary_failure failure ->
       (match failure.cause with
        | Fs_compat.Target_already_exists -> true
        | Fs_compat.Invalid_recovery_target _ | Fs_compat.Mutation_contended
        | Fs_compat.Posix_descriptor_unavailable | Fs_compat.Unexpected_resource_kind _
        | Fs_compat.Resource_identity_unavailable | Fs_compat.Resource_identity_changed
        | Fs_compat.Payload_write_failed _ | Fs_compat.Operation_failed _ -> false)
     | Fs_compat.Recovery_primary_failure _ | Fs_compat.Recovery_access_primary_failure _ -> false

let failure_refused_existing_target = function
  | Fs_compat.Target_rejected _ | Fs_compat.Registry_failed _ | Fs_compat.Lane_failed _ -> false
  | Fs_compat.Publication_failed error -> publication_refused_existing_target error
  | Fs_compat.Lane_release_failed { value = Ok (); _ } -> false
  | Fs_compat.Lane_release_failed { value = Error error; _ } ->
      publication_refused_existing_target error

let refused_existing_target = function
  | Invalid_destination _ -> false
  | Create_failed (Fs_compat.Create_failed failure) -> failure_refused_existing_target failure
  | Create_failed (Fs_compat.Boundary_failed { observed = Some (Error failure); _ }) ->
      failure_refused_existing_target failure
  | Create_failed (Fs_compat.Boundary_failed { observed = None | Some (Ok ()); _ }) -> false

let error_to_string = function
  | Invalid_destination detail -> detail
  | Create_failed error -> Fs_compat.create_file_error_to_string error

type cancellation = Fs_compat.create_file_cancellation
let cancellation = Fs_compat.create_file_cancellation
let cancellation_effect = Fs_compat.create_file_cancellation_effect
let cancellation_to_string = Fs_compat.create_file_cancellation_to_string

let save ~fs ~path t =
  let open Result.Syntax in
  let* path = path_input path |> Result.map_error (fun detail -> Invalid_destination detail) in
  if String.equal path "" then Error (Invalid_destination "Enter a destination file path")
  else
    Fs_compat.create_file_exclusive ~fs ~owner:"tui-report-export"
      ~path ~permissions:0o600 t.source
    |> Result.map_error (fun error -> Create_failed error)

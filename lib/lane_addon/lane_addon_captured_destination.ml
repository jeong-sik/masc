type t = {
  installation_id : string;
  package_id : string;
  tool : string;
  source_revision : string;
  configuration_revision : string;
}

let ( let* ) = Result.bind

let of_runtime (value : Lane_addon_runtime.tool_request_destination) =
  {
    installation_id = value.installation_id;
    package_id = value.package_id;
    tool = value.tool;
    source_revision = value.source_revision;
    configuration_revision = value.configuration_revision;
  }

let same_semantic left right =
  left.installation_id = right.installation_id
  && left.package_id = right.package_id
  && left.tool = right.tool
  && left.configuration_revision = right.configuration_revision

let members =
  [ "installation_id"; "package_id"; "tool"; "source_revision"; "configuration_revision" ]

let to_json destination =
  `Assoc
    [
      ("installation_id", `String destination.installation_id);
      ("package_id", `String destination.package_id);
      ("tool", `String destination.tool);
      ("source_revision", `String destination.source_revision);
      ("configuration_revision", `String destination.configuration_revision);
    ]

let of_json ~context json =
  let* fields =
    Agent_core.Execution_json.object_fields ~context ~required:members ~optional:[] json
  in
  let nonblank name =
    match Agent_core.Execution_json.string_field name fields with
    | Ok value when String.trim value <> "" -> Ok value
    | Ok _ -> Error (Printf.sprintf "%s: field %s is blank" context name)
    | Error detail -> Error (Printf.sprintf "%s: %s" context detail)
  in
  let* installation_id = nonblank "installation_id" in
  let* package_id = nonblank "package_id" in
  let* tool = nonblank "tool" in
  let* source_revision = nonblank "source_revision" in
  let* configuration_revision = nonblank "configuration_revision" in
  Ok { installation_id; package_id; tool; source_revision; configuration_revision }

module Batch = Runtime_setup_batch
let ( let* ) = Result.bind
let report = function
  | Ok json -> print_endline (Yojson.Safe.to_string json); 0
  | Error error ->
    let kind, runtime_id = match error with
      | Batch.Verification_failed id -> "verification_failed", `String id
      | Changed_configuration -> "changed_configuration", `Null
      | Invalid_selection -> "invalid_selection", `Null
      | Invalid_configuration -> "invalid_configuration", `Null
      | Configuration_unavailable -> "configuration_unavailable", `Null
      | Validation_failed -> "validation_failed", `Null
      | Write_failed -> "write_failed", `Null
      | Rollback_failed -> "rollback_failed", `Null
      | Lock_unavailable -> "lock_unavailable", `Null in
    print_endline (Yojson.Safe.to_string (`Assoc [
      "schema", `String "masc.runtime_setup_error.v1";
      "kind", `String kind; "runtime_id", runtime_id;
      "error", `String (Batch.error_message error)])); 1

let read_json path =
  try Ok (Yojson.Safe.from_file path)
  with Sys_error _ | Yojson.Json_error _ -> Error Batch.Invalid_selection

let render ~spec_path =
  report (let* json = read_json spec_path in
    let* spec = Runtime_setup_spec.of_json json
      |> Result.map_error (fun _ -> Batch.Invalid_selection) in
    Ok (Runtime_setup_spec.render_json (Runtime_setup_spec.render spec)))

let inventory ~base_path =
  report (let* revision, observation = Batch.observe_inventory ~base_path in
    let* config = Runtime_toml.parse_string observation.source_text
      |> Result.map_error (fun _ -> Batch.Invalid_configuration) in
    match Runtime_wizard_inventory.to_json ~include_credential_references:true config with
    | `Assoc fields -> Ok (`Assoc (("setup_revision", `String (Batch.revision_to_string revision)) :: fields))
    | _ -> Error Batch.Invalid_configuration)

type request = {
  revision : Batch.revision;
  specs : Runtime_setup_spec.t list;
  runtime_ids : string list;
  default_runtime_id : string;
  verify : bool;
}

let parse_request = function
  | `Assoc fields when
      List.sort String.compare (List.map fst fields) =
        ["connections"; "default_runtime_id"; "expected_revision"; "runtime_ids"; "verify"] ->
    let field key = List.assoc key fields in
    (match field "connections", field "runtime_ids", field "default_runtime_id",
           field "expected_revision", field "verify" with
     | `List specs, `List ids, `String default_runtime_id, `String revision, `Bool verify ->
       let* revision = Batch.revision_of_string revision in
       let rec parse_specs = function
         | [] -> Ok []
         | spec :: rest ->
           let* spec = Runtime_setup_spec.of_json spec
             |> Result.map_error (fun _ -> Batch.Invalid_selection) in
           let* rest = parse_specs rest in Ok (spec :: rest) in
       let rec parse_ids = function
         | [] -> Ok []
         | `String id :: rest -> let* rest = parse_ids rest in Ok (id :: rest)
         | _ -> Error Batch.Invalid_selection in
       let* specs = parse_specs specs in
       let* runtime_ids = parse_ids ids in
       Ok {revision; specs; runtime_ids; default_runtime_id; verify}
     | _ -> Error Batch.Invalid_selection)
  | _ -> Error Batch.Invalid_selection

let configure ~base_path ~request_path =
  report (let* json = read_json request_path in
    let* request = parse_request json in
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      Eio_context.set_env env;
      Eio_context.set_switch sw;
      Eio_context.set_net (Eio.Stdenv.net env);
      Eio_context.set_clock (Eio.Stdenv.clock env);
      Batch.configure ~binary:Sys.executable_name ~base_path
        ~expected_revision:request.revision ~specs:request.specs
        ~runtime_ids:request.runtime_ids ~default_runtime_id:request.default_runtime_id
        ~verify:request.verify () |> Result.map Batch.receipt_json)))

module Batch = Runtime_setup_batch
open Result.Syntax
let report = function
  | Ok json -> print_endline (Yojson.Safe.to_string json); 0
  | Error error ->
    let kind, runtime_id, failure = match error with
      | Batch.Verification_failed { runtime_id; code; message; detail } ->
        ("verification_failed", `String runtime_id,
         Some (`Assoc [
           "code", `String code; "message", `String message;
           ("detail", match detail with None -> `Null | Some detail -> `String detail)]))
      | Verification_unreadable { runtime_id; _ } -> "verification_unreadable", `String runtime_id, None
      | Changed_configuration -> "changed_configuration", `Null, None
      | Invalid_selection -> "invalid_selection", `Null, None
      | Invalid_configuration -> "invalid_configuration", `Null, None
      | Configuration_unavailable -> "configuration_unavailable", `Null, None
      | Child_not_started _ -> "child_not_started", `Null, None
      | Validation_failed _ -> "validation_failed", `Null, None
      | Commit_refused _ -> "commit_refused", `Null, None
      | Write_failed _ -> "write_failed", `Null, None
      | Lock_unavailable -> "lock_unavailable", `Null, None
      | Commit_unobserved _ -> "commit_unobserved", `Null, None in
    let fields =
      [ "schema", `String "masc.runtime_setup_error.v1";
        "kind", `String kind; "runtime_id", runtime_id;
        "error", `String (Batch.error_message error)]
      @ (match failure with None -> [] | Some failure -> [ "failure", failure ])
      @ (match Batch.error_detail error with None -> [] | Some detail -> [ "detail", `String detail ]) in
    print_endline (Yojson.Safe.to_string (`Assoc fields)); 1

(* The workspace's running server could not be used, so nothing was staged
   or saved. *)
let report_server_refusal message =
  print_endline
    (Yojson.Safe.to_string
       (`Assoc
          [ "schema", `String "masc.runtime_setup_error.v1";
            "kind", `String "server_refused";
            "runtime_id", `Null;
            "error", `String message ]));
  1

let read_json path =
  try Ok (Yojson.Safe.from_file path)
  with Sys_error _ | Yojson.Json_error _ -> Error Batch.Invalid_selection

let render ~base_path ~spec_path =
  report (let* json = read_json spec_path in
    let* spec = Runtime_setup_spec.of_json json
      |> Result.map_error (fun _ -> Batch.Invalid_selection) in
    let* spec = match base_path with
      | None -> Ok spec
      | Some base_path ->
        Eio_main.run (fun _ -> Eio.Switch.run (fun _ ->
          let* _, observation = Batch.observe_inventory ~base_path in
          let* config = Runtime_toml.parse_string observation.source_text
            |> Result.map_error (fun _ -> Batch.Invalid_configuration) in
          Runtime_setup_spec.resolve_provider spec config.providers
          |> Result.map_error (fun _ -> Batch.Invalid_selection))) in
    Ok (Runtime_setup_spec.render_json (Runtime_setup_spec.render spec)))

let inventory_of_text ~revision text =
  let* config = Runtime_toml.parse_string text
    |> Result.map_error (fun _ -> Batch.Invalid_configuration) in
  match Runtime_wizard_inventory.to_json ~include_credential_references:true config with
  | `Assoc fields -> Ok (`Assoc (("setup_revision", `String (Batch.revision_to_string revision)) :: fields))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error Batch.Invalid_configuration

(* The inventory is read from the writer the save will go to, so the revision
   it hands out is the one runtime-setup-batch compares (RFC-0482 §3.2). *)
let inventory ~base_path ~port ~agent =
  let locally () =
    report (let* revision, observation = Batch.observe_inventory ~base_path in
      inventory_of_text ~revision observation.source_text)
  in
  match Unix.realpath base_path with
  | exception Unix.Unix_error _ -> locally ()
  | real_base_path ->
    let route =
      Masc_cli_runtime_config_remote.with_client (fun ~clock ->
        match Masc_cli_runtime_config_remote.find ~clock ~base_path:real_base_path ~port ~agent with
        | Error message -> `Refused message
        | Ok Masc_cli_runtime_config_remote.No_server -> `Local
        | Ok (Masc_cli_runtime_config_remote.Running_server server) ->
          (match Masc_cli_runtime_config_remote.fetch ~clock server with
           | Error message -> `Refused message
           | Ok source ->
             let text = source.Masc_cli_runtime_config_remote.text in
             `Read (inventory_of_text ~revision:(Batch.revision_of_text text) text)))
    in
    match route with
    | `Local -> locally ()
    | `Refused message -> report_server_refusal message
    | `Read result -> report result

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

let configure ~base_path ~port ~agent ~request_path =
  match
    let* json = read_json request_path in
    parse_request json
  with
  | Error error -> report (Error error)
  | Ok request ->
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      Eio_context.set_env env;
      Eio_context.set_switch sw;
      Eio_context.set_net (Eio.Stdenv.net env);
      Eio_context.set_clock (Eio.Stdenv.clock env);
      let clock = Eio.Stdenv.clock env in
      (* With no process holding the workspace lease, the command is the
         writer: then nothing else writes the file and no reader is waiting. *)
      let locally () =
        report
          (Batch.configure ~binary:Sys.executable_name ~base_path
             ~expected_revision:request.revision ~specs:request.specs
             ~runtime_ids:request.runtime_ids ~default_runtime_id:request.default_runtime_id
             ~verify:request.verify ()
           |> Result.map Batch.receipt_json)
      in
      let route =
        match Unix.realpath base_path with
        | exception Unix.Unix_error _ -> `Local
        | real_base_path ->
          Masc_http_client.with_scoped_pool ~sw ~env (fun () ->
            match
              Masc_cli_runtime_config_remote.find ~clock ~base_path:real_base_path ~port ~agent
            with
            | Error message -> `Refused message
            | Ok Masc_cli_runtime_config_remote.No_server -> `Local
            | Ok (Masc_cli_runtime_config_remote.Running_server server) ->
              (* RFC-0482 §3.2: the running server is the writer. The save
                 is decided against its text and staged here; only the
                 publication goes to it. *)
              (match Masc_cli_runtime_config_remote.fetch ~clock server with
               | Error message -> `Refused message
               | Ok source ->
                 `Through_server
                   (Batch.configure_text ~binary:Sys.executable_name
                      ~original_text:source.Masc_cli_runtime_config_remote.text
                      ~expected_revision:request.revision ~specs:request.specs
                      ~runtime_ids:request.runtime_ids ~default_runtime_id:request.default_runtime_id
                      ~verify:request.verify
                      ~commit:(fun text ->
                        Masc_cli_runtime_config_remote.publish_setup_text ~clock server source ~text)
                      ())))
      in
      match route with
      | `Local -> locally ()
      | `Refused message -> report_server_refusal message
      | `Through_server result -> report (Result.map Batch.receipt_json result)))

module Store = Workspace_memory_proposal
let status_fields = ["status", `String "model_proposed";
  "semantic_verification", `String "not_performed"]
let full (id, proposal) = `Assoc (["id", `String id;
  "proposal", Store.to_json proposal] @ status_fields)
let summary (id, proposal) =
  let raw = Store.to_json proposal in
  let field key = Yojson.Safe.Util.member key raw in
  let sources = Yojson.Safe.Util.to_list (field "sources") in
  let bindings = List.map (fun source -> `Assoc [
    "source_id", Yojson.Safe.Util.member "source_id" source;
    "snapshot_id", Yojson.Safe.Util.member "snapshot_id" source]) sources in
  (* Summaries retain the model's exact claims and conflicts with source IDs.
     The explicit read resolves those IDs to full owners and source evidence. *)
  `Assoc (["id", `String id; "context_sha256", field "context_sha256";
    "proposal", field "proposal"; "source_count", `Int (List.length sources);
    "source_bindings", `List bindings; "gaps", field "gaps";
    "snapshots", field "snapshots"] @ status_fields)
let failure ~failure_class detail =
  Keeper_tool_execution.failure_data ~class_:failure_class ~message:detail
    (`Assoc ["ok", `Bool false; "error", `String detail])
let handle ~base_path ~args =
  let input = match args with
    | `Assoc [] -> Ok None
    | `Assoc ["id", `String id] -> Ok (Some id)
    | _ -> Error "Expected an object with optional string id only" in
  match input with
  | Error detail -> failure ~failure_class:Tool_result.Policy_rejection detail
  | Ok id ->
    let result = Domain_pool_ref.submit_io_or_inline (fun () ->
      match id with
      | None -> Store.list ~base_path |> Result.map (fun rows ->
          `Assoc ["ok", `Bool true; "proposals", `List (List.map summary rows)])
      | Some id -> Store.read ~base_path ~id |> Result.map (function
          | None -> `Assoc ["ok", `Bool true; "found", `Bool false; "id", `String id]
          | Some proposal -> `Assoc ["ok", `Bool true; "found", `Bool true;
              "result", full (id, proposal)])) in
    match result with
    | Ok json -> Keeper_tool_execution.success_data json
    | Error (Store.Invalid detail) -> failure ~failure_class:Tool_result.Policy_rejection detail
    | Error (Store.Unavailable detail) -> failure ~failure_class:Tool_result.Dependency_unavailable detail

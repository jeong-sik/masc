open Masc
module Source = Keeper_tool_result_source
module Page = Keeper_tool_result_page
let ( let* ) = Result.bind
let error status detail = status, `Assoc ["error",`String detail]

type request = {execution_id:string;offset:int;max_bytes:int;source_id:string option}
let request req =
  let fields=Uri.query (Uri.of_string req.Httpun.Request.target) in
  let value name = match List.filter (fun (key,_) -> String.equal key name) fields with
    | [] -> Ok None | [_,[value]] -> Ok (Some value)
    | _ -> Error (name ^ " must occur at most once with one value") in
  let* () = if List.for_all (fun (name,_) -> List.mem name
      ["execution_id";"offset";"max_bytes";"source_id";
       "expected_base_path";"expected_masc_root"]) fields then Ok ()
      else Error "Unknown original result query field" in
  let* execution_id=value "execution_id" in
  let* execution_id=match execution_id with
    | Some id when String.trim id<>"" -> Ok id
    | None | Some _ -> Error "execution_id is required" in
  let integer name default = let* value=value name in match value with
    | None -> Ok default
    | Some value ->
      (match Yojson.Safe.from_string value with
       | `Int n when n>=0 -> Ok n
       | _ -> Error ("Invalid nonnegative integer "^name)
       | exception Yojson.Json_error _ -> Error ("Invalid integer "^name)) in
  let* offset=integer "offset" 0 in
  let* max_bytes=integer "max_bytes" Keeper_artifact_read.default_max_bytes in
  let* source_id=value "source_id" in
  let* ()=match source_id with
    | None when offset=0 -> Ok ()
    | None -> Error "Continuation requires source_id"
    | Some digest -> Result.map_error (fun _ -> "Invalid original source_id")
        (Tool_output.validate_sha256 digest) in
  if max_bytes < Keeper_artifact_read.minimum_max_bytes
     || max_bytes > Keeper_artifact_read.maximum_max_bytes
  then Error "max_bytes exceeds the declared page bounds"
  else Ok {execution_id;offset;max_bytes;source_id}

let response ~config ~keeper req =
  if not (Keeper_config.validate_name keeper) then error `Bad_request "Invalid keeper"
  else match request req with
    | Error detail -> error `Bad_request detail
    | Ok request ->
      let run () =
        let ledger = Dated_jsonl.open_store (Dated_jsonl.Store.at
            (Workspace.dated_store_root config) Dated_jsonl.Store.Root.Tool_calls) in
        let* rows=Keeper_tool_call_index.by_execution_ids ~store:ledger
            ~keeper_name:keeper ~execution_ids:[request.execution_id]
          |> Result.map_error (error `Service_unavailable) in
        let* invocation=Source.invocation ~keeper
            ~execution_id:(Ids.Execution_id.of_string request.execution_id) ~rows
          |> Result.map_error (fun reason -> error
            (match reason with Source.Execution_missing -> `Not_found
             | Execution_ambiguous | Invalid_execution _ | Turn_mismatch _
             | Invalid_run _ | Invalid_occurrence _ | Result_missing -> `Conflict)
            (Source.error_to_string reason)) in
        let store=Dated_jsonl.open_store (Dated_jsonl.Store.keeper
            (Workspace.dated_store_root config) ~keeper Dated_jsonl.Store.Keeper.Turn_records) in
        let* record,_=Server_keeper_turn_records.read_exact ~store ~keeper
            ~turn_ref:(Source.turn_ref invocation)
          |> Result.map_error (fun detail -> error `Service_unavailable
              (Server_keeper_turn_records.exact_error_to_string detail)) in
        let* bound=Source.bind invocation record
          |> Result.map_error (fun reason -> error `Conflict (Source.error_to_string reason)) in
        let json value=Page.to_json ~keeper ~execution_id:request.execution_id value in
        match bound with
        | Source.Awaiting_turn -> Ok (`OK,json Page.Pending)
        | Untraced_turn -> Ok (`OK,json (Page.Unavailable "The enclosing turn retained no raw trace"))
        | Bound target ->
          let* reading=Keeper_tool_result_file.read ~config ~keeper target
            |> Result.map_error (error `Service_unavailable) in
          let* ()=match request.source_id with
            | Some expected when not (String.equal expected reading.source_id) ->
                Error (error `Conflict "Original result source changed; retry this execution")
            | None | Some _ -> Ok () in
          let identity : Page.identity = {source_id=reading.source_id;sha256=reading.sha256;
            recorded_bytes=reading.body.recorded_bytes;is_error=reading.body.is_error} in
          let envelope = Page.page_envelope ~keeper ~execution_id:request.execution_id identity in
          let page_request : Keeper_artifact_read.request = {
            sha256=reading.sha256;offset=request.offset;max_bytes=request.max_bytes} in
          let* page=Keeper_artifact_read.page ~envelope page_request reading.body.content
            |> Result.map_error (error `Bad_request) in
          Ok (`OK,json (Page.Page (identity,page))) in
      match run () with Ok result -> result | Error result -> result

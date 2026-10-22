module Ledger = Workspace_memory_ledger
module Request = Workspace_memory_request
module Brief = Workspace_memory_briefing
module Decision = Workspace_memory_decision
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
let ( let* ) = Result.bind
module Request_id = struct
  type t = string
  let fresh = Random_id.uuid_v7
  let of_string = Random_id.parse_uuid_v7
  let to_string value = value
  let compare = String.compare
end
type workspace = { path : string; device : int; inode : int }
let observe_workspace ~base_path =
  Fs_compat.with_owned_inventory_root base_path (fun root ->
    let stat = Fs_compat.owned_inventory_root_stat root in
    Ok {path=Fs_compat.owned_inventory_root_path root; device=stat.Unix.st_dev; inode=stat.Unix.st_ino})
  |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string
type destination = {
  installation_id : string; package_id : string; tool : string;
  source_revision : string; configuration_revision : string;
}
type work = Classification of {ledger : Ledger.t; batch : Request.batch} | Briefing of Brief.batch
type t = {id : Request_id.t; predecessor : Request_id.t option; workspace : workspace; destination : destination;
  prompt : Prompt_registry.prompt_resolution; work : work; input_text : string}
let scope = "workspace-curator"
let package_id = "workspace-curator"
let tool = "curate"
let request_id t = t.id
let predecessor t = t.predecessor
let destination t = t.destination
let base_path t = t.workspace.path
let work t = t.work
let input_text t = t.input_text
let input = function Classification {batch;_} -> batch.Request.input | Briefing batch -> Brief.input batch
let rendered = function Classification {batch;_} -> batch.Request.rendered_prompt | Briefing batch -> Brief.rendered_prompt batch
let rendered_prompt t = rendered t.work
let schema = function Classification _ -> Decision.output_schema | Briefing _ -> Brief.output_schema
let output_schema t = schema t.work
let fields names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | _ -> Error "captured Curator record has unknown, missing or repeated fields"
let text = function
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error "captured Curator record expects nonblank text"
let optional_text = function `Null -> Ok None | value -> Result.map Option.some (text value)
let boolean = function `Bool value -> Ok value | _ -> Error "captured Curator record expects a boolean"
let integer = function `Int value -> Ok value | _ -> Error "captured Curator workspace expects an integer"
let parsed text = try Ok (Yojson.Safe.from_string text) with Yojson.Json_error detail -> Error detail
let optional = Option.fold ~none:`Null ~some:(fun value -> `String value)
let workspace_json w = `Assoc ["path",`String w.path;"device",`Int w.device;"inode",`Int w.inode]
let workspace_of_json json =
  let* f = fields ["path";"device";"inode"] json in
  let* path = text (List.assoc "path" f) in
  let* device = integer (List.assoc "device" f) in
  let* inode = integer (List.assoc "inode" f) in
  if Filename.is_relative path then Error "captured workspace path must be absolute"
  else Ok {path;device;inode}
let destination_json d = `Assoc ["installation_id",`String d.installation_id;
  "package_id",`String d.package_id;"tool",`String d.tool;
  "source_revision",`String d.source_revision;"configuration_revision",`String d.configuration_revision]
let destination_of_json json =
  let* f = fields ["installation_id";"package_id";"tool";"source_revision";"configuration_revision"] json in
  let* installation_id = text (List.assoc "installation_id" f) in
  let* package_id = text (List.assoc "package_id" f) in
  let* tool = text (List.assoc "tool" f) in
  let* source_revision = text (List.assoc "source_revision" f) in
  let* configuration_revision = text (List.assoc "configuration_revision" f) in
  Ok {installation_id;package_id;tool;source_revision;configuration_revision}
let prompt_json (p : Prompt_registry.prompt_resolution) = `Assoc [
  "effective",`String p.effective;"source",`String (Prompt_registry.prompt_source_to_string p.source);
  "file_value",optional p.file_value;"override_value",optional p.override_value;
  "file_path",optional p.file_path;"file_exists",`Bool p.file_exists;"has_override",`Bool p.has_override]
let validate_prompt (p : Prompt_registry.prompt_resolution) =
  let source, effective = match p.override_value,p.file_value with
    | Some value, _ -> Prompt_registry.Override, value
    | None, Some value -> Prompt_registry.File, value
    | None, None -> Prompt_registry.Missing, "" in
  if source <> p.source || not (String.equal effective p.effective)
     || p.file_exists <> Option.is_some p.file_value
     || p.has_override <> Option.is_some p.override_value
  then Error "captured prompt resolution is internally inconsistent"
  else if String.trim effective = "" then Error "captured Curator prompt is missing"
  else Ok ()
let prompt_of_json json =
  let* f = fields ["effective";"source";"file_value";"override_value";"file_path";"file_exists";"has_override"] json in
  let* effective = text (List.assoc "effective" f) in
  let* source = match List.assoc "source" f with
    | `String "override" -> Ok Prompt_registry.Override
    | `String "file" -> Ok Prompt_registry.File
    | `String "missing" -> Ok Prompt_registry.Missing
    | _ -> Error "unknown captured prompt source" in
  (* Inactive file text can be empty beneath an effective override. *)
  let nullable_value = function `Null -> Ok None | `String value -> Ok (Some value)
    | _ -> Error "captured prompt value expects text or null" in
  let* file_value = nullable_value (List.assoc "file_value" f) in
  let* override_value = nullable_value (List.assoc "override_value" f) in
  let* file_path = optional_text (List.assoc "file_path" f) in
  let* file_exists = boolean (List.assoc "file_exists" f) in
  let* has_override = boolean (List.assoc "has_override" f) in
  let p = {Prompt_registry.effective;source;file_value;override_value;file_path;file_exists;has_override} in
  let* () = validate_prompt p in Ok p
let work_json = function
  | Classification {ledger;batch} -> `Assoc ["kind",`String "classification";
      "ledger",Ledger.to_json ledger;"batch",Request.batch_to_json batch]
  | Briefing batch -> `Assoc ["kind",`String "briefing";"batch",Brief.batch_to_json batch]
let work_of_json json =
  let kind = match json with `Assoc f -> List.assoc_opt "kind" f | _ -> None in
  match kind with
  | Some (`String "classification") ->
    let* f = fields ["kind";"ledger";"batch"] json in
    let* ledger = Ledger.of_json (List.assoc "ledger" f) in
    let* batch = Request.batch_of_json ~ledger (List.assoc "batch" f)
      |> Result.map_error Request.error_to_string in
    Ok (Classification {ledger;batch})
  | Some (`String "briefing") ->
    let* f = fields ["kind";"batch"] json in
    let* batch = Brief.batch_of_json (List.assoc "batch" f) in Ok (Briefing batch)
  | _ -> Error "unknown captured Curator request kind"
let check ~prompt ~input_text work =
  let* () = validate_prompt prompt in
  let* original_input = parsed input_text in
  let* original_input = Lane_addon_action.canonical original_input in
  let* () = if Yojson.Safe.equal original_input (input work) then Ok ()
    else Error "captured substitution bytes differ from the original batch input" in
  let key, variable = match work with
    | Classification _ -> Prompt_names.workspace_memory_curator, "workspace_memory_changes"
    | Briefing _ -> Prompt_names.workspace_memory_briefing, "workspace_memory_briefing" in
  let* expected_prompt = Prompt_registry.render_resolved_prompt_template key prompt [variable,input_text] in
  let* () = if String.equal expected_prompt (rendered work) then Ok ()
    else Error "captured rendered prompt differs from its original template and input bytes" in
  match work with
  | Classification _ -> Ok ()
  | Briefing batch ->
    let* original_contract = Brief.batch_contract batch in
    if String.equal original_contract (Brief.contract ~template:prompt.effective) then Ok ()
    else Error "captured briefing pass has a different prompt/schema contract"
let make ~request_id ~workspace ~destination ~prompt work =
  let* destination = destination_of_json (destination_json destination) in
  let* prompt = prompt_of_json (prompt_json prompt) in
  let input_text = Yojson.Safe.to_string (input work) in
  (* Preserve the parent's original substitution bytes separately. Its typed
     work uses the same canonical snapshot before and after durable retention,
     so narrowing cannot render a different child from reordered object keys. *)
  let* snapshot = Lane_addon_action.canonical (work_json work) in
  let* work = work_of_json snapshot in
  let* () = check ~prompt ~input_text work in
  Ok {id=request_id;predecessor=None;workspace;destination;prompt;work;input_text}
let classification ~request_id ~workspace ~destination ~prompt ~ledger ~batch =
  make ~request_id ~workspace ~destination ~prompt (Classification {ledger;batch})
let briefing ~request_id ~workspace ~destination ~prompt ~batch =
  make ~request_id ~workspace ~destination ~prompt (Briefing batch)
let to_json t = `Assoc ["schema",`String "workspace.memory.execution-capture.v2";
  "request_id",`String (Request_id.to_string t.id);
  "predecessor",optional (Option.map Request_id.to_string t.predecessor);"workspace",workspace_json t.workspace;
  "destination",destination_json t.destination;"prompt",prompt_json t.prompt;
  "work",work_json t.work;"input_text",`String t.input_text;"output_schema",schema t.work]
let restore_record ~workspace (retained : Owner.retained) =
  let* f = fields ["schema";"request_id";"predecessor";"workspace";"destination";"prompt";"work";"input_text";"output_schema"] retained.request in
  let* () = match List.assoc "schema" f with
    | `String "workspace.memory.execution-capture.v2" -> Ok ()
    | _ -> Error "unknown Curator execution capture schema" in
  let* id_text = text (List.assoc "request_id" f) in
  let* id = Request_id.of_string id_text in
  let* predecessor = match List.assoc "predecessor" f with
    | `Null -> Ok None
    | `String value -> Result.map Option.some (Request_id.of_string value)
    | _ -> Error "captured predecessor must be a request ID or null" in
  let* original_workspace = workspace_of_json (List.assoc "workspace" f) in
  let* () = if original_workspace = workspace then Ok () else Error "Curator request belongs to another physical workspace" in
  let* destination = destination_of_json (List.assoc "destination" f) in
  let* () = if String.equal retained.scope scope && String.equal retained.request_id id_text
      && String.equal retained.installation_id destination.installation_id
      && String.equal retained.package_id destination.package_id && String.equal retained.tool destination.tool
    then Ok () else Error "Curator capture differs from its original request owner" in
  let* prompt = prompt_of_json (List.assoc "prompt" f) in
  let* work = work_of_json (List.assoc "work" f) in
  let* () = if Yojson.Safe.equal (List.assoc "output_schema" f) (schema work) then Ok ()
    else Error "Curator capture has a different domain output schema" in
  let* input_text = text (List.assoc "input_text" f) in
  let* () = check ~prompt ~input_text work in
  Ok {id;predecessor;workspace;destination;prompt;work;input_text}
let classification_size originals =
  let answered = List.filter_map (fun (t, (phase : Progress.phase)) ->
      match t.work, phase with
      | Classification {batch;_}, (Finished _ | Conflicted _) -> Some (t, List.length batch.selected)
      | Classification _, (Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
                          | Commit_unknown _ | Rejected _ | Subdividing _ | Subdivided _)
      | Briefing _, _ -> None) originals in
  let latest = List.fold_left (fun latest (t, count) -> match latest with
      | Some (newer, _) when Request_id.compare newer.id t.id > 0 -> latest
      | Some _ | None -> Some (t, count)) None answered in
  match latest with
  | None -> Request.Fill_frame
  | Some ({predecessor = Some _; _}, count) -> Request.Up_to count
  | Some ({predecessor = None; _}, count) -> Request.Up_to (2 * count)
let narrow ~request_id ~final t =
  let* () = if Request_id.to_string request_id <> Request_id.to_string t.id then Ok ()
    else Error "a successor must have its own original request ID" in
  let* () = match final,t.work with
    | Exact.Call_final (Exact.Input_refused (Exact.Input_capacity | Exact.Context_overflow
        | Exact.Request_body_refused)),(Classification _ | Briefing _)
    | Exact.Call_final (Exact.Output_limit_reached _),Classification _ -> Ok ()
    | Exact.Call_final (Exact.Output_limit_reached _),Briefing _
    | Exact.Call_final (Exact.Answered _ | Exact.Invalid_output _ | Exact.Input_refused Exact.Invalid_request),
        (Classification _ | Briefing _)
    | (Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused),(Classification _ | Briefing _) ->
      Error "the original terminal does not permit this batch to be narrowed" in
  let key,variable = match t.work with
    | Classification _ -> Prompt_names.workspace_memory_curator,"workspace_memory_changes"
    | Briefing _ -> Prompt_names.workspace_memory_briefing,"workspace_memory_briefing" in
  let render input = Prompt_registry.render_resolved_prompt_template key t.prompt
    [variable,Yojson.Safe.to_string input] in
  let* smaller = match t.work with
    | Classification {ledger;batch} ->
      Request.narrow ~render ~ledger batch |> Result.map_error Request.error_to_string
      |> Result.map (Option.map (fun batch -> Classification {ledger;batch}))
    | Briefing batch -> Brief.narrow ~render batch |> Result.map (Option.map (fun batch -> Briefing batch)) in
  match smaller with
  | None -> Ok None
  | Some work ->
    let* child = make ~request_id ~workspace:t.workspace ~destination:t.destination ~prompt:t.prompt work in
    Ok (Some {child with predecessor=Some t.id})
let expected_successor original (refusal : Progress.refusal) (successor : Progress.successor) =
  let* id = Request_id.of_string successor.request_id in
  let* final = match refusal.stage with
    | Progress.Execution -> Exact.final_of_json ~schema:(output_schema original) refusal.evidence
    | Progress.Before_dispatch -> Error "Curator successor requires an original execution refusal" in
  let* child = narrow ~request_id:id ~final original in
  let* child = match child with Some child -> Ok child
    | None -> Error "an indivisible original batch cannot have a successor" in
  let* expected = Lane_addon_action.canonical (to_json child) in
  if Yojson.Safe.equal expected successor.request then Ok child
  else Error "Curator successor is not the original whole-batch reduction"
let restore_with ~pending ~workspace ~load retained =
  let rec walk seen (retained : Owner.retained) =
    let* () = if List.mem retained.request_id seen then Error "cyclic Curator predecessor chain" else Ok () in
    let* capture = restore_record ~workspace retained in
    match capture.predecessor with
    | None -> Ok capture
    | Some predecessor ->
      let* parent = load ~request_id:(Request_id.to_string predecessor) in
      let* parent = match parent with Some parent -> Ok parent
        | None -> Error "original Curator predecessor is absent" in
      let* original = walk (retained.request_id :: seen) parent in
      let* refusal,successor = match Progress.phase parent.progress with
        | Progress.Subdivided (refusal,successor) -> Ok (refusal,successor)
        | Progress.Subdividing (refusal,successor) when pending && Progress.events retained.progress=[] ->
          Ok (refusal,successor)
        | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
        | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _ | Progress.Conflicted _
        | Progress.Rejected _ | Progress.Subdividing _ ->
          Error "original Curator predecessor has not acknowledged this child" in
      let* () = if String.equal successor.request_id retained.request_id
          && Yojson.Safe.equal successor.request retained.request then Ok ()
        else Error "Curator child differs from its predecessor's original intent" in
      let* _ = expected_successor original refusal successor in
      Ok capture in
  walk [] retained
let restore ~workspace ~load retained = restore_with ~pending:false ~workspace ~load retained
module Originals = Map.Make (String)
let recoverable_successors ~workspace originals =
  let rec index records = function
    | [] -> Ok records
    | (original : Owner.retained)::rest ->
      if Originals.mem original.request_id records then Error "duplicate original Curator request ID"
      else index (Originals.add original.request_id original records) rest in
  let* records = index Originals.empty originals in
  let load ~request_id = Ok (Originals.find_opt request_id records) in
  let rec validate pending = function
    | [] -> Ok (List.rev pending)
    | (record : Owner.retained)::rest ->
      let* original = restore_with ~pending:true ~workspace ~load record in
      let* pending = match Progress.phase record.progress with
        | Progress.Subdividing (refusal,intent) ->
          let* _ = expected_successor original refusal intent in
          let* () = match Originals.find_opt intent.request_id records with
            | None -> Ok ()
            | Some child ->
              let* () = if Yojson.Safe.equal child.request intent.request && Progress.events child.progress=[] then Ok ()
                else Error "unacknowledged Curator child differs from its original initial capture" in
              let* _ = restore_with ~pending:true ~workspace ~load child in Ok () in
          Ok (record.request_id::pending)
        | Progress.Subdivided (refusal,intent) ->
          let* _ = expected_successor original refusal intent in
          let* child = match Originals.find_opt intent.request_id records with Some child -> Ok child
            | None -> Error "acknowledged original Curator child is absent" in
          let* () = if Yojson.Safe.equal child.request intent.request then Ok ()
            else Error "acknowledged Curator child differs from its original intent" in
          let* _ = restore ~workspace ~load child in Ok pending
        | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
        | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _ | Progress.Conflicted _
        | Progress.Rejected _ -> Ok pending in
      validate pending rest in
  validate [] originals
type expected_commit = Classification_commit of Ledger.t | Briefing_commit of Brief.t
let validate_output t raw = match t.work with
  | Classification {ledger;batch} ->
    let* assignments = Decision.decode ~batch raw in
    Ledger.apply ledger ~selected:batch.selected assignments
    |> Result.map_error Ledger.apply_error_to_string |> Result.map (fun ledger -> Classification_commit ledger)
  | Briefing batch ->
    let* text = Brief.decode_output raw in
    Brief.accept batch ~text |> Result.map (fun state -> Briefing_commit state)
let commit_plan t ~judgment =
  let* final = Exact.final_of_json ~schema:(output_schema t) judgment in
  let* expected = match final with
    | Exact.Call_final (Exact.Answered {output;_}) -> validate_output t (Exact.checked_json output)
    | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
    | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused ->
      Error "Domain commit requires the original answered judgment" in
  let domain kind state = `Assoc ["kind",`String kind;"state",state] in
  let* change = match t.work,expected with
    | Classification {ledger;_},Classification_commit after ->
      Ok {Progress.before=domain "classification" (Ledger.to_json ledger);
        after=domain "classification" (Ledger.to_json after)}
    | Briefing batch,Briefing_commit after ->
      Ok {Progress.before=domain "briefing" (Brief.to_json (Brief.prepared_state batch));
        after=domain "briefing" (Brief.to_json after)}
    | Classification _,Briefing_commit _ | Briefing _,Classification_commit _ ->
      Error "Original commit domain differs" in
  Ok (expected,change)

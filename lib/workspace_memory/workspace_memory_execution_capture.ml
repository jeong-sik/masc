module Ledger = Workspace_memory_ledger
module Request = Workspace_memory_request
module Brief = Workspace_memory_briefing
module Revision = Workspace_memory_revision
module Decision = Workspace_memory_decision
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
open Result.Syntax
module Request_id = struct
  type t = string
  let fresh = Random_id.uuid_v7
  let of_string = Random_id.parse_uuid_v7
  let to_string value = value
  let compare = String.compare
  let minted_on value =
    Result.map (fun time_ms ->
      let day = Unix.gmtime (Int64.to_float time_ms /. 1000.) in
      Printf.sprintf "%04d-%02d-%02d" (day.Unix.tm_year + 1900) (day.tm_mon + 1) day.tm_mday)
      (Random_id.uuid_v7_time_ms value)
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
type work = Classification of {ledger : Ledger.t; revision : Revision.ledger; batch : Request.batch} | Briefing of Brief.batch
type t = {id : Request_id.t; predecessor : Request_id.t option; workspace : workspace; destination : destination;
  prompt : Prompt_registry.prompt_resolution; work : work}
let scope = "workspace-curator"
let package_id = "workspace-curator"
let tool = "curate"
let request_id t = t.id
let predecessor t = t.predecessor
let destination t = t.destination
let base_path t = t.workspace.path
let work t = t.work
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
(* Renders with the captured template only, never today's prompt override. *)
let classification_render ~prompt input = Prompt_registry.render_resolved_prompt_template
  Prompt_names.workspace_memory_curator prompt ["workspace_memory_changes",Yojson.Safe.to_string input]
let briefing_render ~prompt input = Prompt_registry.render_resolved_prompt_template
  Prompt_names.workspace_memory_briefing prompt ["workspace_memory_briefing",Yojson.Safe.to_string input]
let renderer ~prompt = function
  | Classification _ -> classification_render ~prompt
  | Briefing _ -> briefing_render ~prompt
let sha256 text = Agent_core_sha256.(digest_string text |> to_hex)
let work_json = function
  | Classification {revision;batch;_} -> `Assoc ["kind",`String "classification";
      "ledger_revision",Revision.to_json (Revision.Ledger revision);"batch",Request.batch_to_json batch]
  | Briefing batch -> `Assoc ["kind",`String "briefing";"batch",Brief.batch_to_json batch]
let work_of_json ~load_ledger ~prompt json =
  let kind = match json with `Assoc f -> List.assoc_opt "kind" f | _ -> None in
  match kind with
  | Some (`String "classification") ->
    let* f = fields ["kind";"ledger_revision";"batch"] json in
    let* revision = Revision.of_json (List.assoc "ledger_revision" f) in
    let* revision = match revision with Revision.Ledger revision -> Ok revision
      | Revision.Briefing _ -> Error "a classification capture requires a ledger revision" in
    let* ledger = load_ledger revision in
    let* batch = Request.batch_of_json ~ledger ~render:(classification_render ~prompt) (List.assoc "batch" f)
      |> Result.map_error Request.error_to_string in
    Ok (Classification {ledger;revision;batch})
  | Some (`String "briefing") ->
    let* f = fields ["kind";"batch"] json in
    let* batch = Brief.batch_of_json ~render:(briefing_render ~prompt) (List.assoc "batch" f) in
    Ok (Briefing batch)
  | _ -> Error "unknown captured Curator request kind"
let check ~prompt work =
  let* () = validate_prompt prompt in
  match work with
  | Classification _ -> Ok ()
  | Briefing batch ->
    let* original_contract = Brief.batch_contract batch in
    if String.equal original_contract (Brief.contract ~template:prompt.effective) then Ok ()
    else Error "captured briefing pass has a different prompt/schema contract"
let make ~request_id ~workspace ~destination ~prompt work =
  let* destination = destination_of_json (destination_json destination) in
  let* prompt = prompt_of_json (prompt_json prompt) in
  (* The typed work is the canonical snapshot a restore reads, so a fresh and a
     restored capture narrow to the same child. The prompt the caller rendered
     must be the one the captured template renders. *)
  let* snapshot = Lane_addon_action.canonical (work_json work) in
  let load_ledger revision = match work with
    | Classification {ledger;revision=expected;_}
        when String.equal (Revision.ledger_sha256 revision) (Revision.ledger_sha256 expected) -> Ok ledger
    | Classification _ | Briefing _ -> Error "captured work names another ledger revision" in
  let* restored = work_of_json ~load_ledger ~prompt snapshot in
  let* () = if String.equal (rendered work) (rendered restored) then Ok ()
    else Error "captured prompt differs from the one its stored snapshot renders" in
  let* () = check ~prompt restored in
  Ok {id=request_id;predecessor=None;workspace;destination;prompt;work=restored}
let classification ~request_id ~workspace ~destination ~prompt ~ledger ~stored_ledger ~batch =
  let revision = Revision.stored_ledger_revision stored_ledger in
  let* () = if Revision.stored_ledger_workspace stored_ledger = (workspace.path,workspace.device,workspace.inode)
    then Ok () else Error "stored ledger belongs to another physical workspace" in
  let* () = if String.equal (Revision.ledger_sha256 revision) (Ledger.sha256 ledger) then Ok ()
    else Error "stored ledger receipt names another ledger state" in
  make ~request_id ~workspace ~destination ~prompt (Classification {ledger;revision;batch})
let briefing ~request_id ~workspace ~destination ~prompt ~batch =
  make ~request_id ~workspace ~destination ~prompt (Briefing batch)
let capture_schema = "workspace.memory.execution-capture.v4"
(* The model input is stored once, inside [work]; the prompt is rendered again
   on restore and only its digest is kept. *)
let to_json t = `Assoc ["schema",`String capture_schema;
  "request_id",`String (Request_id.to_string t.id);
  "predecessor",optional (Option.map Request_id.to_string t.predecessor);"workspace",workspace_json t.workspace;
  "destination",destination_json t.destination;"prompt",prompt_json t.prompt;
  "work",work_json t.work;"rendered_prompt_sha256",`String (sha256 (rendered t.work));
  "output_schema",schema t.work]
(* What a pass reads about an original without restoring it. It is derived
   from the capture, kept in the owner record, and checked against the
   capture on every restore. *)
module Summary = struct
  let schema = "workspace.memory.execution-summary.v1"
  type batch =
    | Classification of { up_to : Request.size; selected : Ledger.fact_ref list }
    | Briefing of { selected_count : int; prepared_state : string }
  type t = { predecessor : Request_id.t option; workspace : workspace; batch : batch }
  let output_schema t = match t.batch with
    | Classification _ -> Decision.output_schema | Briefing _ -> Brief.output_schema
  let to_json t = `Assoc (("schema", `String schema)
    :: ("predecessor", optional (Option.map Request_id.to_string t.predecessor))
    :: ("workspace", workspace_json t.workspace) ::
    match t.batch with
    | Classification {up_to; selected} -> ["kind",`String "classification";"up_to",Request.size_to_json up_to;
        "selected",`List (List.map Ledger.fact_ref_to_json selected)]
    | Briefing {selected_count; prepared_state} -> ["kind",`String "briefing";
        "selected_count",`Int selected_count;"prepared_state_sha256",`String prepared_state])
  let of_json json =
    let field key = match json with `Assoc f -> List.assoc_opt key f | _ -> None in
    let* () = match field "schema" with
      | Some (`String version) when String.equal version schema -> Ok ()
      | _ -> Error "unknown Curator summary schema" in
    let kind = field "kind" in
    let predecessor f = match List.assoc "predecessor" f with
      | `Null -> Ok None
      | `String value -> Result.map Option.some (Request_id.of_string value)
      | _ -> Error "a Curator summary predecessor must be a request ID or null" in
    match kind with
    | Some (`String "classification") ->
      let* f = fields ["schema";"predecessor";"workspace";"kind";"up_to";"selected"] json in
      let* predecessor = predecessor f in
      let* workspace = workspace_of_json (List.assoc "workspace" f) in
      let* up_to = Request.size_of_json (List.assoc "up_to" f) in
      let* selected = match List.assoc "selected" f with
        | `List (_ :: _ as refs) -> List.fold_right (fun json selected ->
            let* selected = selected in
            let* fact = Ledger.fact_ref_of_json json in Ok (fact :: selected)) refs (Ok [])
        | _ -> Error "a Curator classification summary selects at least one fact" in
      Ok {predecessor; workspace; batch=Classification {up_to; selected}}
    | Some (`String "briefing") ->
      let* f = fields ["schema";"predecessor";"workspace";"kind";"selected_count";"prepared_state_sha256"] json in
      let* predecessor = predecessor f in
      let* workspace = workspace_of_json (List.assoc "workspace" f) in
      let* selected_count = match List.assoc "selected_count" f with
        | `Int count when count >= 1 -> Ok count
        | _ -> Error "a Curator Briefing summary selects at least one entry" in
      let* prepared_state = match List.assoc "prepared_state_sha256" f with
        | `String digest when String_util.is_lowercase_sha256_hex digest -> Ok digest
        | _ -> Error "a Curator Briefing summary names its prepared state by SHA-256" in
      Ok {predecessor; workspace; batch=Briefing {selected_count; prepared_state}}
    | _ -> Error "unknown Curator summary kind"
end
let summary t =
  let* batch = match t.work with
    | Classification {batch;_} ->
      Ok (Summary.Classification {up_to=batch.size;
        selected=List.map (fun (fact : Ledger.pending_fact) -> fact.fact) batch.selected})
    | Briefing batch ->
      let prepared_state = Workspace_memory_revision.(briefing_sha256 (of_briefing (Brief.prepared_state batch))) in
      Ok (Summary.Briefing {selected_count=Brief.selected_count batch; prepared_state}) in
  Ok {Summary.predecessor=t.predecessor; workspace=t.workspace; batch}
let restore_record ~workspace (retained : Owner.retained) =
  let* f = fields ["schema";"request_id";"predecessor";"workspace";"destination";"prompt";"work";
                   "rendered_prompt_sha256";"output_schema"] retained.request in
  let* () = match List.assoc "schema" f with
    | `String schema when String.equal schema capture_schema -> Ok ()
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
  let load_ledger revision = Revision.read_ledger ~base_path:workspace.path revision
    |> Result.map_error (fun error -> "Curator original " ^ id_text ^ ": " ^ Revision.read_error_to_string error) in
  let* work = work_of_json ~load_ledger ~prompt (List.assoc "work" f) in
  let* () = if Yojson.Safe.equal (List.assoc "output_schema" f) (schema work) then Ok ()
    else Error "Curator capture has a different domain output schema" in
  let* sent = text (List.assoc "rendered_prompt_sha256" f) in
  let* () = if String.equal sent (sha256 (rendered work)) then Ok ()
    else Error "Curator capture now renders a different prompt than the one it recorded" in
  let* () = check ~prompt work in
  let t = {id;predecessor;workspace;destination;prompt;work} in
  let* summary = summary t in
  if Yojson.Safe.equal retained.summary (Summary.to_json summary) then Ok t
  else Error "Curator capture differs from the summary its owner record keeps"
(* One answered classification: when it was minted, whether it is a root,
   the size it was prepared for and how many facts it held. *)
type answered = { minted : Request_id.t; root : bool; prepared : Request.size; held : int }
let classification_size originals =
  let answered = List.filter_map (fun (minted, (summary : Summary.t), (phase : Progress.phase)) ->
      match summary.Summary.batch, phase with
      | Summary.Classification {up_to; selected}, (Finished _ | Conflicted _) ->
        Some {minted; root=Option.is_none summary.Summary.predecessor; prepared=up_to; held=List.length selected}
      | Summary.Classification _, (Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
                                  | Commit_unknown _ | Rejected _ | Subdividing _ | Subdivided _)
      | Summary.Briefing _, _ -> None) originals in
  let latest = List.fold_left (fun latest answer -> match latest with
      | Some newer when Request_id.compare newer.minted answer.minted > 0 -> latest
      | Some _ | None -> Some answer) None answered in
  match latest with
  | None -> Request.Fill_frame
  | Some {root=false; held; _} -> Request.Up_to held
  | Some {root=true; prepared; held; _} ->
    (match prepared with
     | Request.Fill_frame -> Request.Fill_frame
     | Request.Up_to target when held < target -> Request.Up_to target
     | Request.Up_to target -> Request.Up_to (2 * target))
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
  let render = renderer ~prompt:t.prompt t.work in
  let* smaller = match t.work with
    | Classification {ledger;revision;batch} ->
      Request.narrow ~render ~ledger batch |> Result.map_error Request.error_to_string
      |> Result.map (Option.map (fun batch -> Classification {ledger;revision;batch}))
    | Briefing batch -> Brief.narrow ~render batch |> Result.map (Option.map (fun batch -> Briefing batch)) in
  match smaller with
  | None -> Ok None
  | Some work ->
    let* child = make ~request_id ~workspace:t.workspace ~destination:t.destination ~prompt:t.prompt work in
    Ok (Some {child with predecessor=Some t.id})
let expected_successor original (refusal : Progress.refusal) (successor : Progress.successor) =
  let* id = Request_id.of_string successor.request_id in
  let* final = match refusal.stage with
    | Progress.Execution ->
      Exact.retained_final_of_json ~schema:(output_schema original) refusal.evidence
      |> Result.map Exact.delivered
    | Progress.Before_dispatch -> Error "Curator successor requires an original execution refusal" in
  let* child = narrow ~request_id:id ~final original in
  let* child = match child with Some child -> Ok child
    | None -> Error "an indivisible original batch cannot have a successor" in
  let* digest = Owner.request_digest (to_json child) in
  if String.equal digest successor.request_digest then Ok child
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
          && String.equal successor.request_digest retained.request_digest then Ok ()
        else Error "Curator child differs from its predecessor's original intent" in
      let* _ = expected_successor original refusal successor in
      Ok capture in
  walk [] retained
let restore ~workspace ~load retained = restore_with ~pending:false ~workspace ~load retained
module Originals = Map.Make (String)
(* Records and summaries only. A restore of an original walks its chain and
   checks every derivation; this checks the links between records and that
   every original was captured in this physical workspace. *)
let recoverable_successors ~workspace originals =
  let rec index records = function
    | [] -> Ok records
    | ((record, summary) as original : Owner.Record.t * Summary.t)::rest ->
      let id = Owner.Record.request_id record in
      if Originals.mem id records then Error "duplicate original Curator request ID"
      else if summary.Summary.workspace <> workspace then Error "Curator request belongs to another physical workspace"
      else index (Originals.add id original records) rest in
  let* records = index Originals.empty originals in
  let rec ancestry seen ((record, summary) : Owner.Record.t * Summary.t) =
    let id = Owner.Record.request_id record in
    if List.mem id seen then Error "cyclic Curator predecessor chain" else
    match summary.Summary.predecessor with
    | None -> Ok ()
    | Some predecessor ->
      let* parent = match Originals.find_opt (Request_id.to_string predecessor) records with
        | Some parent -> Ok parent | None -> Error "original Curator predecessor is absent" in
      let* successor = match Progress.phase (Owner.Record.progress (fst parent)) with
        | Progress.Subdivided (_,successor) -> Ok successor
        | Progress.Subdividing (_,successor) when Progress.events (Owner.Record.progress record)=[] -> Ok successor
        | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
        | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _ | Progress.Conflicted _
        | Progress.Rejected _ | Progress.Subdividing _ ->
          Error "original Curator predecessor has not acknowledged this child" in
      let* () = if String.equal successor.request_id id
          && String.equal successor.request_digest (Owner.Record.request_digest record) then Ok ()
        else Error "Curator child differs from its predecessor's original intent" in
      ancestry (id :: seen) parent in
  let child_of parent (intent : Progress.successor) (child, (child_summary : Summary.t)) =
    if String.equal (Owner.Record.request_digest child) intent.request_digest
       && Option.map Request_id.to_string child_summary.Summary.predecessor = Some parent then Ok ()
    else Error "Curator child differs from its parent's original intent" in
  let rec validate pending = function
    | [] -> Ok (List.rev pending)
    | ((record, _) as original)::rest ->
      let id = Owner.Record.request_id record in
      let* () = ancestry [] original in
      let* pending = match Progress.phase (Owner.Record.progress record) with
        | Progress.Subdividing (_,intent) ->
          let* () = match Originals.find_opt intent.request_id records with
            | None -> Ok ()
            | Some ((child, _) as found) ->
              if Progress.events (Owner.Record.progress child)=[] then child_of id intent found
              else Error "an unacknowledged Curator child has already started" in
          Ok (id::pending)
        | Progress.Subdivided (_,intent) ->
          let* found = match Originals.find_opt intent.request_id records with Some found -> Ok found
            | None -> Error "acknowledged original Curator child is absent" in
          let* () = child_of id intent found in Ok pending
        | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
        | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _ | Progress.Conflicted _
        | Progress.Rejected _ -> Ok pending in
      validate pending rest in
  validate [] originals
let refusal_blocks summary (refusal : Progress.refusal) =
  match refusal.stage with
  | Progress.Before_dispatch -> Ok true
  | Progress.Execution ->
    let* retained = Exact.retained_final_of_json ~schema:(Summary.output_schema summary) refusal.evidence in
    match retained with
    | Exact.Retained_unknown Exact.Interrupted -> Ok false
    | Exact.Retained_unknown (Exact.Cut | Exact.Raised)
    | Exact.Retained_call (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
    | Exact.Retained_not_allowed _ | Exact.Retained_request_id_reused -> Ok true
    | Exact.Retained_call (Exact.Answered _) -> Error "An original refusal cannot contain an Answered judgment"
(* Chains no pass needs again, leaf first. Interrupted leaves release their
   inputs, but observer work must still be acknowledged across the chain. *)
type settling = Classifications | Briefings of { state : string }
let settled_chains settling originals =
  let records = List.fold_left (fun records ((record, _) as original : Owner.Record.t * Summary.t) ->
      Originals.add (Owner.Record.request_id record) original records) Originals.empty originals in
  let observed record = match Progress.observer (Owner.Record.progress record) with
    | {Lane_addon_request_receipt.registration=Acknowledged _; completion=Acknowledged _} -> true
    | {registration=(Unobserved | Pending _); _}
    | {registration=Acknowledged _; completion=(Unobserved | Pending _)} -> false in
  let answered record = match Progress.phase (Owner.Record.progress record) with
    | Progress.Finished _ | Progress.Conflicted _ -> true
    | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
    | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Rejected _ | Progress.Subdividing _
    | Progress.Subdivided _ -> false in
  (* The chain from [original] down to its leaf, leaf first. A missing or
     repeated child is a broken link, which discovery refuses. *)
  let rec chain below ((record, _) as original : Owner.Record.t * Summary.t) =
    match Progress.phase (Owner.Record.progress record) with
    | Progress.Subdivided (_, intent) ->
      if List.exists (fun (above, _) -> String.equal (Owner.Record.request_id above) intent.request_id) below
      then None
      else Option.bind (Originals.find_opt intent.request_id records) (chain (original :: below))
    | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
    | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _ | Progress.Conflicted _
    | Progress.Rejected _ | Progress.Subdividing _ -> Some (original :: below) in
  let latest_answer = List.fold_left (fun latest ((record, summary) : Owner.Record.t * Summary.t) ->
      match summary.Summary.batch with
      | Summary.Classification _ when answered record ->
        let id = Owner.Record.request_id record in
        (match latest with
         | Some newer when Request_id.compare newer id > 0 -> latest
         | Some _ | None -> Some id)
      | Summary.Classification _ | Summary.Briefing _ -> latest) None originals in
  let* chains = List.fold_left (fun accumulated ((root, summary) as original : Owner.Record.t * Summary.t) ->
    let* accumulated = accumulated in
    match summary.Summary.predecessor, chain [] original with
    | Some _, _ | None, (None | Some []) -> Ok accumulated
    | None, Some ((leaf, leaf_summary) :: _ as leaf_first) ->
      let* interrupted = match Progress.phase (Owner.Record.progress leaf) with
        | Progress.Rejected refusal -> Result.map not (refusal_blocks leaf_summary refusal)
        | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
        | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _ | Progress.Conflicted _
        | Progress.Subdividing _ | Progress.Subdivided _ -> Ok false in
      (* A child is captured with its parent's kind, so the leaf names the
         chain's domain. *)
      let unneeded = match settling, leaf_summary.Summary.batch with
        | Classifications, Summary.Classification _ ->
          interrupted || latest_answer <> Some (Owner.Record.request_id leaf)
        | Briefings {state}, Summary.Briefing {prepared_state; _} ->
          interrupted || not (String.equal prepared_state state)
        | Classifications, Summary.Briefing _ | Briefings _, Summary.Classification _ -> false in
      if unneeded && (answered leaf || interrupted) && List.for_all (fun (record, _) -> observed record) leaf_first
      then Ok ((Owner.Record.request_id root, List.map fst leaf_first) :: accumulated)
      else Ok accumulated) (Ok []) originals in
  Ok (List.rev chains)
type expected_commit = Classification_commit of Ledger.t | Briefing_commit of Brief.t
let validate_output t raw = match t.work with
  | Classification {ledger;batch;_} ->
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

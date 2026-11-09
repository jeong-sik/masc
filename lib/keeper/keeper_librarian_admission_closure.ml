module Capture = Keeper_librarian_admission_capture
module Parts = Keeper_librarian_admission_parts
module Gate_journal = Keeper_librarian_admission_gate
module Owner = Lane_addon_tool_request_owner
module Record = Owner.Record
module Progress = Lane_addon_request_progress
module Current = Keeper_memory_os_current
module Queue = Keeper_memory_admission_queue
module Store = Lane_addon_store
open Result.Syntax

type kind = Part | Partition | Execution | Gate
type stage = Captured | Closing | Closed
type member = {kind:kind; metadata:Record.t; payload:Yojson.Safe.t option}
type t = {original:Owner.retained; owner:Capture.owner; day:string;
          ids:Current.explicit_candidate_id list; originals:member list; state:stage}
let require condition detail = if condition then Ok () else Error detail
let owned value = Result.map_error Owner.error_to_string value
let same left right detail =
  let* left=Lane_addon_action.canonical left in
  let* right=Lane_addon_action.canonical right in
  require (Yojson.Safe.equal left right) detail
let prefix="keeper-librarian-admission-closure/"
let is_scope value=String.starts_with ~prefix value
let scope owner=prefix ^ Capture.scope_hash (Capture.scope_identity owner)
let scope_for owner = function
  | Part -> Parts.scope owner | Partition -> Parts.partition_scope owner
  | Execution -> Capture.scope owner | Gate -> Gate_journal.scope owner
let kind_json = function
  | Part -> `String "part" | Partition -> `String "partition"
  | Execution -> `String "execution" | Gate -> `String "gate"
let kind_of_json = function
  | `String "part" -> Ok Part | `String "partition" -> Ok Partition
  | `String "execution" -> Ok Execution | `String "gate" -> Ok Gate
  | _ -> Error "Unknown admission closure member kind"
let fields names = function
  | `Assoc values when List.sort String.compare (List.map fst values)=List.sort String.compare names -> Ok values
  | _ -> Error "Unknown, missing or repeated admission closure fields"
let value = List.assoc
let text = function
  | `String value when value<>"" && String.trim value=value -> Ok value
  | _ -> Error "Admission closure requires canonical nonblank text"
let list decode = function
  | `List values ->
    let rec loop found = function
      | [] -> Ok (List.rev found)
      | json::rest -> let* value=decode json in loop (value::found) rest in
    loop [] values
  | _ -> Error "Admission closure requires an array"
let candidate_json=Keeper_memory_os_current_range_codec.explicit_candidate_id_to_json
let candidate_of_json json=Keeper_memory_os_current_range_codec.explicit_candidate_id_of_json json
  |> Result.map_error Keeper_memory_os_types.wire_error_to_string
let member_json member = `Assoc ["kind",kind_json member.kind;
  "record",Owner.record_to_json member.metadata;
  "request",Option.value ~default:`Null member.payload]
let member_of_json ~owner json =
  let* f=fields ["kind";"record";"request"] json in
  let* kind=kind_of_json (value "kind" f) in
  let metadata=value "record" f in
  let* header=match metadata with `Assoc f -> Ok f | _ -> Error "Closure member record is not an object" in
  let* id=Option.to_result ~none:"Closure member ID is missing" (List.assoc_opt "request_id" header) in
  let* id=text id in
  let* metadata=Owner.decode_published ~directory_name:(Store.digest (scope_for owner kind))
    ~file_name:(Store.digest id ^ ".json") metadata in
  let payload=value "request" f in
  let* payload=match kind,payload with
    | Execution,`Null -> Ok None
    | Execution,_ -> Error "Admission closure must not copy an execution body"
    | (Part | Partition | Gate),`Null -> Error "Admission closure lost a source payload"
    | (Part | Partition | Gate),payload ->
      let* digest=Owner.request_digest payload in
      let+ ()=require (digest=Record.request_digest metadata) "Closure member payload digest changed" in
      Some payload in
  Ok {kind;metadata;payload}
let candidate_list ids=`List (List.map candidate_json ids)
let manifest_json ~owner ~id ~day ~ids originals = `Assoc [
  "schema",`Int 1;"kind",`String "admission_forest_closure";
  "request_id",`String id;"owner",Capture.owner_to_json owner;"date",`String day;
  "candidate_ids",candidate_list ids;"members",`List (List.map member_json originals)]
let member_identity member = `Assoc ["scope",`String (Record.scope member.metadata);
  "request_id",`String (Record.request_id member.metadata)]
let summary id=`Assoc ["kind",`String "admission_forest_closure";"request_id",`String id]
let transaction original day originals =
  let identity=`List (List.map member_identity originals) in
  let judgment=`Assoc ["kind",`String "admission_forest_closure";
    "manifest_sha256",`String original.Owner.request_digest] in
  let change : Progress.change={before=`Assoc ["live",identity];
    after=`Assoc ["settled",identity;"date",`String day]} in
  [Progress.Dispatch_intended;Progress.Judgment_retained judgment;Progress.Commit_intended change],change.after
let fold events=List.fold_left (fun result event -> let* progress=result in Progress.append progress event)
  (Ok Progress.captured) events
let stage_of_progress original day originals =
  let events,after=transaction original day originals in
  let* closing=fold events in
  let* closed=Progress.append closing (Progress.Commit_observed after) in
  let actual=Progress.to_json original.Owner.progress in
  if Yojson.Safe.equal actual (Progress.to_json Progress.captured) then Ok Captured
  else if Yojson.Safe.equal actual (Progress.to_json closing) then Ok Closing
  else if Yojson.Safe.equal actual (Progress.to_json closed) then Ok Closed
  else Error "Admission closure has an unsupported or incomplete host journal"
let materialize member = match member.payload with
  | None -> Ok None
  | Some payload ->
    let reader=Owner.Published_reader.create ~read_body:(fun ~scope:_ ~request_digest:_ ->
      let+ canonical=Lane_addon_action.canonical payload in Some (Yojson.Safe.to_string canonical)) in
    let+ retained=Owner.Published_reader.read reader
      ~directory_name:(Store.digest (Record.scope member.metadata))
      ~file_name:(Store.digest (Record.request_id member.metadata) ^ ".json")
      (Owner.record_to_json member.metadata) in Some retained
let validate_members ~owner ~ids originals =
  let* decoded=list candidate_of_json (candidate_list ids) in
  let* ()=require (ids<>[] && decoded=ids && ids=List.sort_uniq Stdlib.compare ids)
    "Admission closure candidate identities are empty, repeated or unordered" in
  let keys=List.map (fun member -> Record.scope member.metadata,Record.request_id member.metadata) originals in
  let bodies=List.map (fun member -> Record.scope member.metadata,Record.request_digest member.metadata) originals in
  let* ()=require (List.length keys=List.length (List.sort_uniq Stdlib.compare keys)
    && List.length bodies=List.length (List.sort_uniq Stdlib.compare bodies))
    "Admission closure repeats an original or shared request body" in
  let* ()=List.fold_left (fun result member -> let* ()=result in
    let* ()=require (Record.scope member.metadata=scope_for owner member.kind)
      "Admission closure member belongs to another scope" in
    match member.kind with
    | Part | Execution | Gate -> Ok ()
    | Partition -> match Progress.phase (Record.progress member.metadata) with
      | Progress.Finished _ -> Ok ()
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
        Error "Admission closure contains an unacknowledged partition") (Ok ()) originals in
  let* small=List.fold_left (fun result member ->
    let* records=result in let+ record=materialize member in
    Option.fold ~none:records ~some:(fun record -> record::records) record) (Ok []) originals in
  let read ~scope ~request_id=Ok (List.find_opt (fun (record:Owner.retained) ->
    record.scope=scope && record.request_id=request_id) small) in
  let read_scope ~scope=Ok (List.filter (fun (record:Owner.retained) -> record.scope=scope) small) in
  let* ()=Parts.validate_payload_forest ~read_scope ~owner in
  let* part_ids=List.fold_left (fun result member -> let* ids=result in
    match member.kind with
    | Part ->
      let+ batch=Parts.load_parent_payload ~read ~owner ~request_id:(Record.request_id member.metadata) in
      Queue.candidate_ids batch @ ids
    | Partition | Execution | Gate -> Ok ids) (Ok []) originals in
  require (List.sort_uniq Stdlib.compare part_ids=ids)
    "Admission closure does not cover every original candidate"
let restore ~owner (original:Owner.retained) =
  let* f=fields ["schema";"kind";"request_id";"owner";"date";"candidate_ids";"members"] original.request in
  let* ()=require (value "schema" f=`Int 1 && value "kind" f=`String "admission_forest_closure")
    "Unknown admission closure schema" in
  let* id=text (value "request_id" f) in
  let* ()=Capture.owner_matches_json owner (value "owner" f) in
  let* source_scope=Capture.scope_of_request_id id in
  let* ()=require (source_scope=Capture.scope owner && original.scope=scope owner && original.request_id=id)
    "Admission closure belongs to another physical owner" in
  let* day=text (value "date" f) in
  let* minted_day=Capture.minted_on id in
  let* ()=require (day=minted_day) "Admission closure archive day changed" in
  let* ids=list candidate_of_json (value "candidate_ids" f) in
  let* originals=list (member_of_json ~owner) (value "members" f) in
  let* ()=validate_members ~owner ~ids originals in
  let* first=List.find_opt (fun member -> member.kind=Part) originals
    |> Option.to_result ~none:"Admission closure has no original parts" in
  let* ()=require (original.installation_id=Record.installation_id first.metadata
    && original.package_id=Capture.package_id && original.tool=Capture.tool)
    "Admission closure destination differs from its original parts" in
  let* ()=same original.summary (summary id) "Admission closure summary changed" in
  let* ()=same original.request (manifest_json ~owner ~id ~day ~ids originals)
    "Noncanonical admission closure payload" in
  let* state=stage_of_progress original day originals in
  Ok {original;owner;day;ids;originals;state}
let stage value=value.state
let candidates value=value.ids
let members value=
  let order = function Gate -> 0 | Execution -> 1 | Partition -> 2 | Part -> 3 in
  List.stable_sort (fun left right -> Int.compare (order left.kind) (order right.kind)) value.originals
let member_record value=value.metadata
let date value=value.day
let record value=value.original
let named_ids value=List.map (fun member -> Record.request_id member.metadata) value.originals
let retain ~store ~owner ~request_id ~candidates:ids ~originals =
  let* source_scope=Capture.scope_of_request_id request_id in
  let* ()=require (source_scope=Capture.scope owner) "Admission closure ID belongs to another owner" in
  let* day=Capture.minted_on request_id in
  let originals=List.map (fun (kind,(record:Owner.retained)) ->
    {kind;metadata=Owner.listed record;payload=(match kind with
      | Execution -> None | Part | Partition | Gate -> Some record.request)}) originals in
  let* ()=validate_members ~owner ~ids originals in
  let* existing=Owner.discover ~store ~scope:(scope owner) |> owned in
  let* ()=require (List.for_all (fun record -> Record.request_id record=request_id) existing)
    "An admission closing transaction already exists" in
  let* archived=Owner.load_settled ~store ~scope:(scope owner) ~date:day ~request_id |> owned in
  let* ()=require (Option.is_none archived) "An admission closure ID was already settled" in
  let* first=List.find_opt (fun member -> member.kind=Part) originals
    |> Option.to_result ~none:"Cannot close an empty admission forest" in
  let request=manifest_json ~owner ~id:request_id ~day ~ids originals in
  let* ()=Owner.retain ~store ~scope:(scope owner) ~request_id
    ~installation_id:(Record.installation_id first.metadata) ~package_id:Capture.package_id
    ~tool:Capture.tool ~summary:(summary request_id) ~request |> owned in
  let* original=Owner.load ~store ~scope:(scope owner) ~request_id |> owned in
  let* original=Option.to_result ~none:"Admission closure disappeared after retain" original in
  restore ~owner original
let publish ~store value events =
  let* publication=Owner.advance_events ~store ~expected:value.original ~events
    |> Result.map_error Owner.update_error_to_string in
  match publication with
  | Owner.Stored original | Already_stored original -> restore ~owner:value.owner original
  | Unconfirmed detail -> Error ("Reload the original admission closure after uncertain publication: " ^ detail)
let intend ~store value =
  match value.state with
  | Captured -> let events,_=transaction value.original value.day value.originals in publish ~store value events
  | Closing | Closed -> Ok value
let confirm ~store value =
  match value.state with
  | Captured -> Error "Admission closure has no confirmed intent"
  | Closing -> let _,after=transaction value.original value.day value.originals in
    publish ~store value [Progress.Commit_observed after]
  | Closed -> Ok value

type reader = scope:string -> request_id:string -> (Owner.retained option,string) result
type scope_reader = scope:string -> (Owner.retained list,string) result
type body_reader = scope:string -> request_digest:string -> (Yojson.Safe.t,string) result
type archive_reader = scope:string -> date:string -> request_id:string -> (Record.t option,string) result
type view = {closure:t option;read:reader;read_scope:scope_reader;read_body:body_reader;live_members:Owner.retained list}
let same_record member record = same (Owner.record_to_json member.metadata)
  (Owner.record_to_json record) "Admission closure member metadata changed"
let project ~owner ~read ~read_scope ~read_body ~read_archive =
  let* closing=read_scope ~scope:(scope owner) in
  match closing with
  | [] -> Ok {closure=None;read;read_scope;read_body;live_members=[]}
  | _::_::_ -> Error "An admission owner has multiple closing transactions"
  | [original] ->
    let* closure=restore ~owner original in
    let expected_scope scope=List.exists (fun kind -> scope=scope_for owner kind) [Part;Partition;Execution;Gate] in
    let member_at scope id=List.find_opt (fun member -> Record.scope member.metadata=scope
      && Record.request_id member.metadata=id) closure.originals in
    let check_location member current =
      let scope=Record.scope member.metadata and request_id=Record.request_id member.metadata in
      match current with
      | Some current ->
        let* ()=require (closure.state<>Closed) "Closed admission manifest still has live members" in
        let+ ()=same_record member (Owner.listed current) in Some current
      | None ->
        let* ()=require (closure.state<>Captured) "Captured admission closure lost a live member" in
        let* archived=read_archive ~scope ~date:closure.day ~request_id in
        let* archived=Option.to_result ~none:"Admission closure member is neither live nor archived" archived in
        let+ ()=same_record member archived in None in
    let locate member =
      let* current=read ~scope:(Record.scope member.metadata) ~request_id:(Record.request_id member.metadata) in
      check_location member current in
    let projected_read ~scope ~request_id =
      if not (expected_scope scope) then read ~scope ~request_id else
      match member_at scope request_id with
      | None -> Error "Admission closure does not name this original"
      | Some member -> let* current=locate member in
        match current with Some _ -> Ok current | None -> materialize member in
    let check_scope ~scope current =
      let* ()=List.fold_left (fun result (record:Owner.retained) -> let* ()=result in
        match member_at scope record.request_id with
        | None -> Error "A new original appeared while its admission forest was closing"
        | Some member -> same_record member (Owner.listed record)) (Ok ()) current in
      List.fold_left (fun result member -> let* (records,live)=result in
        if Record.scope member.metadata<>scope then Ok (records,live) else
        let actual=List.find_opt (fun (record:Owner.retained) -> record.request_id=Record.request_id member.metadata) current in
        let* actual=check_location member actual in
        let+ record=match actual with Some _ -> Ok actual | None -> materialize member in
        Option.fold ~none:records ~some:(fun record -> record::records) record,
        Option.fold ~none:live ~some:(fun record -> record::live) actual) (Ok ([],[])) closure.originals
      |> Result.map (fun (records,live) -> List.rev records,List.rev live) in
    let projected_scope ~scope =
      if not (expected_scope scope) then read_scope ~scope else
      let* current=read_scope ~scope in let+ projected,_=check_scope ~scope current in projected in
    let projected_body ~scope ~request_digest =
      match List.find_opt (fun member -> Record.scope member.metadata=scope
        && Record.request_digest member.metadata=request_digest) closure.originals with
      | None -> read_body ~scope ~request_digest
      | Some member ->
        let* current=locate member in
        match current,member.payload with
        | Some _,_ | None,None -> read_body ~scope ~request_digest
        | None,Some payload -> Ok payload in
    let* live_members=List.fold_left (fun result kind ->
      let* records=result in
      let scope=scope_for owner kind in
      let* current=read_scope ~scope in
      let+ _,live=check_scope ~scope current in records @ live) (Ok []) [Part;Partition;Execution;Gate] in
    let live_kind kind=List.exists (fun (record:Owner.retained) -> record.scope=scope_for owner kind) live_members in
    let absent_kind kind=List.exists (fun member -> member.kind=kind
      && not (List.exists (fun (record:Owner.retained) -> record.scope=Record.scope member.metadata
        && record.request_id=Record.request_id member.metadata) live_members)) closure.originals in
    let* ()=require (not (live_kind Gate && absent_kind Execution)
      && not ((absent_kind Part || absent_kind Partition) && (live_kind Gate || live_kind Execution)))
      "Admission closure violated gate/execution/source settlement order" in
    Ok {closure=Some closure;read=projected_read;read_scope=projected_scope;
        read_body=projected_body;live_members}

module Capture = Keeper_librarian_admission_capture
module Queue = Keeper_memory_admission_queue
module Current = Keeper_memory_os_current
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Gate = Keeper_librarian_absorb_gate
let ( let* ) = Result.bind
let ( let+ ) result f = Result.map f result
let require condition detail = if condition then Ok () else Error detail
let fields expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare expected -> Ok fields
  | _ -> Error "Original Librarian part has unknown, missing or duplicate fields"
let value key fields = List.assoc key fields
let text = function `String value when String.trim value <> "" -> Ok value
  | _ -> Error "Original Librarian part requires nonblank text"
let integer = function `Int value -> Ok value | _ -> Error "Original Librarian part requires integer"
let list decode = function
  | `List values -> List.fold_right (fun json result -> let* item=decode json in let+ rest=result in item::rest) values (Ok [])
  | _ -> Error "Original Librarian part requires array"
let optional encode = Option.fold ~none:`Null ~some:encode
let option decode = function `Null -> Ok None | json -> let+ value=decode json in Some value
let canonical = Lane_addon_action.canonical
let same a b = let* a=canonical a in let+ b=canonical b in Yojson.Safe.equal a b
let equal a b detail = let* same=same a b in require same detail
let owner_error result = Result.map_error Owner.error_to_string result
let update_error = Result.map_error Owner.update_error_to_string
let rec ordered (json:Yojson.Safe.t) : Yojson.Safe.t = match json with
  | `Assoc fields -> `Assoc (List.sort (fun (a,_) (b,_) -> String.compare a b)
      (List.map (fun (key,value) -> key,ordered value) fields))
  | `List values -> `List (List.map ordered values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value -> value
let owner_hash owner =
  Lane_addon_store.digest (Yojson.Safe.to_string (ordered (Capture.owner_to_json owner)))
let scope owner = "keeper-librarian-parts/" ^ owner_hash owner
let partition_scope owner = "keeper-librarian-partitions/" ^ owner_hash owner
let destination_json (d:Capture.destination) = `Assoc [
  "installation_id",`String d.installation_id;"package_id",`String d.package_id;
  "tool",`String d.tool;"source_revision",`String d.source_revision;
  "configuration_revision",`String d.configuration_revision]
let destination_of_json json =
  let* f=fields ["installation_id";"package_id";"tool";"source_revision";"configuration_revision"] json in
  let* installation_id=text (value "installation_id" f) in
  let* installation=Owner.installation_of_id installation_id in
  let* ()=match installation with Owner.Configuration _ -> Ok () | Owner.Manual _ -> Error "Original Librarian part requires configured installation" in
  let* package_id=text (value "package_id" f) in let* tool=text (value "tool" f) in
  let* source_revision=text (value "source_revision" f) in
  let* configuration_revision=text (value "configuration_revision" f) in
  let+ ()=require (package_id=Capture.package_id && tool=Capture.tool) "Original Librarian part destination changed" in
  {Capture.installation_id;package_id;tool;source_revision;configuration_revision}
let candidate_json (id:Current.explicit_candidate_id) = `Assoc [
  "queue_generation",`String id.queue_generation;"request_id",`String id.request_id;
  "sequence",`Int id.sequence;"input_sha256",`String id.input_sha256]
let candidate_of_json json =
  let* f=fields ["queue_generation";"request_id";"sequence";"input_sha256"] json in
  let* queue_generation=text (value "queue_generation" f) in let* request_id=text (value "request_id" f) in
  let* sequence=integer (value "sequence" f) in let* input_sha256=text (value "input_sha256" f) in
  let+ ()=require (sequence>0 && queue_generation=String.trim queue_generation && request_id=String.trim request_id
    && String_util.is_lowercase_sha256_hex input_sha256) "Invalid original candidate identity" in
  {Current.queue_generation;request_id;sequence;input_sha256}

type part = {id:string;owner:Capture.owner;destination:Capture.destination;
  original_batch:Queue.batch;predecessor:string option;through:int}
let part_id (part:part)=part.id
let batch (part:part)=part.original_batch
let destination (part:part)=part.destination
let predecessor (part:part)=part.predecessor
let original_through (part:part)=part.through
let to_json (part:part) : Yojson.Safe.t = `Assoc ["schema",`Int 1;"kind",`String "candidate_part";
  "part_id",`String part.id;"owner",Capture.owner_to_json part.owner;
  "destination",destination_json part.destination;
  "predecessor",optional (fun id -> `String id) part.predecessor;
  "original_through",`Int part.through;
  "candidate_ids",`List (List.map candidate_json (Queue.candidate_ids part.original_batch));
  "batch",Queue.batch_to_json part.original_batch]
let highest batch = List.fold_left (fun highest (row:Queue.candidate) -> max highest row.sequence) 0 (Queue.candidates batch)
let decode_part ~owner json =
  let* f=fields ["schema";"kind";"part_id";"owner";"destination";"predecessor";"original_through";"candidate_ids";"batch"] json in
  let* version=integer (value "schema" f) in let* kind=text (value "kind" f) in
  let* ()=require (version=1 && kind="candidate_part") "Unknown original candidate part" in
  let* id=text (value "part_id" f) in let* ()=Capture.owner_matches_json owner (value "owner" f) in
  let* destination=destination_of_json (value "destination" f) in
  let* predecessor=option text (value "predecessor" f) in let* through=integer (value "original_through" f) in
  let* ids=list candidate_of_json (value "candidate_ids" f) in
  let* original_batch=Queue.batch_of_json ~expected_candidate_ids:ids (value "batch" f) in
  let* ()=require (through>=highest original_batch && through>0) "Original candidate bound precedes its rows" in
  let part={id;owner;destination;original_batch;predecessor;through} in
  let+ ()=equal json (to_json part) "Noncanonical original candidate part" in part
let check_record ~scope ~id ~destination (record:Owner.retained) =
  require (record.scope=scope && record.request_id=id && record.installation_id=destination.Capture.installation_id
    && record.package_id=destination.package_id && record.tool=destination.tool) "Original part differs from retained owner binding"
let decode_record ~owner (record:Owner.retained) =
  let* part=decode_part ~owner record.request in
  let* ()=check_record ~scope:(scope owner) ~id:part.id ~destination:part.destination record in
  let+ ()=require (Progress.events record.progress=[]) "Immutable candidate part has execution progress" in part

type proof_source = Exact_source of string | Gate_source of {execution_id:string;gate_request_id:string}
let source_json (source:proof_source) : Yojson.Safe.t = match source with
  | Exact_source execution_id -> `Assoc ["kind",`String "exact";"execution_id",`String execution_id]
  | Gate_source {execution_id;gate_request_id} -> `Assoc ["kind",`String "gate";
      "execution_id",`String execution_id;"gate_request_id",`String gate_request_id]
let source_of_json json =
  let* header=match json with `Assoc f -> Ok f | _ -> Error "Original size source is not object" in
  let* kind=match List.assoc_opt "kind" header with Some json -> text json | None -> Error "Missing original size source" in
  match kind with
  | "exact" -> let* f=fields ["kind";"execution_id"] json in let+ id=text (value "execution_id" f) in Exact_source id
  | "gate" -> let* f=fields ["kind";"execution_id";"gate_request_id"] json in
    let* execution_id=text (value "execution_id" f) in let+ gate_request_id=text (value "gate_request_id" f) in
    Gate_source {execution_id;gate_request_id}
  | _ -> Error "Unknown original size proof source"
type size_evidence = {parent_id:string;source:proof_source;proof:Yojson.Safe.t}
type partition_record = {id:string;parent_id:string;left:part;right:part;evidence:size_evidence;record:Owner.retained}
type inventory = {parts:part list;partitions:partition_record list}
type gate_restore = parent_execution:Capture.t -> gate_request_id:string -> (Gate.run_result,string) result
type admit = destination:Capture.destination -> publish:(unit -> (unit,string) result) -> (unit,string) result
let find inventory ~part_id = match List.find_opt (fun (part:part) -> part.id=part_id) inventory.parts with
  | Some part -> Ok part | None -> Error "Original candidate part is missing"
let find_partition inventory id = match List.find_opt (fun (p:partition_record) -> p.id=id) inventory.partitions with
  | Some part -> Ok part | None -> Error "Original predecessor partition is missing"
let acknowledged (partition:partition_record) = match Progress.phase partition.record.progress with
  | Progress.Finished _ -> true
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false
let rec eligible inventory visited (part:part) =
  let* ()=require (not (List.mem part.id visited)) "Original candidate ancestry contains a cycle" in
  match part.predecessor with
  | None -> Ok ()
  | Some id ->
    let* partition=find_partition inventory id in
    let* ()=require (acknowledged partition) "Original candidate partition is not acknowledged" in
    let* parent=find inventory ~part_id:partition.parent_id in eligible inventory (part.id::visited) parent
let load_parent inventory ~request_id =
  let* part=find inventory ~part_id:request_id in let+ ()=eligible inventory [] part in part.original_batch
let root_order (a:part) (b:part) =
  match Queue.candidate_ids a.original_batch,Queue.candidate_ids b.original_batch with
  | first_a::_,first_b::_ ->
    let generation=String.compare first_a.queue_generation first_b.queue_generation in
    if generation<>0 then generation else let seq=Int.compare first_a.sequence first_b.sequence in
    if seq<>0 then seq else String.compare a.id b.id
  | [],[] -> String.compare a.id b.id | [],_::_ -> -1 | _::_,[] -> 1
let roots inventory = List.filter (fun (part:part) -> part.predecessor=None) inventory.parts |> List.sort root_order
let runnable inventory =
  let rec walk (part:part) =
    match List.find_opt (fun (p:partition_record) -> p.parent_id=part.id) inventory.partitions with
    | None -> [part]
    | Some p when acknowledged p -> walk p.left @ walk p.right
    | Some _ -> [] in
  List.concat_map walk (roots inventory)
let declaration_id (destination:Capture.destination) =
  let* installation=Owner.installation_of_id destination.installation_id in
  match installation with Owner.Configuration id -> Ok id | Owner.Manual _ -> Error "Original size proof has manual destination"
let original_execution ~store ~owner ~inventory ~(parent:part) execution_id =
  let* current=find inventory ~part_id:parent.id in
  let* ()=equal (to_json current) (to_json parent) "Original size-evidence parent changed" in
  let* ()=Capture.owner_matches_json owner (Capture.owner_to_json parent.owner) in
  let* original=Owner.load ~store ~scope:(Capture.scope owner) ~request_id:execution_id |> owner_error in
  let* original=match original with Some original -> Ok original | None -> Error "Original parent execution is missing" in
  let* capture=Capture.restore ~owner ~load_parent:(load_parent inventory) original in
  let* ()=require (Capture.parent_part_id capture=parent.id) "Size proof belongs to another candidate part" in
  let* ()=equal (destination_json (Capture.destination capture)) (destination_json parent.destination) "Size proof destination differs" in
  let* request=Capture.request capture in
  let* schema=match request.Exact.schema with Some schema -> Ok schema | None -> Error "Original Librarian execution schema missing" in
  let* declaration_id=declaration_id (Capture.destination capture) in
  let* latest=Exact.read_latest_original_execution ~store ~declaration_id ~schema request in
  let* ordinal,execution=match latest with
    | Exact.No_completed_latest -> Error "Original latest execution proof is incomplete"
    | Exact.Completed_latest {attempt_ordinal;execution} -> Ok (attempt_ordinal,execution) in
  Ok (capture,request,schema,ordinal,execution)
let check_size ~store ~owner ~inventory ~(parent:part) ~restore_gate source =
  let execution_id=match source with Exact_source id -> id | Gate_source {execution_id;_} -> execution_id in
  let* capture,request,schema,ordinal,(execution:Exact.execution_result)=original_execution ~store ~owner ~inventory ~parent execution_id in
  let* outcome=match source,execution.outcome with
    | Exact_source _,Exact.Call_ended (Exact.Input_refused (Input_capacity | Context_overflow | Request_body_refused) as final) ->
      let failure=Keeper_exact_walk_receipt.failure_evidence execution.receipt in
      let+ ()=require (Keeper_exact_walk_failure.refuses_input_capacity failure
        && not failure.size_independent_execution_failure && not failure.invalid_output)
        "Original Exact walk is not a pure named input-capacity refusal" in
      Exact.final_to_json (Exact.Call_final final)
    | Gate_source {gate_request_id;_},Exact.Call_ended (Exact.Answered {output;_}) ->
      let* proposal=Capture.validate_proposal capture (Exact.checked_json output) in
      let* ()=match proposal with Keeper_librarian_runtime.Accepted _ -> Ok ()
        | Deferred -> Error "Deferred original execution cannot authorize gate subdivision" in
      let* result=restore_gate ~parent_execution:capture ~gate_request_id in
      let+ ()=require (Gate.failure_kind result=Some Gate.Input_capacity_exceeded)
        "Original gate did not refuse input capacity" in Gate.run_result_to_yojson result
    | (Exact_source _ | Gate_source _),
      (Exact.Call_ended (Answered _ | Invalid_output _
          | Input_refused (Input_capacity | Context_overflow | Invalid_request | Request_body_refused)
          | Output_limit_reached _)
       | Exact.Call_refused _) -> Error "Original execution does not prove the requested size-only subdivision"
  in
  let proof=`Assoc ["source",source_json source;"request_digest",`String (Exact.digest request);
    "schema",schema;"attempt_ordinal",`Int ordinal;
    "receipt",Keeper_exact_walk_receipt.to_json execution.receipt;"outcome",outcome] in
  Ok {parent_id=parent.id;source;proof}
let execution_size_evidence ~store ~owner ~inventory ~parent ~execution_id =
  check_size ~store ~owner ~inventory ~parent
    ~restore_gate:(fun ~parent_execution:_ ~gate_request_id:_ -> Error "Gate source not supplied") (Exact_source execution_id)
let gate_size_evidence ~store ~owner ~inventory ~parent ~execution_id ~gate_request_id ~restore_gate =
  check_size ~store ~owner ~inventory ~parent ~restore_gate (Gate_source {execution_id;gate_request_id})
let partition_json ~owner ~id ~parent_id ~(left:part) ~(right:part) ~(evidence:size_evidence) : Yojson.Safe.t =
  `Assoc ["schema",`Int 1;"kind",`String "two_child_partition";"partition_id",`String id;
    "owner",Capture.owner_to_json owner;"parent_part_id",`String parent_id;
    "source",source_json evidence.source;"proof",evidence.proof;"left",to_json left;"right",to_json right]
let change (partition:partition_record) : Progress.change =
  {before=`Assoc ["parent_part_id",`String partition.parent_id;"children",`List []];
   after=`Assoc ["parent_part_id",`String partition.parent_id;"children",`List [to_json partition.left;to_json partition.right]]}
let transaction_events (partition:partition_record) =
  [Progress.Dispatch_intended;Progress.Judgment_retained partition.evidence.proof;
   Progress.Commit_intended (change partition);Progress.Commit_observed (change partition).after]
let check_transaction (partition:partition_record) =
  let actual=Progress.events partition.record.progress in
  let expected=transaction_events partition in
  (* Compare each event by folding its complete original prefix. This checks
     every payload with the same generic closed transition codec. *)
  let rec folded actual expected left right = match actual,expected with
    | [],_ -> Ok ()
    | a::rest,b::tail ->
      let* left=Progress.append left a in let* right=Progress.append right b in
      let* ()=equal (Progress.to_json left) (Progress.to_json right) "Original partition progress differs from full intent" in
      folded rest tail left right
    | _::_,[] -> Error "Unexpected original partition progress" in
  folded actual expected Progress.captured Progress.captured
let decode_partition ~owner (record:Owner.retained) =
  let* f=fields ["schema";"kind";"partition_id";"owner";"parent_part_id";"source";"proof";"left";"right"] record.request in
  let* schema=integer (value "schema" f) in let* kind=text (value "kind" f) in
  let* ()=require (schema=1 && kind="two_child_partition") "Unknown original partition" in
  let* id=text (value "partition_id" f) in let* parent_id=text (value "parent_part_id" f) in
  let* ()=Capture.owner_matches_json owner (value "owner" f) in
  let* source=source_of_json (value "source" f) in
  let* left=decode_part ~owner (value "left" f) in let* right=decode_part ~owner (value "right" f) in
  let evidence={parent_id;source;proof=value "proof" f} in
  let partition={id;parent_id;left;right;evidence;record} in
  let* ()=check_record ~scope:(partition_scope owner) ~id ~destination:left.destination record in
  let* ()=equal record.request (partition_json ~owner ~id ~parent_id ~left ~right ~evidence) "Noncanonical original partition" in
  let+ ()=check_transaction partition in partition
let sequence results = List.fold_right (fun result tail -> let* value=result in let+ tail=tail in value::tail) results (Ok [])
let check_children (parent:part) (partition:partition_record) =
  let* ()=require (parent.id<>partition.left.id && parent.id<>partition.right.id
    && partition.left.id<>partition.right.id && partition.id<>parent.id
    && partition.id<>partition.left.id && partition.id<>partition.right.id
    && partition.left.predecessor=Some partition.id && partition.right.predecessor=Some partition.id
    && partition.left.through=parent.through && partition.right.through=parent.through)
    "Invalid original partition child ownership" in
  let* expected_left,expected_right=match Queue.split parent.original_batch with
    | Some pair -> Ok pair | None -> Error "Singleton original part cannot split" in
  let* ()=equal (destination_json parent.destination) (destination_json partition.left.destination) "Left child destination changed" in
  let* ()=equal (destination_json parent.destination) (destination_json partition.right.destination) "Right child destination changed" in
  let* ()=equal (Queue.batch_to_json expected_left) (Queue.batch_to_json partition.left.original_batch) "Left child is not original ordered split" in
  equal (Queue.batch_to_json expected_right) (Queue.batch_to_json partition.right.original_batch) "Right child is not original ordered split"
let validate_forest ~store ~owner ~restore_gate inventory =
  let* ()=List.map (fun (partition:partition_record) ->
    let* parent=find inventory ~part_id:partition.parent_id in
    let* ()=eligible inventory [] parent in
    let* ()=check_children parent partition in
    let* actual=check_size ~store ~owner ~inventory ~parent ~restore_gate partition.evidence.source in
    let* ()=equal actual.proof partition.evidence.proof "Original subdivision proof changed" in
    let* ()=List.map (fun (expected:part) -> match List.find_opt (fun (p:part) -> p.id=expected.id) inventory.parts with
      | None -> require (not (acknowledged partition)) "Acknowledged original partition child is missing"
      | Some actual ->
        let* ()=require (List.length (Progress.events partition.record.progress)>=3)
          "Original child exists before its full commit intent" in
        equal (to_json actual) (to_json expected) "Original partition child changed")
      [partition.left;partition.right] |> sequence |> Result.map (fun _ -> ()) in Ok ()) inventory.partitions |> sequence |> Result.map (fun _ -> ()) in
  let* ()=List.map (fun (part:part) -> match part.predecessor with
    | None -> require (part.through=highest part.original_batch) "Root candidate bound changed"
    | Some id ->
      let* partition=find_partition inventory id in
      require (part.id=partition.left.id || part.id=partition.right.id) "Child is not owned by original predecessor") inventory.parts
    |> sequence |> Result.map (fun _ -> ()) in
  let parent_ids=List.map (fun (p:partition_record) -> p.parent_id) inventory.partitions in
  let child_ids=List.concat_map (fun (p:partition_record) -> [p.left.id;p.right.id]) inventory.partitions in
  let execution_ids=List.map (fun (p:partition_record) -> match p.evidence.source with Exact_source id -> id | Gate_source {execution_id;_} -> execution_id) inventory.partitions in
  let unique values = List.length values=List.length (List.sort_uniq String.compare values) in
  let* ()=require (unique parent_ids && unique child_ids && unique execution_ids) "Multiple original partitions claim one parent, execution or child" in
  let all_ids=List.map (fun (p:part) -> p.id) inventory.parts @ List.map (fun (p:partition_record) -> p.id) inventory.partitions in
  let* ()=require (unique all_ids) "Original part and transaction identities collide" in
  let rec root_ids seen = function
    | [] -> Ok ()
    | (part:part)::rest ->
      let ids=Queue.candidate_ids part.original_batch in
      let conflict (id:Current.explicit_candidate_id) = List.exists (fun (old:Current.explicit_candidate_id) ->
        old.queue_generation=id.queue_generation && (old.request_id=id.request_id || old.sequence=id.sequence)) seen in
      let* ()=require (not (List.exists conflict ids)) "Original roots overlap candidate ownership" in
      root_ids (ids@seen) rest in
  root_ids [] (roots inventory)
let check_current_owner owner =
  let* current=Capture.observe_owner ~base_path:(Capture.base_path owner)
    ~keepers_dir:(Capture.keepers_dir owner) ~keeper_id:(Capture.keeper_id owner) in
  Capture.owner_matches_json current (Capture.owner_to_json owner)
let discover ~store ~owner ~restore_gate =
  let* ()=check_current_owner owner in
  let* raw_parts=Owner.discover ~store ~scope:(scope owner) |> owner_error in
  let* parts=List.map (decode_record ~owner) raw_parts |> sequence in
  let* raw_partitions=Owner.discover ~store ~scope:(partition_scope owner) |> owner_error in
  let* partitions=List.map (decode_partition ~owner) raw_partitions |> sequence in
  let inventory={parts;partitions} in
  let+ ()=validate_forest ~store ~owner ~restore_gate inventory in inventory
let retain_part ~store (part:part) = Owner.retain ~store ~scope:(scope part.owner) ~request_id:part.id
  ~installation_id:part.destination.installation_id ~package_id:part.destination.package_id
  ~tool:part.destination.tool ~request:(to_json part) |> owner_error
let admitted_publish ~destination ~admit publish =
  let published=ref false in
  let* ()=admit ~destination ~publish:(fun () -> let+ ()=publish () in published:=true) in
  require !published "Fresh original Runtime admission did not publish the original record"
let retain_root ~store ~owner ~restore_gate ~part_id ~destination ~batch ~admit =
  let* inventory=discover ~store ~owner ~restore_gate in
  let part={id=part_id;owner;destination;original_batch=batch;predecessor=None;through=highest batch} in
  let* part=decode_part ~owner (to_json part) in
  let prospective=match List.find_opt (fun (p:part) -> p.id=part.id) inventory.parts with
    | None -> Ok {inventory with parts=part::inventory.parts}
    | Some existing -> let+ ()=equal (to_json existing) (to_json part) "Original root ID was reused" in inventory in
  let* prospective=prospective in let* ()=validate_forest ~store ~owner ~restore_gate prospective in
  let* ()=admitted_publish ~destination ~admit (fun () -> retain_part ~store part) in
  let* fresh=discover ~store ~owner ~restore_gate in find fresh ~part_id
let advance ~store record event =
  let* result=Owner.advance ~store ~expected:record ~event |> update_error in
  match result with
  | Owner.Stored record | Already_stored record -> Ok record
  | Unconfirmed detail -> Error ("Original partition publication unconfirmed: " ^ detail)
let resume_partition ~store ~owner (partition:partition_record) =
  let expected=transaction_events partition in
  let rec advance_prefix record events = match events with
    | [] -> Ok record
    | event::rest -> let* record=advance ~store record event in advance_prefix record rest in
  if acknowledged partition then Ok () else
  let actual=List.length (Progress.events partition.record.progress) in
  let* intent=advance_prefix partition.record (List.take (3-actual) (List.drop actual expected)) in
  let* ()=retain_part ~store partition.left in
  let* ()=retain_part ~store partition.right in
  let* ()=List.map (fun (expected:part) ->
    let* raw=Owner.load ~store ~scope:(scope owner) ~request_id:expected.id |> owner_error in
    let* raw=match raw with Some raw -> Ok raw | None -> Error "Original partition child publication unconfirmed" in
    let* actual=decode_record ~owner raw in equal (to_json actual) (to_json expected) "Original partition child differs")
    [partition.left;partition.right] |> sequence |> Result.map (fun _ -> ()) in
  let+ _=advance ~store intent (Progress.Commit_observed (change partition).after) in ()
let recover_partitions ~store ~owner ~restore_gate =
  let* inventory=discover ~store ~owner ~restore_gate in
  let rec resume = function
    | [] -> Ok ()
    | original::rest -> let* ()=resume_partition ~store ~owner original in resume rest in
  let* ()=resume inventory.partitions in
  discover ~store ~owner ~restore_gate
let partition ~store ~owner ~restore_gate ~(parent:part) ~(evidence:size_evidence) ~partition_id ~left_id ~right_id ~admit =
  let* inventory=discover ~store ~owner ~restore_gate in
  let* actual_parent=find inventory ~part_id:parent.id in
  let* ()=equal (to_json actual_parent) (to_json parent) "Original subdivision parent changed" in
  let* ()=eligible inventory [] parent in
  let* ()=require (evidence.parent_id=parent.id) "Size proof belongs to another parent" in
  let* fresh_evidence=check_size ~store ~owner ~inventory ~parent ~restore_gate evidence.source in
  let* ()=equal evidence.proof fresh_evidence.proof "Original size proof changed before partition" in
  let* left_batch,right_batch=match Queue.split parent.original_batch with
    | Some pair -> Ok pair | None -> Error "Singleton original part cannot split" in
  let* _=text (`String partition_id) in
  let* left=decode_part ~owner (to_json {parent with id=left_id;original_batch=left_batch;predecessor=Some partition_id}) in
  let* right=decode_part ~owner (to_json {parent with id=right_id;original_batch=right_batch;predecessor=Some partition_id}) in
  let request=partition_json ~owner ~id:partition_id ~parent_id:parent.id ~left ~right ~evidence in
  let* ()=require (not (List.exists (fun (p:partition_record) -> p.parent_id=parent.id) inventory.partitions))
    "Original parent already has a partition; recover its same transaction" in
  let* ()=require (not (List.exists (fun (p:part) -> List.mem p.id [partition_id;left_id;right_id]) inventory.parts)
    && not (List.exists (fun (p:partition_record) -> List.mem p.id [partition_id;left_id;right_id]) inventory.partitions))
    "New original child or partition identity already exists" in
  let* ()=require (left_id<>right_id && partition_id<>left_id && partition_id<>right_id) "Original partition IDs collide" in
  let* ()=admitted_publish ~destination:parent.destination ~admit (fun () ->
    Owner.retain ~store ~scope:(partition_scope owner) ~request_id:partition_id
      ~installation_id:parent.destination.installation_id ~package_id:parent.destination.package_id
      ~tool:parent.destination.tool ~request |> owner_error) in
  let* recovered=recover_partitions ~store ~owner ~restore_gate in
  let* left=find recovered ~part_id:left_id in let+ right=find recovered ~part_id:right_id in left,right

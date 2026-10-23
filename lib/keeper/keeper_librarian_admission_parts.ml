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
  Capture.scope_hash (Capture.scope_identity owner)
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

type terminal_source =
  | Original_execution of {part_id:string;execution_id:string}
  | Original_gate of {part_id:string;execution_id:string;gate_request_id:string}
type memory_basis = {revision:int option;snapshot_sha256:string option;facts:Keeper_memory_os_types.fact list}
type terminal_witness = {reference:terminal_source;evidence:Yojson.Safe.t}
type supersession_proof = {predecessors:string list;frontier:terminal_witness list;
  pending:Queue.batch;memory:memory_basis;committed:Current.explicit_candidate_id list}
let terminal_json (source:terminal_source) : Yojson.Safe.t = match source with
  | Original_execution {part_id;execution_id} -> `Assoc ["kind",`String "execution";
      "part_id",`String part_id;"execution_id",`String execution_id]
  | Original_gate {part_id;execution_id;gate_request_id} -> `Assoc ["kind",`String "gate";
      "part_id",`String part_id;"execution_id",`String execution_id;"gate_request_id",`String gate_request_id]
let terminal_of_json json =
  let* header=match json with `Assoc fields -> Ok fields | _ -> Error "Terminal reference is not an object" in
  let* kind=match List.assoc_opt "kind" header with Some json -> text json | None -> Error "Terminal reference kind missing" in
  match kind with
  | "execution" -> let* f=fields ["kind";"part_id";"execution_id"] json in
    let* part_id=text (value "part_id" f) in let+ execution_id=text (value "execution_id" f) in
    Original_execution {part_id;execution_id}
  | "gate" -> let* f=fields ["kind";"part_id";"execution_id";"gate_request_id"] json in
    let* part_id=text (value "part_id" f) in let* execution_id=text (value "execution_id" f) in
    let+ gate_request_id=text (value "gate_request_id" f) in Original_gate {part_id;execution_id;gate_request_id}
  | _ -> Error "Unknown terminal frontier reference"
let terminal_part = function Original_execution {part_id;_} | Original_gate {part_id;_} -> part_id
let facts_json facts = `List (List.map Keeper_memory_os_types.fact_to_json facts)
let memory_json (memory:memory_basis) : Yojson.Safe.t = `Assoc [
  "revision",optional (fun n -> `Int n) memory.revision;
  "snapshot_sha256",optional (fun hash -> `String hash) memory.snapshot_sha256;
  "facts",facts_json memory.facts]
let memory_of_json json =
  let* f=fields ["revision";"snapshot_sha256";"facts"] json in
  let* revision=option integer (value "revision" f) in
  let* snapshot_sha256=option text (value "snapshot_sha256" f) in
  let* facts=list (fun json -> Keeper_memory_os_types.fact_of_json json
    |> Result.map_error Keeper_memory_os_types.wire_error_to_string) (value "facts" f) in
  let* ()=match revision,snapshot_sha256 with
    | None,None -> require (facts=[]) "Absent original Memory has facts"
    | Some revision,Some hash -> require (revision>=0 && String_util.is_lowercase_sha256_hex hash)
        "Invalid original Memory snapshot identity"
    | None,Some _ | Some _,None -> Error "Incomplete original Memory snapshot identity" in
  let ids=List.map Keeper_memory_os_types.memory_id facts in
  let* ()=require (List.length ids=List.length (List.sort_uniq String.compare ids)) "Duplicate original current Memory identity" in
  let memory={revision;snapshot_sha256;facts} in
  let+ ()=equal json (memory_json memory) "Noncanonical original Memory basis" in memory
let batch_digest batch = Lane_addon_store.digest (Yojson.Safe.to_string (ordered (Queue.batch_to_json batch)))
let supersession_json (proof:supersession_proof) : Yojson.Safe.t = `Assoc ["version",`Int 1;
  "predecessor_roots",`List (List.map (fun id -> `String id) proof.predecessors);
  "frontier",`List (List.map (fun (witness:terminal_witness) -> `Assoc [
      "source",terminal_json witness.reference;"evidence",witness.evidence]) proof.frontier);
  "pending_digest",`String (batch_digest proof.pending);"memory",memory_json proof.memory;
  "committed_candidates",`List (List.map candidate_json proof.committed)]
let supersession_of_json ~pending json =
  let* f=fields ["version";"predecessor_roots";"frontier";"pending_digest";"memory";"committed_candidates"] json in
  let* ()=require (value "version" f=`Int 1) "Unknown frontier replacement version" in
  let* predecessors=list text (value "predecessor_roots" f) in
  let* ()=require (predecessors<>[] && predecessors=List.sort_uniq String.compare predecessors)
    "Original predecessor roots are empty, repeated or unordered" in
  let* frontier=list (fun json -> let* f=fields ["source";"evidence"] json in
    let+ reference=terminal_of_json (value "source" f) in {reference;evidence=value "evidence" f}) (value "frontier" f) in
  let* digest=text (value "pending_digest" f) in
  let* ()=require (digest=batch_digest pending) "Frontier replacement batch changed" in
  let* memory=memory_of_json (value "memory" f) in
  let* committed=list candidate_of_json (value "committed_candidates" f) in
  let proof={predecessors;frontier;pending;memory;committed} in
  let+ ()=equal json (supersession_json proof) "Noncanonical original frontier replacement" in proof

type part = {id:string;owner:Capture.owner;destination:Capture.destination;
  original_batch:Queue.batch;predecessor:string option;through:int;supersession:supersession_proof option}
let part_id (part:part)=part.id
let batch (part:part)=part.original_batch
let destination (part:part)=part.destination
let predecessor (part:part)=part.predecessor
let original_through (part:part)=part.through
let to_json (part:part) : Yojson.Safe.t = `Assoc ["schema",`Int 1;"kind",`String "candidate_part";
  "part_id",`String part.id;"owner",Capture.owner_to_json part.owner;
  "destination",destination_json part.destination;
  "predecessor",optional (fun id -> `String id) part.predecessor;
  "original_through",`Int part.through;"supersession",optional supersession_json part.supersession;
  "candidate_ids",`List (List.map candidate_json (Queue.candidate_ids part.original_batch));
  "batch",Queue.batch_to_json part.original_batch]
let highest batch = List.fold_left (fun highest (row:Queue.candidate) -> max highest row.sequence) 0 (Queue.candidates batch)
let decode_part ~owner json =
  let* f=fields ["schema";"kind";"part_id";"owner";"destination";"predecessor";"original_through";"supersession";"candidate_ids";"batch"] json in
  let* version=integer (value "schema" f) in let* kind=text (value "kind" f) in
  let* ()=require (version=1 && kind="candidate_part") "Unknown original candidate part" in
  let* id=text (value "part_id" f) in let* ()=Capture.owner_matches_json owner (value "owner" f) in
  let* destination=destination_of_json (value "destination" f) in
  let* predecessor=option text (value "predecessor" f) in let* through=integer (value "original_through" f) in
  let* ids=list candidate_of_json (value "candidate_ids" f) in
  let* original_batch=Queue.batch_of_json ~expected_candidate_ids:ids (value "batch" f) in
  let* ()=require (through>=highest original_batch && through>0) "Original candidate bound precedes its rows" in
  let* supersession=option (supersession_of_json ~pending:original_batch) (value "supersession" f) in
  let* ()=require (predecessor=None || supersession=None) "A partition child cannot supersede original roots" in
  let part={id;owner;destination;original_batch;predecessor;through;supersession} in
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
let all_roots inventory = List.filter (fun (part:part) -> part.predecessor=None) inventory.parts |> List.sort root_order
let roots inventory =
  let obsolete=List.concat_map (fun (part:part) -> match part.supersession with
    | None -> [] | Some proof -> proof.predecessors) (all_roots inventory) in
  List.filter (fun (part:part) -> not (List.mem part.id obsolete)) (all_roots inventory)
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
let original_capture ~store ~owner ~inventory ~(parent:part) execution_id =
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
  let+ declaration_id=declaration_id (Capture.destination capture) in
  original,capture,request,schema,declaration_id
let original_execution ~store ~owner ~inventory ~parent execution_id =
  let* _original,capture,request,schema,declaration_id=original_capture ~store ~owner ~inventory ~parent execution_id in
  let* latest=Exact.read_latest_original_execution ~store ~declaration_id ~schema request in
  let* ordinal,execution=match latest with
    | Exact.No_completed_latest -> Error "Original latest execution proof is incomplete"
    | Exact.Completed_latest {attempt_ordinal;execution} -> Ok (attempt_ordinal,execution) in
  let* ()=match execution.Exact.outcome with
    | Exact.Call_ended final -> Capture.confirm_final ~store capture (Exact.Call_final final)
    | Call_refused _ -> Error "Original refused execution cannot prove an admission terminal" in
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
let rec traverse f = function
  | [] -> Ok []
  | first::rest -> let* value=f first in let+ rest=traverse f rest in value::rest
let leaves_of_roots inventory root_parts =
  let rec walk (part:part) =
    match List.find_opt (fun (partition:partition_record) -> partition.parent_id=part.id) inventory.partitions with
    | None -> Ok [part]
    | Some partition ->
      let* ()=require (acknowledged partition) "Pending original partition cannot be superseded" in
      let* left=walk partition.left in let+ right=walk partition.right in left@right in
  let+ parts=traverse walk root_parts in List.concat parts
let original_facts capture = match (Capture.input capture).Keeper_librarian.current with
  | None -> [] | Some current -> current.facts
let commit_json (commit:Progress.commit) = `Assoc ["judgment",commit.judgment;
  "before",commit.change.before;"after",commit.change.after]
let original_judgment (record:Owner.retained) = match Progress.phase record.progress with
  | Progress.Judged judgment -> Some judgment
  | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) -> Some commit.judgment
  | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ -> None
let answered_original ~store ~owner ~inventory ~parent execution_id =
  let* record,capture,request,schema,declaration_id=original_capture ~store ~owner ~inventory ~parent execution_id in
  let* latest=Exact.read_latest_original_execution ~store ~declaration_id ~schema request in
  let* final,authority=match latest with
    | Exact.No_completed_latest -> Error "Original terminal judgment has no completed latest host proof"
    | Completed_latest {attempt_ordinal;execution={outcome=Exact.Call_ended call_final;receipt}} ->
      let final=Exact.Call_final call_final in
      let* ()=Capture.confirm_final ~store capture final in
      let* ()=match original_judgment record with
        | None -> Ok ()
        | Some raw -> equal raw (Exact.final_to_json final) "Original judgment differs from confirmed host execution" in
      Ok (final,`Assoc ["kind",`String "host_execution";"attempt_ordinal",`Int attempt_ordinal;
        "receipt",Keeper_exact_walk_receipt.to_json receipt;"final",Exact.final_to_json final])
    | Completed_latest {execution={outcome=Exact.Call_refused _;_};_} ->
      Error "Ordinary provider failure is not a terminal frontier" in
  match final with
  | Exact.Call_final (Answered {output;_}) ->
    let+ proposal=Capture.validate_proposal capture (Exact.checked_json output) in
    record,capture,proposal,authority
  | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
  | Outcome_unknown | Not_allowed _ | Request_id_reused -> Error "Original frontier requires a completed semantic answer"
let terminal_witness ~store ~owner ~inventory ~restore_gate ~committed reference =
  let id=terminal_part reference in
  let* parent=find inventory ~part_id:id in
  let* ()=eligible inventory [] parent in
  let singleton=List.length (Queue.candidates parent.original_batch)=1 in
  let* capture,kind,authority=match reference with
    | Original_gate {execution_id;gate_request_id;_} ->
      let* ()=require singleton "Only an indivisible gate-capacity frontier may be replaced" in
      let* evidence=gate_size_evidence ~store ~owner ~inventory ~parent ~execution_id ~gate_request_id ~restore_gate in
      let+ _record,capture,_request,_schema,_declaration=original_capture ~store ~owner ~inventory ~parent execution_id in
      capture,"singleton_capacity",evidence.proof
    | Original_execution {execution_id;_} ->
      let* _record,capture,request,schema,declaration_id=original_capture ~store ~owner ~inventory ~parent execution_id in
      let* latest=Exact.read_latest_original_execution ~store ~declaration_id ~schema request in
      (match latest with
       | Exact.Completed_latest {execution={outcome=Exact.Call_ended (Input_refused _);_};_} ->
         let* ()=require singleton "A divisible size frontier must retain its original two-child partition" in
         let+ evidence=execution_size_evidence ~store ~owner ~inventory ~parent ~execution_id in
         capture,"singleton_capacity",evidence.proof
       | Completed_latest {execution={outcome=Call_ended (Answered _ | Invalid_output _ | Output_limit_reached _)
           | Call_refused _;_};_} | No_completed_latest ->
         let* record,capture,proposal,authority=answered_original ~store ~owner ~inventory ~parent execution_id in
         match proposal with
         | Keeper_librarian_runtime.Deferred -> Ok (capture,"semantic_deferred",authority)
         | Accepted accepted ->
           let* commit=match Progress.phase record.progress with
             | Progress.Finished commit -> Ok commit
             | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
             | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
               Error "Accepted original work has not completed its Memory transaction" in
           let* ()=require (accepted.explicit_candidate_ids<>[] &&
             List.for_all (fun id -> List.mem id committed) accepted.explicit_candidate_ids)
             "Finished original admission has no exact committed candidate proof" in
           Ok (capture,"committed_frontier",`Assoc ["answer",authority;"commit",commit_json commit;
             "accepted_candidates",`List (List.map candidate_json accepted.explicit_candidate_ids)])) in
  let evidence=`Assoc ["kind",`String kind;
    "capture_digest",`String (Lane_addon_store.digest (Yojson.Safe.to_string (ordered (Capture.to_json capture))));
    "original_revision",optional (fun n -> `Int n) (Capture.expected_revision capture);
    "original_facts",facts_json (original_facts capture);"authority",authority] in
  Ok ({reference;evidence},capture)
let root_candidates root_parts = List.concat_map (fun (part:part) -> Queue.candidate_ids part.original_batch) root_parts
let candidate_collision (a:Current.explicit_candidate_id) (b:Current.explicit_candidate_id) =
  a.queue_generation=b.queue_generation && (a.request_id=b.request_id || a.sequence=b.sequence)
let read_committed ~owner ids =
  let generations=List.map (fun (id:Current.explicit_candidate_id) -> id.queue_generation) ids |> List.sort_uniq String.compare in
  let* all=traverse (fun queue_generation -> Current.committed_explicit_candidates
    ~keepers_dir:(Capture.keepers_dir owner) ~keeper_id:(Capture.keeper_id owner) ~queue_generation) generations in
  let all=List.concat all in
  let* ()=require (not (List.exists (fun original -> List.exists
    (fun actual -> candidate_collision original actual && original<>actual) all) ids))
    "Current candidate receipt conflicts with original frontier identity" in
  Ok (List.filter (fun id -> List.mem id all) ids)
let read_memory owner : (memory_basis,string) result =
  let+ snapshot=Current.read_with_snapshot_sha256 ~keepers_dir:(Capture.keepers_dir owner) ~keeper_id:(Capture.keeper_id owner) in
  match snapshot with
  | None -> {revision=None;snapshot_sha256=None;facts=[]}
  | Some ((snapshot:Current.t),hash) -> {revision=Some snapshot.revision;snapshot_sha256=Some hash;facts=snapshot.facts}
let check_pending owner expected =
  let* pending=Queue.read_pending ~keepers_dir:(Capture.keepers_dir owner) ~keeper_id:(Capture.keeper_id owner) in
  match pending with
  | None -> Error "Current pending batch is absent"
  | Some pending -> equal (Queue.batch_to_json pending) (Queue.batch_to_json expected) "Current full pending batch differs from captured replacement"
let frontier_ids frontier = List.map (fun (witness:terminal_witness) -> terminal_part witness.reference) frontier
type reconsideration = Changed_frontier | Unchanged_frontier
let check_replacement ~store ~owner ~restore_gate ~inventory (proof:supersession_proof) =
  let* predecessors=traverse (fun id -> let* part=find inventory ~part_id:id in
    let+ ()=require (part.predecessor=None) "Frontier predecessor is not an original root" in part) proof.predecessors in
  let predecessors=List.sort root_order predecessors in
  let* leaves=leaves_of_roots inventory predecessors in
  let expected_ids=List.map (fun (part:part) -> part.id) leaves in
  let* ()=require (frontier_ids proof.frontier=expected_ids) "Replacement does not retain the entire original ordered frontier" in
  let ids=root_candidates predecessors in
  let* ()=require (List.for_all (fun id -> List.mem id ids) proof.committed &&
    List.length proof.committed=List.length (List.sort_uniq Stdlib.compare proof.committed))
    "Replacement has unrelated or duplicate committed candidate identities" in
  let* ()=require (proof.committed=List.filter (fun id -> List.mem id proof.committed) ids)
    "Original committed frontier identities are out of order" in
  let* actual_committed=read_committed ~owner proof.committed in
  let* ()=require (actual_committed=proof.committed) "Original committed frontier proof is no longer authoritative" in
  let new_ids=Queue.candidate_ids proof.pending in
  let* ()=require (not (List.exists (fun id -> List.mem id proof.committed) new_ids))
    "Committed old input is still present in the replacement pending batch; finish ACK first" in
  let* ()=require (List.for_all (fun id -> List.mem id new_ids || List.mem id proof.committed) ids)
    "Original uncommitted frontier gaps were lost from the replacement input" in
  let through=List.fold_left (fun n (part:part) -> max n part.through) 0 predecessors in
  let fresh=List.filter (fun id -> not (List.mem id ids)) new_ids in
  let* ()=require (List.for_all (fun (id:Current.explicit_candidate_id) -> id.sequence>through &&
    not (List.exists (candidate_collision id) ids)) fresh) "Replacement introduces reused or non-tail input" in
  let new_tail=fresh<>[] in
  let* eligible=traverse (fun (witness:terminal_witness) ->
    let* actual,capture=terminal_witness ~store ~owner ~inventory ~restore_gate ~committed:proof.committed witness.reference in
    let* ()=equal actual.evidence witness.evidence "Original terminal frontier evidence changed" in
    let* part=find inventory ~part_id:(terminal_part witness.reference) in
    let has_gap=List.exists (fun id -> not (List.mem id proof.committed)) (Queue.candidate_ids part.original_batch) in
    let+ unchanged=same (facts_json proof.memory.facts) (facts_json (original_facts capture)) in
    not has_gap || new_tail || not unchanged) proof.frontier in
  let+ ()=require (new_tail || List.exists (fun id -> List.mem id new_ids) ids)
    "Replacement contains no pending original gap or actual new tail" in
  if List.for_all Fun.id eligible then Changed_frontier else Unchanged_frontier
let validate_replacement ~store ~owner ~restore_gate ~inventory proof =
  let* result=check_replacement ~store ~owner ~restore_gate ~inventory proof in
  match result with
  | Changed_frontier -> Ok ()
  | Unchanged_frontier -> Error "Unchanged terminal input and Memory context cannot mint a new root"
let validate_root_lineage inventory =
  let all=all_roots inventory in
  let root id = match List.find_opt (fun (part:part) -> part.id=id) all with
    | Some root -> Ok root | None -> Error "Superseded original root is missing" in
  let predecessor_ids=List.concat_map (fun (part:part) -> match part.supersession with None -> [] | Some proof -> proof.predecessors) all in
  let* ()=require (List.length predecessor_ids=List.length (List.sort_uniq String.compare predecessor_ids))
    "Two replacement roots claim the same original frontier" in
  let rec ancestors visiting (part:part) =
    let* ()=require (not (List.mem part.id visiting)) "Original root replacement contains a cycle" in
    match part.supersession with
    | None -> Ok []
    | Some proof ->
      let* nested=traverse (fun id -> let* predecessor=root id in
        let+ prior=ancestors (part.id::visiting) predecessor in id::prior) proof.predecessors in
      Ok (List.concat nested) in
  let* lineage=traverse (fun (part:part) -> let+ prior=ancestors [] part in part,prior) all in
  let rec pairs = function
    | [] -> Ok ()
    | ((part:part),prior)::rest ->
      let* _=traverse (fun ((other:part),other_prior) ->
        let left=Queue.candidate_ids part.original_batch and right=Queue.candidate_ids other.original_batch in
        let collisions=List.concat_map (fun id -> List.filter (candidate_collision id) right |> List.map (fun other -> id,other)) left in
        let* ()=require (List.for_all (fun (a,b) -> a=b) collisions) "Historical root candidate identity was reused" in
        require (collisions=[] || List.mem other.id prior || List.mem part.id other_prior)
          "Overlapping roots have no original terminal supersession lineage") rest in pairs rest in
  pairs lineage
let validate_execution_inventory ~store ~owner inventory =
  let* records=Owner.load_scope ~store ~scope:(Capture.scope owner) |> owner_error in
  let* captures=traverse (Capture.restore ~owner ~load_parent:(load_parent inventory)) records in
  let parents=List.map Capture.parent_part_id captures in
  require (List.length parents=List.length (List.sort_uniq String.compare parents))
    "Multiple original executions claim the same immutable candidate part"
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
  let* ()=validate_root_lineage inventory in
  let* ()=validate_execution_inventory ~store ~owner inventory in
  let* _=traverse (fun (part:part) -> match part.supersession with
    | None -> Ok ()
    | Some proof -> validate_replacement ~store ~owner ~restore_gate ~inventory proof) (all_roots inventory) in
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
  let* raw_parts=Owner.load_scope ~store ~scope:(scope owner) |> owner_error in
  let* parts=List.map (decode_record ~owner) raw_parts |> sequence in
  let* raw_partitions=Owner.load_scope ~store ~scope:(partition_scope owner) |> owner_error in
  let* partitions=List.map (decode_partition ~owner) raw_partitions |> sequence in
  let inventory={parts;partitions} in
  let+ ()=validate_forest ~store ~owner ~restore_gate inventory in inventory
let retain_part ~store (part:part) = Owner.retain ~store ~scope:(scope part.owner) ~request_id:part.id
  ~installation_id:part.destination.installation_id ~package_id:part.destination.package_id
  ~tool:part.destination.tool ~summary:`Null ~request:(to_json part) |> owner_error
let admitted_publish ~destination ~admit publish =
  let published=ref false in
  let* ()=admit ~destination ~publish:(fun () -> let+ ()=publish () in published:=true) in
  require !published "Fresh original Runtime admission did not publish the original record"
let live_supersession ~owner ~inventory (proof:supersession_proof) =
  let active=roots inventory in
  let active_ids=List.map (fun (part:part) -> part.id) active |> List.sort String.compare in
  let* ()=require (active_ids=proof.predecessors) "Original active frontier changed before replacement publication" in
  let* ()=check_pending owner proof.pending in
  let* memory=read_memory owner in
  let* ()=equal (memory_json memory) (memory_json proof.memory) "Current Memory changed before replacement publication" in
  let ids=root_candidates active in
  let pending_ids=Queue.candidate_ids proof.pending in
  let* receipts=read_committed ~owner (ids@pending_ids) in
  let* ()=require (not (List.exists (fun id -> List.mem id receipts) pending_ids))
    "Current pending input already has a commit receipt; finish original queue ACK first" in
  equal (`List (List.map candidate_json proof.committed))
    (`List (List.map candidate_json (List.filter (fun id -> List.mem id receipts) ids)))
    "Current committed frontier evidence changed"
let prove_supersession ~store ~owner ~restore_gate ~inventory ~batch ~frontier =
  let* fresh=discover ~store ~owner ~restore_gate in
  let active=roots fresh in
  let* ()=require (active<>[] && List.map (fun (p:part) -> p.id) active=
    List.map (fun (p:part) -> p.id) (roots inventory)) "Original active roots changed or are absent" in
  let* leaves=leaves_of_roots fresh active in
  let* ()=require (List.map terminal_part frontier=List.map (fun (p:part) -> p.id) leaves)
    "Replacement references must name every original active leaf in traversal order" in
  let* ()=check_pending owner batch in
  let* memory=read_memory owner in
  let* committed=read_committed ~owner (root_candidates active) in
  let* witnesses=traverse (fun reference -> let+ witness,_capture=
    terminal_witness ~store ~owner ~inventory:fresh ~restore_gate ~committed reference in witness) frontier in
  let proof={predecessors=List.map (fun (p:part) -> p.id) active |> List.sort String.compare;
    frontier=witnesses;pending=batch;memory;committed} in
  let* qualification=check_replacement ~store ~owner ~restore_gate ~inventory:fresh proof in
  let+ ()=live_supersession ~owner ~inventory:fresh proof in
  match qualification with Changed_frontier -> Some proof | Unchanged_frontier -> None
let retain_root ~store ~owner ~restore_gate ?supersession ~part_id ~destination ~batch ~admit () =
  let* inventory=discover ~store ~owner ~restore_gate in
  let part={id=part_id;owner;destination;original_batch=batch;predecessor=None;through=highest batch;supersession} in
  let* part=decode_part ~owner (to_json part) in
  match List.find_opt (fun (p:part) -> p.id=part.id) inventory.parts with
  | Some existing ->
    let+ ()=equal (to_json existing) (to_json part) "Original root ID was reused" in existing
  | None ->
    let live () =
      let* ()=check_current_owner owner in
      match supersession with
      | Some proof ->
        let* ()=validate_replacement ~store ~owner ~restore_gate ~inventory proof in
        live_supersession ~owner ~inventory proof
      | None ->
        let* ()=require (roots inventory=[]) "A new root must explicitly supersede the original terminal frontier" in
        let* ()=check_pending owner batch in
        let* committed=read_committed ~owner (Queue.candidate_ids batch) in
        require (committed=[]) "Initial pending input already has a commit receipt; finish queue ACK first" in
    let* ()=live () in
    let prospective={inventory with parts=part::inventory.parts} in
    let* ()=validate_forest ~store ~owner ~restore_gate prospective in
    let* ()=admitted_publish ~destination ~admit (fun () -> let* ()=live () in retain_part ~store part) in
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
  let* ()=require (List.exists (fun (part:part) -> part.id=parent.id) (runnable inventory))
    "Superseded or non-runnable history cannot publish a new partition" in
  let* ()=require (evidence.parent_id=parent.id) "Size proof belongs to another parent" in
  let* fresh_evidence=check_size ~store ~owner ~inventory ~parent ~restore_gate evidence.source in
  let* ()=equal evidence.proof fresh_evidence.proof "Original size proof changed before partition" in
  let* left_batch,right_batch=match Queue.split parent.original_batch with
    | Some pair -> Ok pair | None -> Error "Singleton original part cannot split" in
  let* _=text (`String partition_id) in
  let* left=decode_part ~owner (to_json {parent with id=left_id;original_batch=left_batch;predecessor=Some partition_id;supersession=None}) in
  let* right=decode_part ~owner (to_json {parent with id=right_id;original_batch=right_batch;predecessor=Some partition_id;supersession=None}) in
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
      ~tool:parent.destination.tool ~summary:`Null ~request |> owner_error) in
  let* recovered=recover_partitions ~store ~owner ~restore_gate in
  let* left=find recovered ~part_id:left_id in let+ right=find recovered ~part_id:right_id in left,right

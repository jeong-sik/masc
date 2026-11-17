module Request = Keeper_librarian_durable_request
module Source = Keeper_librarian_durable_capture
module Lock = Keeper_librarian_durable_source_lock
module Owner = Lane_addon_tool_request_owner
module Current = Keeper_memory_os_current
module Memory = Keeper_memory_os_current_types
module Publication = Keeper_memory_os_program_publication
module Codec = Keeper_memory_os_current_range_codec
module Step = Keeper_librarian_floor_step_request
module Steps = Keeper_librarian_floor_step_owner
module Runtime = Keeper_librarian_runtime
module Cursor = Keeper_external_read_cursor
module Atom = Keeper_librarian_progress
module Official = Keeper_librarian_official_progress
module Json = Candle_json
open Result.Syntax

let require condition detail = if condition then Ok () else Error detail
let hash json =
  let* value=Json.as_string json in
  let+ ()=require (String_util.is_lowercase_sha256_hex value) "Invalid program settlement digest" in value
let integer = function
  | `Int value when value>=0 -> Ok value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
    Error "Invalid program settlement integer"
let atom_of_json json = Atom.of_json json |> Result.map_error Keeper_memory_os_types.wire_error_to_string
let official_of_json json = Official.of_json json |> Result.map_error Keeper_memory_os_types.wire_error_to_string

type retained = {
  request_id:string;request_digest:string;owner:Request.owner;source_basis_digest:string;
  first_step_id:string;first_step_digest:string;anchor:Current.program_anchor_evidence;
  publication:Keeper_memory_os_program_types.publication;snapshot_revision:int;snapshot_sha256:string;
  receipts:Memory.durable_range_receipt list;external_through:int;external_ack:Cursor.observation;
  atom_position:Atom.t option;official_position:Official.t option;
}
let nullable encode = Option.fold ~none:`Null ~some:encode
let retained_to_json proof = `Assoc [
  "kind",`String "ordered_program";
  "request_id",`String proof.request_id;"request_digest",`String proof.request_digest;
  "owner",Request.owner_to_json proof.owner;"source_basis_digest",`String proof.source_basis_digest;
  "first_step_id",`String proof.first_step_id;"first_step_digest",`String proof.first_step_digest;
  "anchor",Current.program_anchor_evidence_to_json proof.anchor;
  "publication",Publication.to_json proof.publication;
  "snapshot_revision",`Int proof.snapshot_revision;"snapshot_sha256",`String proof.snapshot_sha256;
  "receipts",`List (List.map Codec.durable_range_receipt_to_json proof.receipts);
  "external_through",`Int proof.external_through;"external_ack",Cursor.observation_to_json proof.external_ack;
  "atom_position",nullable Atom.to_json proof.atom_position;
  "official_position",nullable Official.to_json proof.official_position]

let atom_target (range:Current.durable_range_id) =
  {Atom.position={trace_id=range.trace_id;end_atom=range.end_atom;last_atom_digest=range.last_atom_digest};
    boundary_lines_seen=range.boundary_lines_seen}
let official_target (range:Current.official_range_id) =
  {Official.boundary_line=List.fold_left (fun last (line,_) -> max last line)
    range.after_boundary_line range.turns}
let receipt_ranges ~snapshot_revision ~snapshot_sha256 receipts =
  let rec collect values = function
    | [] -> Ok (List.rev values)
    | Memory.Committed receipt::rest ->
      let* ()=require (receipt.snapshot_revision=snapshot_revision && receipt.snapshot_sha256=snapshot_sha256)
        "Program settlement receipts name another snapshot" in
      collect (receipt.range_id::values) rest
    | Prepared _::_ -> Error "Program settlement contains a pending receipt" in
  collect [] receipts
let validate_retained proof =
  let program=proof.publication.execution.program in
  let* scope=Request.scope_of_request_id proof.request_id in
  let* step_scope=Step.scope_of_request_id proof.first_step_id in
  let* ()=require (scope=Request.scope proof.owner && step_scope=Step.scope proof.owner
    && Keeper_identity.Keeper_id.to_string program.keeper_id=Request.keeper_id proof.owner)
    "Program settlement belongs to another original owner" in
  let prior=Option.fold ~none:0 ~some:fst proof.publication.locked_prior.snapshot in
  let* ()=require (program.sources<>[] && program.unread=[] && proof.snapshot_revision=prior+1)
    "Program settlement is not a complete original transaction" in
  let* ()=Current.program_anchor_evidence_matches_publication proof.anchor proof.publication in
  let* ranges=receipt_ranges ~snapshot_revision:proof.snapshot_revision ~snapshot_sha256:proof.snapshot_sha256 proof.receipts in
  let* ()=Publication.require_receipt_ranges proof.publication ranges in
  let* ()=require (Cursor.observation_matches_preparation proof.external_ack
    ~after:proof.external_through ~through:proof.external_through ~atom:None ~official:None)
    "Program settlement external ACK is unconfirmed" in
  List.fold_left (fun result -> function
    | Memory.Atom_range range -> let* ()=result in
      require (range.unread_messages=[] && proof.atom_position=Some (atom_target range))
        "Program settlement atom position is unconfirmed"
    | Official_range range -> let* ()=result in
      require (range.unread_messages=[] && proof.official_position=Some (official_target range))
        "Program settlement official position is unconfirmed"
    | Explicit_candidate _ | Explicit_candidate_with_recall _ -> Error "Program settlement is not a history range")
    (Ok ()) ranges
let retained_of_json json =
  let context="history ordered-program settlement" in
  let* fields=Json.object_fields ~context json in
  let* kind,fields=Json.field ~context "kind" Json.as_string fields in
  let* ()=require (kind="ordered_program") "Unknown history program settlement" in
  let* request_id,fields=Json.field ~context "request_id" Json.as_non_blank fields in
  let* request_digest,fields=Json.field ~context "request_digest" hash fields in
  let* owner,fields=Json.field ~context "owner" Request.owner_of_json fields in
  let* source_basis_digest,fields=Json.field ~context "source_basis_digest" hash fields in
  let* first_step_id,fields=Json.field ~context "first_step_id" Json.as_non_blank fields in
  let* first_step_digest,fields=Json.field ~context "first_step_digest" hash fields in
  let* anchor,fields=Json.field ~context "anchor" Current.program_anchor_evidence_of_json fields in
  let* publication,fields=Json.field ~context "publication" Publication.of_json fields in
  let* snapshot_revision,fields=Json.field ~context "snapshot_revision" integer fields in
  let* snapshot_sha256,fields=Json.field ~context "snapshot_sha256" hash fields in
  let* receipts,fields=Json.field ~context "receipts" (Json.as_list (fun json ->
    Codec.durable_range_receipt_of_json json |> Result.map_error Keeper_memory_os_types.wire_error_to_string)) fields in
  let* external_through,fields=Json.field ~context "external_through" integer fields in
  let* external_ack,fields=Json.field ~context "external_ack" Cursor.observation_of_json fields in
  let* atom_position,fields=Json.field ~context "atom_position" (Json.as_nullable atom_of_json) fields in
  let* official_position,fields=Json.field ~context "official_position" (Json.as_nullable official_of_json) fields in
  let* ()=Json.finish ~context fields in
  let proof={request_id;request_digest;owner;source_basis_digest;first_step_id;first_step_digest;anchor;
    publication;snapshot_revision;snapshot_sha256;receipts;external_through;external_ack;atom_position;official_position} in
  let+ ()=validate_retained proof in proof

type t = {store:Lane_addon_store.t;request:Request.t;record:Owner.retained;
  program:Current.committed_program;retained:retained}
let request proof=proof.request
let program proof=proof.program
let retained proof=proof.retained

let first_basis ~store request =
  let owner=Request.physical_owner request in
  let* source_basis_digest=Request.source_basis_digest request in
  let identity={Runtime.request_id=Request.request_id request;request_digest=Request.body_digest request;
    source_basis_digest} in
  let* found=Steps.discover ~store ~owner |> Result.map_error Steps.error_to_string in
  let matching=List.filter (fun (_, (index:Step.index)) ->
    index.header.range.request_id=identity.request_id) found in
  let* ()=require (List.for_all (fun (_, (index:Step.index)) ->
    index.header.range.request_digest=identity.request_digest && index.header.retained_source=Some identity) matching)
    "Program original has a different retained source or preparation mode" in
  let* selected=match List.filter (fun (_, (index:Step.index)) -> index.header.position=0) matching with
    | [first] -> Ok first
    | [] | _::_ -> Error "Program has no unique retained first question" in
  let* record,_=Steps.load ~store selected |> Result.map_error Steps.error_to_string in
  let* step=Step.restore ~owner record in
  let* ()=require (Step.physical_owner step=owner && Lane_addon_captured_destination.same_semantic
    (Step.destination step) (Request.destination request)) "Program first question changed its original destination" in
  let* ()=Runtime.validate_retained_durable_step ~source:identity
    ~original:(Request.preparation request) (Step.step step) in
  let+ basis=Option.to_result ~none:"Program first question has no original anchor and full manifest" (Step.chain_basis step) in
  step,basis,record.request_digest
let exact_ranges request (program:Current.committed_program) =
  let source=Request.source request in
  let expected=Option.to_list (Option.map (fun range -> Memory.Atom_range range) (Source.range_id source))
    @ Option.to_list (Option.map (fun range -> Memory.Official_range range) (Source.official_range_id source)) in
  let* actual=receipt_ranges ~snapshot_revision:program.snapshot_revision ~snapshot_sha256:program.snapshot_sha256 program.receipts in
  require (expected<>[] && List.length expected=List.length actual
    && List.for_all (fun range -> List.mem range actual) expected)
    "Program receipts differ from the full original source"
let observe_locked ~store ~request ~(record:Owner.retained) ~(program:Current.committed_program) =
  let owner=Request.physical_owner request and source=Request.source request in
  let* ()=Request.confirm_record request record in
  let* actual=Owner.load ~store ~scope:record.scope ~request_id:record.request_id
    |> Result.map_error Owner.error_to_string in
  let* actual=Option.to_result ~none:"Program original is no longer retained" actual in
  let* ()=Request.confirm_record request actual in
  let* ()=require (Yojson.Safe.equal (Owner.record_to_json (Owner.listed actual))
    (Owner.record_to_json (Owner.listed record))) "Program original progress changed before settlement observation" in
  let* ()=require (program.keepers_dir=Request.keepers_dir owner && program.keeper_id=Request.keeper_id owner)
    "Program publication belongs to another physical Memory owner" in
  let* ()=Current.confirm_committed_program program in
  let* all_receipts=Keeper_librarian_durable_receipts.state request in
  let* ()=require all_receipts "Program full original receipts are absent" in
  let* ()=exact_ranges request program in
  let* first,basis,first_step_digest=first_basis ~store request in
  let execution=program.publication.execution.program in
  let* ()=require (execution.transaction_id=Step.transaction_id first
    && execution.sources=basis.Step.sources && execution.unread=[]
    && execution.keeper_id=(Source.input source).keeper_id
    && execution.initial_current=Option.map (fun (current:Keeper_librarian.current_selection) -> current.facts)
      (Step.step first).preparation.source_input.current
    && Ids.Turn_ref.equal execution.turn_ref (Source.input source).turn_ref)
    "Program transaction or complete first-step manifest differs" in
  let* ()=Current.program_anchor_evidence_matches_publication basis.anchor program.publication in
  let runtime_keepers_dir=Source.runtime_keepers_dir source and keeper_id=Request.keeper_id owner in
  let* external_ack=Cursor.observe ~runtime_keepers_dir ~keeper_name:keeper_id in
  let external_through=Keeper_librarian_input_sources.external_through (Source.counterparts source) in
  let* atom_position=Atom.read ~keepers_dir:runtime_keepers_dir ~keeper_id |> Result.map_error Atom.read_error_to_string in
  let* official_position=Official.read ~keepers_dir:runtime_keepers_dir ~keeper_id |> Result.map_error Official.read_error_to_string in
  let positions=Source.positions source in
  let atom=Option.fold ~none:positions.current ~some:(fun range -> Some (atom_target range)) (Source.range_id source) in
  let official=Option.fold ~none:positions.official ~some:(fun range -> Some (official_target range)) (Source.official_range_id source) in
  let* ()=require (atom_position=atom && official_position=official)
    "Program original read positions have not completed their exact ACK" in
  let* source_basis_digest=Request.source_basis_digest request in
  let retained={request_id=Request.request_id request;request_digest=Request.body_digest request;owner;
    source_basis_digest;first_step_id=Step.request_id first;first_step_digest;
    anchor=basis.anchor;publication=program.publication;snapshot_revision=program.snapshot_revision;
    snapshot_sha256=program.snapshot_sha256;receipts=program.receipts;external_through;external_ack;atom_position;official_position} in
  let* ()=validate_retained retained in
  let+ ()=Current.confirm_committed_program program in {store;request;record=actual;program;retained}
let observe ~store ~request ~record ~program =
  Lock.with_original_settlement ~request (fun () -> observe_locked ~store ~request ~record ~program)
let recheck proof =
  let* actual=observe ~store:proof.store ~request:proof.request ~record:proof.record ~program:proof.program in
  require (Yojson.Safe.equal (retained_to_json actual.retained) (retained_to_json proof.retained))
    "Program source settlement evidence changed before retention"

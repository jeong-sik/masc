module Owner = Lane_addon_tool_request_owner
module Admission = Keeper_librarian_admission_capture
module Parts = Keeper_librarian_admission_parts
module History = Keeper_librarian_durable_request
module Floor = Keeper_librarian_floor_step_request
open Result.Syntax

type purpose = Admission_execution | Admission_part | Admission_partition
  | History_execution | Floor_execution | Admission_gate | History_gate | Floor_gate

(* These are host-owned Store protocol namespaces, not model text or live
   ownership. The complete decoder below verifies the exact captured scope. *)
let purpose scope =
  List.find_map (fun (prefix,purpose) ->
    if String.starts_with ~prefix scope then Some purpose else None)
    ["keeper-librarian-admission-gate/",Admission_gate;
     "keeper-librarian-durable-gate/",History_gate;
     "keeper-librarian-floor-step-gate/",Floor_gate;
     "keeper-librarian-execution-",Admission_execution;
     "keeper-librarian-history-execution-",History_execution;
     "keeper-librarian-floor-step-",Floor_execution;
     "keeper-librarian-parts/",Admission_part;
     "keeper-librarian-partitions/",Admission_partition]

let owner_json (record:Owner.retained) = match record.request with
  | `Assoc fields -> Option.to_result ~none:"Original Librarian payload has no captured owner"
      (List.assoc_opt "owner" fields)
  | _ -> Error "Original Librarian payload is not an object"
let admission_owner record = let* json=owner_json record in Admission.owner_of_json json
let history_owner record = let* json=owner_json record in History.owner_of_json json
let parent ~read ~scope ~request_id =
  let* record=read ~scope ~request_id in
  Option.to_result ~none:("Original Librarian source parent is absent: " ^ request_id) record
let admission_capture ~read ~owner record =
  Admission.restore ~owner ~load_parent:(Parts.load_parent_payload ~read ~owner) record

let validate ~read ~read_body (record:Owner.retained) =
  match purpose record.scope with
  | None -> Ok ()
  | Some Admission_execution ->
    let* owner=admission_owner record in
    let* capture=admission_capture ~read ~owner record in
    Keeper_librarian_admission_gate.validate_preparation_payload ~read ~read_body ~owner ~capture ~parent:record
  | Some Admission_part ->
    let* owner=admission_owner record in Parts.validate_part_payload ~owner record
  | Some Admission_partition ->
    let* owner=admission_owner record in Parts.validate_partition_payload ~owner record
  | Some History_execution ->
    let* owner=history_owner record in
    let* capture=History.restore_payload ~owner record in
    Keeper_librarian_durable_gate.validate_preparation_payload ~read ~read_body ~owner ~capture ~parent:record
  | Some Floor_execution ->
    let* owner=history_owner record in
    let* capture=Floor.restore ~owner record in
    Keeper_librarian_floor_step_gate.validate_preparation_payload ~read ~read_body ~owner ~capture ~parent:record
  | Some Admission_gate ->
    let module Gate=Keeper_librarian_admission_gate in
    let* request_id=Gate.parent_execution_id record in
    let* owner=admission_owner record in
    let* parent=parent ~read ~scope:(Admission.scope owner) ~request_id in
    let* capture=admission_capture ~read ~owner parent in
    Gate.validate_payload ~read ~read_body ~owner ~capture ~parent ~record
  | Some History_gate ->
    let module Gate=Keeper_librarian_durable_gate in
    let* request_id=Gate.parent_execution_id record in
    let* owner=history_owner record in
    let* parent=parent ~read ~scope:(History.scope owner) ~request_id in
    let* capture=History.restore_payload ~owner parent in
    Gate.validate_payload ~read ~read_body ~owner ~capture ~parent ~record
  | Some Floor_gate ->
    let module Gate=Keeper_librarian_floor_step_gate in
    let* request_id=Gate.parent_execution_id record in
    let* owner=history_owner record in
    let* parent=parent ~read ~scope:(Floor.scope owner) ~request_id in
    let* capture=Floor.restore ~owner parent in
    Gate.validate_payload ~read ~read_body ~owner ~capture ~parent ~record

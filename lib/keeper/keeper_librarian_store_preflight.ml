module Owner = Lane_addon_tool_request_owner
module Admission = Keeper_librarian_admission_capture
module Parts = Keeper_librarian_admission_parts
module Closure = Keeper_librarian_admission_closure
module History = Keeper_librarian_durable_request
module Floor = Keeper_librarian_floor_step_request
open Result.Syntax

type purpose = Admission_execution | Admission_part | Admission_partition | Admission_closure
  | History_execution | Floor_execution | Admission_gate | History_gate | Floor_gate

(* Producers own their Store protocol namespaces. Recognition grants no live
   ownership; the complete decoder still checks the exact captured scope. *)
let purpose scope =
  List.find_map (fun (owns,purpose) -> if owns scope then Some purpose else None)
    [Keeper_librarian_admission_gate.is_scope,Admission_gate;
     Keeper_librarian_durable_gate.is_scope,History_gate;
     Keeper_librarian_floor_step_gate.is_scope,Floor_gate;
     Admission.is_scope,Admission_execution;History.is_scope,History_execution;
     Floor.is_scope,Floor_execution;Parts.is_scope,Admission_part;
     Parts.is_partition_scope,Admission_partition;Closure.is_scope,Admission_closure]

let owner_json (record:Owner.retained) = match record.request with
  | `Assoc fields -> Option.to_result ~none:"Original Librarian payload has no captured owner"
      (List.assoc_opt "owner" fields)
  | _ -> Error "Original Librarian payload is not an object"
let admission_owner record = let* json=owner_json record in Admission.owner_of_json json
let history_owner record = let* json=owner_json record in History.owner_of_json json
let parent ~read ~scope ~request_id =
  let* record=read ~scope ~request_id in
  Option.to_result ~none:("Original Librarian source parent is absent: " ^ request_id) record
(* The forest is every part and partition one owner has, read from that
   owner's two whole scopes, and it is the same for each record that names the
   owner. An owner has dozens of such records, so proving it again for each one
   read those scopes dozens of times. A passed proof is kept for the rest of the
   scan. A failed one is not: each record that names the owner proves it again
   and is refused exactly as it was before. *)
let forest_proof () =
  let proved=Hashtbl.create 16 in
  fun ~read_scope ~owner ->
    let key=Yojson.Safe.to_string (Admission.owner_to_json owner) in
    if Hashtbl.mem proved key then Ok ()
    else
      let+ ()=Parts.validate_payload_forest ~read_scope ~owner in
      Hashtbl.replace proved key ()
let history_capture ~read ~read_fence ~read_resolution ~owner (record:Owner.retained) =
  let* capture=History.restore_payload ~owner record in
  let+ ()=Keeper_librarian_history_resolution_lineage.validate_predecessor_payload ~read ~read_fence ~read_resolution
    ~require_confirmed:(Lane_addon_request_progress.events record.progress<>[]) capture in capture
let floor_capture ~read ~owner record =
  let* capture=Floor.restore ~owner record in
  let+ ()=Floor.validate_ancestry_payload ~read capture in capture

let validator () =
  let forest=forest_proof () in
  let admission_capture ~read ~read_scope ~owner record =
    let* ()=forest ~read_scope ~owner in
    Admission.restore ~owner ~load_parent:(Parts.load_parent_payload ~read ~owner) record in
  let validate ~read ~read_scope ~read_body ~read_fence ~read_resolution (record:Owner.retained) =
  match purpose record.scope with
  | None -> Ok ()
  | Some Admission_execution ->
    let* owner=admission_owner record in
    let* capture=admission_capture ~read ~read_scope ~owner record in
    Keeper_librarian_admission_gate.validate_preparation_payload ~read ~read_body ~owner ~capture ~parent:record
  | Some Admission_part ->
    let* owner=admission_owner record in
    let* ()=Parts.validate_part_payload ~owner record in
    forest ~read_scope ~owner
  | Some Admission_partition ->
    let* owner=admission_owner record in
    let* ()=Parts.validate_partition_payload ~owner record in
    forest ~read_scope ~owner
  | Some Admission_closure ->
    let* owner=admission_owner record in
    let+ _=Closure.restore ~owner record in ()
  | Some History_execution ->
    let* owner=history_owner record in
    let* capture=history_capture ~read ~read_fence ~read_resolution ~owner record in
    (* Lineage reads a resolution record only from its child. One with no
       child yet is read here, so a record this build cannot read is refused
       before the server starts and not on the Keeper's first pass. *)
    let* stored=read_resolution ~scope:record.scope ~request_id:record.request_id in
    let* ()=match stored with
      | None -> Ok ()
      | Some stored ->
        Keeper_librarian_history_resolution_intent.decode_published ~scope:record.scope
          ~request_id:record.request_id stored |> Result.map (fun _ -> ()) in
    Keeper_librarian_durable_gate.validate_preparation_payload ~read ~read_body ~owner ~capture ~parent:record
  | Some Floor_execution ->
    let* owner=history_owner record in
    let* capture=floor_capture ~read ~owner record in
    Keeper_librarian_floor_step_gate.validate_preparation_payload ~read ~read_body ~owner ~capture ~parent:record
  | Some Admission_gate ->
    let module Gate=Keeper_librarian_admission_gate in
    let* request_id=Gate.parent_execution_id record in
    let* owner=admission_owner record in
    let* parent=parent ~read ~scope:(Admission.scope owner) ~request_id in
    let* capture=admission_capture ~read ~read_scope ~owner parent in
    Gate.validate_payload ~read ~read_body ~owner ~capture ~parent ~record
  | Some History_gate ->
    let module Gate=Keeper_librarian_durable_gate in
    let* request_id=Gate.parent_execution_id record in
    let* owner=history_owner record in
    let* parent=parent ~read ~scope:(History.scope owner) ~request_id in
    let* capture=history_capture ~read ~read_fence ~read_resolution ~owner parent in
    Gate.validate_payload ~read ~read_body ~owner ~capture ~parent ~record
  | Some Floor_gate ->
    let module Gate=Keeper_librarian_floor_step_gate in
    let* request_id=Gate.parent_execution_id record in
    let* owner=history_owner record in
    let* parent=parent ~read ~scope:(Floor.scope owner) ~request_id in
    let* capture=floor_capture ~read ~owner parent in
    Gate.validate_payload ~read ~read_body ~owner ~capture ~parent ~record
  in
  (* Unlike the immutable forest payload, absence is not stable: a running
     owner can publish its closing journal before the next scanned record. *)
  fun ~read ~read_scope ~read_body ~read_archive ~read_fence ~read_resolution (record:Owner.retained) ->
  match purpose record.scope with
  | None | Some (History_execution | Floor_execution | History_gate | Floor_gate) ->
    validate ~read ~read_scope ~read_body ~read_fence ~read_resolution record
  | Some (Admission_execution | Admission_part | Admission_partition | Admission_gate | Admission_closure) ->
    let* owner=admission_owner record in
    let* view=Closure.project ~owner ~read ~read_scope ~read_body ~read_archive in
    match view.closure with
    | None ->
      validate ~read ~read_scope ~read_body ~read_fence ~read_resolution record
    | Some closure ->
      let* ()=if Closure.is_scope record.scope then
        let current=Closure.record closure in
        if Yojson.Safe.equal (Owner.record_to_json (Owner.listed current))
             (Owner.record_to_json (Owner.listed record)) then Ok ()
        else Error "Admission closure changed during preflight"
        else
          let* current=view.read ~scope:record.scope ~request_id:record.request_id in
          match current with
          | Some current when Yojson.Safe.equal (Owner.record_to_json (Owner.listed current))
              (Owner.record_to_json (Owner.listed record)) -> Ok ()
          | None | Some _ -> Error "Admission closure member changed during preflight" in
      let check=validate ~read:view.read ~read_scope:view.read_scope ~read_body:view.read_body ~read_fence ~read_resolution in
      let* ()=check record in
      if Closure.is_scope record.scope then
        List.fold_left (fun result original -> let* ()=result in check original)
          (Ok ()) view.live_members
      else Ok ()

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

(* The deploy check of a Librarian original's Exact files (RFC
   exact-request-skips-a-slot-that-refused-its-input 3.3, item 5). It refuses
   an original exactly when its consumer stops on the Exact files the Exact
   check leaves, and reads them as that consumer reads them. The validator
   above stays as the runtime runs it. *)
module Preflight = Lane_addon_store_preflight
module Exact = Lane_addon_exact
module Final = Keeper_librarian_original_final
module Progress = Lane_addon_request_progress

(* What the consumer of an original does with its Exact files in its phase
   (the phase table of RFC section 5). *)
type consumer_read =
  | Recover_record
      (* Dispatch_pending: resume recovers the record, asks the worker when it
         finds none or an open one, and confirms the final it finishes with. *)
  | Decode_judgment of Yojson.Safe.t
      (* A phase that holds a judgment: decode_final, then confirm_final. *)
  | Confirm_delivered of Exact.final
      (* An execution refusal: confirm_final of the final its evidence names. *)

let consumer_read ~schema (record:Owner.retained) =
  match Progress.phase record.progress with
  | Progress.Captured | Admission_wait _ -> Ok None
  | Dispatch_pending _ -> Ok (Some Recover_record)
  | Judged judgment -> Ok (Some (Decode_judgment judgment))
  | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) ->
    Ok (Some (Decode_judgment commit.Progress.judgment))
  | Rejected {Progress.stage=Progress.Execution;evidence} ->
    let+ retained=Exact.retained_final_of_json ~schema evidence in
    Some (Confirm_delivered (Exact.delivered retained))
  (* The validators of the consumers end these phases before any Exact read. *)
  | Rejected {Progress.stage=Progress.Before_dispatch;_} | Subdividing _ | Subdivided _ -> Ok None

let observe_files (target:Final.target) (files:Preflight.exact_files) =
  Exact.observe_record ~declaration_id:target.declaration_id ~schema:target.schema target.exact
    files.record
let proof_json (files:Preflight.exact_files) = match files.proof with
  | Preflight.No_proof -> Ok None
  | Proof json -> Ok (Some json)
  | Unreadable_proof detail -> Error detail
let latest_files ~declaration_id ~schema request (files:Preflight.exact_files) =
  let* proof=proof_json files in
  Exact.latest_of_files ~store:files.store ~declaration_id ~schema request ~record:files.record ~proof
let confirm_files ~wording (target:Final.target) (files:Preflight.exact_files) final =
  let* verdict=Final.confirm ~observe:(fun () -> observe_files target files)
      ~latest:(fun () -> latest_files ~declaration_id:target.declaration_id
                  ~schema:target.schema target.exact files) final in
  match verdict with
  | Final.Confirmed -> Ok ()
  | Unconfirmed reason -> Error (wording reason)
(* The host finishes a record before it hands the final to the worker, and
   the worker never offers a finished request again. So a finished record the
   Exact check deletes leaves the consumer a worker final and no record, which
   it confirms only for a final the worker refuses before the host. *)
let recover_files ~wording (target:Final.target) (files:Preflight.exact_files) =
  let* ()=match files.deleted with
    | None | Some Preflight.Deleted_open -> Ok ()
    | Some (Deleted_terminal final) when Exact.refused_before_host final -> Ok ()
    | Some (Deleted_terminal _) ->
      Error "the Exact check deletes the original's finished record, and the consumer \
             finds no record for the final the worker returns"
    | Some Deleted_unknown ->
      Error "the Exact check deletes a record at the original's path that shows no \
             final of this original" in
  let* proof=proof_json files in
  let* record=Exact.recovery_of_files ~store:files.store ~declaration_id:target.declaration_id
      ~schema:target.schema target.exact ~record:files.record ~proof in
  let recovered={files with record} in
  let* observed=observe_files target recovered in
  match observed with
  | Exact.Retained_absent | Retained_open -> Ok ()
  | Retained_terminal retained -> confirm_files ~wording target recovered (Exact.delivered retained)
let judge_files ~wording (target:Final.target) files = function
  | Recover_record -> recover_files ~wording target files
  | Decode_judgment judgment ->
    (* Every consumer's decode_final is Final.decode_final, which confirms a
       recovered final in Final's words; the consumer then confirms the final
       in its own. *)
    let* final=Final.decode ~schema:target.schema ~observe:(fun () -> observe_files target files)
        ~confirm:(confirm_files ~wording:Final.unconfirmed_detail target files) judgment in
    confirm_files ~wording target files final
  | Confirm_delivered final -> confirm_files ~wording target files final
(* A proof link the original's request names while no record of it is left.
   Fresh state deletes it with the owner's scopes. *)
let recordless_proof (target:Final.target) (files:Preflight.exact_files) =
  match files.record,files.proof with
  | None,(Preflight.Proof _ | Unreadable_proof _) ->
    [Exact.Retained_key.proof_path
       (Exact.Retained_key.of_request ~declaration_id:target.declaration_id target.exact)]
  | Some _,_ | None,No_proof -> []

(* One original whose consumer reads its Exact files: its request with the
   declaration and schema, what the consumer does with the files, and the
   words the consumer's confirm_final uses. *)
type exact_original = {target:Final.target;read:consumer_read;wording:Final.unconfirmed -> string}
let installation_id (destination:Lane_addon_captured_destination.t) =
  destination.Lane_addon_captured_destination.installation_id
(* [None] when the consumer reads no Exact file of this original: a manual
   installation names no declaration, and some phases read none. *)
let exact_original ~wording ~installation_id exact (record:Owner.retained) =
  let* installation=Owner.installation_of_id installation_id in
  match installation with
  | Owner.Manual _ -> Ok None
  | Owner.Configuration _ ->
    let* target=Final.target ~installation_id exact in
    let+ read=consumer_read ~schema:target.Final.schema record in
    Option.map (fun read -> {target;read;wording}) read
(* Phase one decodes what the consumer reads, as the consumer decodes it; a
   failure there is a payload the consumer refuses. Phase two reads the Exact
   files. *)
let original_verdict ~(read_exact:Preflight.exact_reader) = function
  | Error detail -> Preflight.Payload_invalid detail
  | Ok (_,None) -> Preflight.Payload_valid
  | Ok (scopes,Some {target;read;wording}) ->
    (match read_exact ~declaration_id:target.Final.declaration_id target.Final.exact with
     | Error detail -> Preflight.Exact_root_differs detail
     | Ok files ->
       (match judge_files ~wording target files read with
        | Ok () -> Preflight.Payload_valid
        | Error detail ->
          Preflight.Consumer_stops_on_exact {detail;scopes;paths=recordless_proof target files}))

let admission_scopes owner =
  [Admission.scope owner;Parts.scope owner;Parts.partition_scope owner;
   Keeper_librarian_admission_gate.scope owner;Closure.scope owner]
let history_scopes owner = [History.scope owner;Keeper_librarian_durable_gate.scope owner]
let floor_scopes owner = [Floor.scope owner;Keeper_librarian_floor_step_gate.scope owner]
let admission_original ~read ~owner record =
  let* capture=Admission.restore ~owner ~load_parent:(Parts.load_parent_payload ~read ~owner) record in
  let* exact=Admission.request capture in
  exact_original ~wording:Admission.unconfirmed_detail
    ~installation_id:(installation_id (Admission.destination capture)) exact record
(* A history original an operator fenced is left out of resume and
   validation, so its consumer reads no Exact file. *)
let history_original ~read_fence ~owner (record:Owner.retained) =
  let* fence=read_fence ~scope:record.scope ~request_id:record.request_id in
  match fence with
  | Some _ -> Ok None
  | None ->
    let* capture=History.restore_payload ~owner record in
    let* exact=History.request capture in
    exact_original ~wording:Final.unconfirmed_detail
      ~installation_id:(installation_id (History.destination capture)) exact record
let floor_original ~owner record =
  let* step=Floor.restore ~owner record in
  let* exact=Floor.request step in
  exact_original ~wording:Final.unconfirmed_detail
    ~installation_id:(installation_id (Floor.destination step)) exact record

(* The forest of each owner, read once for the scan by the first record that
   needs it. A check that fails reads it again before it refuses: a part or
   partition published after the first read belongs to the forest the
   consumer reads. *)
let forest_reads () =
  let read=Hashtbl.create 16 in
  fun ~again ~read_scope ~owner ->
    let key=Yojson.Safe.to_string (Admission.owner_to_json owner) in
    match Hashtbl.find_opt read key with
    | Some inventory when not again -> Ok inventory
    | Some _ | None ->
      let+ inventory=Parts.payload_inventory ~read_scope ~owner in
      Hashtbl.replace read key inventory;
      inventory
(* Discovery's checks of a partition and of a replacing root reach several
   executions through these reads. A read that finds a proof naming another
   store root stops the scan, whatever the comparison made of it. *)
let forest_verdict ~forest ~read ~read_scope ~(read_exact:Preflight.exact_reader) ~owner ~scopes check record =
  let root=ref None in
  let read_exact ~declaration_id request =
    let files=read_exact ~declaration_id request in
    Result.iter_error (fun detail -> root:=Some detail) files;
    files in
  let reads={Parts.load=(fun ~request_id -> read ~scope:(Admission.scope owner) ~request_id);
    read_latest=(fun ~declaration_id ~schema request ->
      let* files=read_exact ~declaration_id request in
      latest_files ~declaration_id ~schema request files);
    confirm=(fun capture final ->
      let* exact=Admission.request capture in
      let* target=Final.target ~installation_id:(installation_id (Admission.destination capture)) exact in
      let* files=read_exact ~declaration_id:target.Final.declaration_id target.Final.exact in
      confirm_files ~wording:Admission.unconfirmed_detail target files final)} in
  let checked ~again = check ~reads ~owner ~inventory:(fun () -> forest ~again ~read_scope ~owner) record in
  let outcome=match checked ~again:false with
    | Ok () -> Ok ()
    | Error _ -> checked ~again:true in
  match !root,outcome with
  | Some detail,_ -> Preflight.Exact_root_differs detail
  | None,Ok () -> Preflight.Payload_valid
  | None,Error detail -> Preflight.Consumer_stops_on_exact {detail;scopes;paths=[]}
(* Closing and Closed closures settle their members without discovery, so no
   consumer reads a member's Exact files. The closure is read only for a
   record the check would refuse: it reads members with the live ports, which
   a closing member's moved parents no longer answer. *)
let admission_verdict ~read ~read_scope ~read_body ~read_archive (record:Owner.retained) verdict =
  match admission_owner record with
  | Error detail -> Preflight.Payload_invalid detail
  | Ok owner ->
    match verdict ~owner ~scopes:(admission_scopes owner) with
    | (Preflight.Payload_valid | Exact_root_differs _) as kept -> kept
    | (Payload_invalid _ | Consumer_stops_on_exact _) as refused ->
      match Closure.project ~owner ~read ~read_scope ~read_body ~read_archive with
      | Error detail -> Preflight.Payload_invalid detail
      | Ok view ->
        match Option.map Closure.stage view.closure with
        | Some (Closure.Closing | Closure.Closed) -> Preflight.Payload_valid
        | None | Some Closure.Captured -> refused

let exact_check () =
  let forest=forest_reads () in
  fun ~read ~read_scope ~read_body ~read_archive ~read_fence ~read_exact (record:Owner.retained) ->
  let admission=admission_verdict ~read ~read_scope ~read_body ~read_archive record in
  let forest_check check ~owner ~scopes =
    forest_verdict ~forest ~read ~read_scope ~read_exact ~owner ~scopes check record in
  match purpose record.scope with
  | None | Some Admission_closure -> Preflight.Payload_valid
  | Some Admission_execution ->
    admission (fun ~owner ~scopes ->
      original_verdict ~read_exact
        (let+ original=admission_original ~read ~owner record in scopes,original))
  | Some Admission_gate ->
    admission (fun ~owner ~scopes ->
      original_verdict ~read_exact
        (let* request_id=Keeper_librarian_admission_gate.parent_execution_id record in
         let* parent=parent ~read ~scope:(Admission.scope owner) ~request_id in
         let+ original=admission_original ~read ~owner parent in scopes,original))
  | Some Admission_part -> admission (forest_check Parts.check_frontier_evidence)
  | Some Admission_partition -> admission (forest_check Parts.check_partition_proof)
  | Some History_execution ->
    original_verdict ~read_exact
      (let* owner=history_owner record in
       let+ original=history_original ~read_fence ~owner record in history_scopes owner,original)
  | Some History_gate ->
    original_verdict ~read_exact
      (let* request_id=Keeper_librarian_durable_gate.parent_execution_id record in
       let* owner=history_owner record in
       let* parent=parent ~read ~scope:(History.scope owner) ~request_id in
       let+ original=history_original ~read_fence ~owner parent in history_scopes owner,original)
  | Some Floor_execution ->
    original_verdict ~read_exact
      (let* owner=history_owner record in
       let+ original=floor_original ~owner record in floor_scopes owner,original)
  | Some Floor_gate ->
    original_verdict ~read_exact
      (let* request_id=Keeper_librarian_floor_step_gate.parent_execution_id record in
       let* owner=history_owner record in
       let* parent=parent ~read ~scope:(Floor.scope owner) ~request_id in
       let+ original=floor_original ~owner parent in floor_scopes owner,original)

let preflight () =
  let validate=validator () and exact=exact_check () in
  fun ~read ~read_scope ~read_body ~read_archive ~read_fence ~read_resolution ~read_exact
    (record:Owner.retained) ->
  match validate ~read ~read_scope ~read_body ~read_archive ~read_fence ~read_resolution record with
  | Error detail -> Preflight.Payload_invalid detail
  | Ok () -> exact ~read ~read_scope ~read_body ~read_archive ~read_fence ~read_exact record

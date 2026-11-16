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
let admission_key owner = Yojson.Safe.to_string (Admission.owner_to_json owner)
let history_key owner = Yojson.Safe.to_string (History.owner_to_json owner)
let parent ~read ~scope ~request_id =
  let* record=read ~scope ~request_id in
  Option.to_result ~none:("Original Librarian source parent is absent: " ^ request_id) record
(* Values derived from what one scope of the scan reads. The scan meets a
   scope's records together, and its reader gives back the record it read
   before for bytes that did not change. A value derived from a record is
   used again while the scan stays in the scope and the record reads the
   same. Only that record is compared: the parts, predecessors, fences and
   Exact files read to derive the value are not read again, as the check is
   not a snapshot. Moving to another scope drops them: the next scope's
   reader reads every record anew. *)
let per_scope fresh =
  let current=ref None in
  fun scope -> match !current with
    | Some (seen,values) when String.equal seen scope -> values
    | Some _ | None -> let values=fresh () in current:=Some (scope,values); values
(* The forest is every part and partition one owner has, read from that
   owner's two whole scopes, and it is the same for each record that names the
   owner. An owner has dozens of such records, so proving it again for each one
   read those scopes dozens of times. A passed proof is kept for the rest of the
   scan. A failed one is not: each record that names the owner proves it again
   and is refused exactly as it was before. *)
let forest_proof () =
  let proved=Hashtbl.create 16 in
  fun ~read_scope ~owner ->
    let key=admission_key owner in
    if Hashtbl.mem proved key then Ok ()
    else
      let+ ()=Parts.validate_payload_forest ~read_scope ~owner in
      Hashtbl.replace proved key ()
let history_capture ~indexes ~read ~read_fence ~read_resolution ~owner (record:Owner.retained) =
  let* capture=History.restore_payload ~owner record in
  let+ ()=Keeper_librarian_history_resolution_lineage.validate_predecessor_payload ~indexes ~read ~read_fence ~read_resolution
    ~require_confirmed:(Lane_addon_request_progress.events record.progress<>[]) capture in capture
let floor_capture ~read ~owner record =
  let* capture=Floor.restore ~owner record in
  let+ ()=Floor.validate_ancestry_payload ~read capture in capture

(* What one scope's gate records proved about the executions they name. A
   journal's records all name one execution, and restoring its capture and
   proving its ancestry for each record did that dozens of times. A passed
   capture is kept while the reader returns the same execution record. The
   chains proved from that execution are kept while it reads the same, also
   when it is decoded again (Keeper_librarian_original_gate.proofs). A failed
   capture is not kept: each record that names the execution restores it
   again and is refused as before. *)
type ('capture,'proofs) gate_parents =
  {captures:(string, string * Owner.retained * 'capture) Hashtbl.t; proofs:'proofs}
let gate_parents proofs = {captures=Hashtbl.create 8; proofs=proofs ()}
let parent_capture gates ~owner_key ~(parent:Owner.retained) restore =
  match Hashtbl.find_opt gates.captures parent.request_id with
  | Some (key,read,capture) when String.equal key owner_key && read == parent -> Ok capture
  | Some _ | None ->
    let+ capture=restore () in
    Hashtbl.replace gates.captures parent.request_id (owner_key,parent,capture);
    capture
type scope_gates = {
  admission_gates:(Admission.t, Keeper_librarian_admission_gate.proofs) gate_parents;
  history_gates:(History.t, Keeper_librarian_durable_gate.proofs) gate_parents;
  floor_gates:(Floor.t, Keeper_librarian_floor_step_gate.proofs) gate_parents}
let fresh_gates () =
  {admission_gates=gate_parents Keeper_librarian_admission_gate.proofs;
   history_gates=gate_parents Keeper_librarian_durable_gate.proofs;
   floor_gates=gate_parents Keeper_librarian_floor_step_gate.proofs}

let validator () =
  let forest=forest_proof () in
  (* Each gate record's check follows its retry links back to the journal's
     root. Chains proved earlier in the scope are not proved again. An
     execution's own record proves only its journal's first attempt, with
     proofs of its own. *)
  let scope_gates=per_scope fresh_gates and closure_gates=per_scope fresh_gates in
  let history_indexes=per_scope Keeper_librarian_history_resolution_lineage.payload_indexes in
  let admission_capture ~read ~read_scope ~owner record =
    let* ()=forest ~read_scope ~owner in
    Admission.restore ~owner ~load_parent:(Parts.load_parent_payload ~read ~owner) record in
  let validate ~gates ~indexes ~read ~read_scope ~read_body ~read_fence ~read_resolution (record:Owner.retained) =
  match purpose record.scope with
  | None -> Ok ()
  | Some Admission_execution ->
    let* owner=admission_owner record in
    let* capture=admission_capture ~read ~read_scope ~owner record in
    Keeper_librarian_admission_gate.validate_preparation_payload ~proofs:(Keeper_librarian_admission_gate.proofs ())
      ~read ~read_body ~owner ~capture ~parent:record
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
    let* capture=history_capture ~indexes ~read ~read_fence ~read_resolution ~owner record in
    Keeper_librarian_durable_gate.validate_preparation_payload ~proofs:(Keeper_librarian_durable_gate.proofs ())
      ~read ~read_body ~owner ~capture ~parent:record
  | Some Floor_execution ->
    let* owner=history_owner record in
    let* capture=floor_capture ~read ~owner record in
    Keeper_librarian_floor_step_gate.validate_preparation_payload ~proofs:(Keeper_librarian_floor_step_gate.proofs ())
      ~read ~read_body ~owner ~capture ~parent:record
  | Some Admission_gate ->
    let module Gate=Keeper_librarian_admission_gate in
    let* request_id=Gate.parent_execution_id record in
    let* owner=admission_owner record in
    let* parent=parent ~read ~scope:(Admission.scope owner) ~request_id in
    let* capture=parent_capture gates.admission_gates ~owner_key:(admission_key owner) ~parent
        (fun () -> admission_capture ~read ~read_scope ~owner parent) in
    Gate.validate_payload ~proofs:gates.admission_gates.proofs ~read ~read_body ~owner ~capture ~parent ~record
  | Some History_gate ->
    let module Gate=Keeper_librarian_durable_gate in
    let* request_id=Gate.parent_execution_id record in
    let* owner=history_owner record in
    let* parent=parent ~read ~scope:(History.scope owner) ~request_id in
    let* capture=parent_capture gates.history_gates ~owner_key:(history_key owner) ~parent
        (fun () -> history_capture ~indexes ~read ~read_fence ~read_resolution ~owner parent) in
    Gate.validate_payload ~proofs:gates.history_gates.proofs ~read ~read_body ~owner ~capture ~parent ~record
  | Some Floor_gate ->
    let module Gate=Keeper_librarian_floor_step_gate in
    let* request_id=Gate.parent_execution_id record in
    let* owner=history_owner record in
    let* parent=parent ~read ~scope:(Floor.scope owner) ~request_id in
    let* capture=parent_capture gates.floor_gates ~owner_key:(history_key owner) ~parent
        (fun () -> floor_capture ~read ~owner parent) in
    Gate.validate_payload ~proofs:gates.floor_gates.proofs ~read ~read_body ~owner ~capture ~parent ~record
  in
  (* Unlike the immutable forest payload, absence is not stable: a running
     owner can publish its closing journal before the next scanned record. *)
  fun ~read ~read_scope ~read_body ~read_archive ~read_fence ~read_resolution (record:Owner.retained) ->
  let gates=scope_gates record.scope in
  let indexes=history_indexes record.scope in
  match purpose record.scope with
  | None | Some (History_execution | Floor_execution | History_gate | Floor_gate) ->
    validate ~gates ~indexes ~read ~read_scope ~read_body ~read_fence ~read_resolution record
  | Some (Admission_execution | Admission_part | Admission_partition | Admission_gate | Admission_closure) ->
    let* owner=admission_owner record in
    let* view=Closure.project ~owner ~read ~read_scope ~read_body ~read_archive in
    match view.closure with
    | None ->
      validate ~gates ~indexes ~read ~read_scope ~read_body ~read_fence ~read_resolution record
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
      (* The closure's reads answer what the live reads may not, so the
         captures and chains they prove are kept apart from the live ones, for
         the scope as those are. Every record of an owner that has a closure
         is checked here, a gate journal's attempts too. The owner's forest
         proof is kept for both reads ([forest_proof]). *)
      let check=validate ~gates:(closure_gates record.scope) ~indexes ~read:view.read ~read_scope:view.read_scope
          ~read_body:view.read_body ~read_fence ~read_resolution in
      let* ()=check record in
      if Closure.is_scope record.scope then
        List.fold_left (fun result original -> let* ()=result in check original)
          (Ok ()) view.live_members
      else Ok ()

(* The deploy check of a Librarian original's Exact files (RFC
   exact-request-skips-a-slot-that-refused-its-input 3.3, item 5). It refuses
   an original exactly when its consumer stops on the Exact files the Exact
   check leaves, or reads its size evidence through a record that check
   deletes, and reads them as that consumer reads them. The validator above stays as the runtime runs
   it. *)
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
      (* An execution refusal: confirm_final of the final its evidence names,
         then what the consumer reads after a body refusal. *)
  | Confirm_ending of Owner.Record.t * Lane_addon_captured_destination.t
      (* A declaration ending: its strict cause, host record and independent
         proof read, or positive absence of both before admission. *)

let consumer_read ~(target:Final.target) ~destination (record:Owner.retained) =
  let ending () =
    let* permitted=Keeper_librarian_declaration_replacement.ended_payload
      ~original:(Owner.listed record) ~exact:target.exact ~captured:destination in
    if permitted then Ok (Some (Confirm_ending (Owner.listed record,destination)))
    else Error "Original Librarian has no strict declaration ending" in
  match Progress.phase record.progress with
  | Progress.Captured | Admission_wait _ -> Ok None
  | Dispatch_pending _ -> Ok (Some Recover_record)
  | Judged judgment -> Ok (Some (Decode_judgment judgment))
  | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) ->
    Ok (Some (Decode_judgment commit.Progress.judgment))
  | Rejected {Progress.stage=Progress.Execution;evidence} ->
    let* retained=Exact.retained_final_of_json ~schema:target.schema evidence in
    (match retained with
     | Exact.Retained_not_allowed {reason=Replaced_declaration} -> ending ()
     | Retained_unknown Cut when Option.is_some (Progress.settlement record.progress) -> ending ()
     | Retained_unknown (Interrupted | Raised | Cut) | Retained_call _ | Retained_not_allowed {reason=Permission_refused _}
     | Retained_request_id_reused -> Ok (Some (Confirm_delivered (Exact.delivered retained))))
  | Rejected {Progress.stage=Progress.Before_dispatch;_} -> ending ()
  | Subdividing _ | Subdivided _ -> Ok None

(* What a consumer reads once it confirms the body refusal the worker gives
   before the host (Request_body_refused). The host also ends a request with
   that final when no slot it called may pass again and the body refusal
   ranks first among the input refusals left ([ending] in
   server_lane_addon_exact.ml), and keeps a record and a proof then. History
   and floor build the refusal's evidence from the final alone
   (Final.refusal_evidence). Admission reads the original's latest execution
   proof as the size evidence of its part (size_refused, frontier). *)
type body_refusal_read = Final_alone | Size_proof

(* The latest execution proof is read through the original's record
   (Exact.latest_of_files). Once the Exact check deletes the record at the
   original's path, admission finds no size evidence for the body refusal:
   the part waits, and no new root follows it (#49910's wait). The check
   refuses on that deletion whatever the receipt holds, so an original whose
   receipt gave no size evidence before the deletion is refused too. An
   original that never had a record loses nothing to the Exact check, and
   passes. *)
let size_proof_kept body_refusal (deleted:Preflight.deleted_record option) =
  match body_refusal,deleted with
  | Final_alone,_ | Size_proof,None -> Ok ()
  | Size_proof,Some (Preflight.Deleted_open | Deleted_terminal _ | Deleted_unknown) ->
    Error "the Exact check deletes the original's record, which the size evidence of \
           its body refusal is read through, and its part waits for evidence no pass \
           brings back"

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
   it confirms only for a final the worker refuses before the host. Admission
   then reads the size evidence of that refusal through the deleted record. *)
let recover_files ~wording ~body_refusal (target:Final.target) (files:Preflight.exact_files) =
  let* ()=match files.deleted with
    | None | Some Preflight.Deleted_open -> Ok ()
    | Some (Deleted_terminal final) when Exact.refused_before_host final ->
      size_proof_kept body_refusal files.deleted
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
let judge_files ~wording ~body_refusal (target:Final.target) (files:Preflight.exact_files) = function
  | Recover_record -> recover_files ~wording ~body_refusal target files
  | Decode_judgment judgment ->
    (* Every consumer's decode_final is Final.decode_final, which confirms a
       recovered final in Final's words; the consumer then confirms the final
       in its own. *)
    let* final=Final.decode ~schema:target.schema ~observe:(fun () -> observe_files target files)
        ~confirm:(confirm_files ~wording:Final.unconfirmed_detail target files) judgment in
    confirm_files ~wording target files final
  | Confirm_delivered final ->
    let* ()=confirm_files ~wording target files final in
    if Exact.refused_before_host final then size_proof_kept body_refusal files.deleted else Ok ()
  | Confirm_ending (original,captured) ->
    let reads:Keeper_librarian_declaration_replacement.ending_reads={
      before_dispatch=(fun () ->
        match files.deleted,files.record,files.proof with
        | None,None,Preflight.No_proof -> Ok ()
        | Some (Deleted_open | Deleted_terminal _ | Deleted_unknown),_,_ ->
          Error "The Exact check removes original host evidence; absence cannot confirm a before-dispatch ending"
        | None,(Some _),_ | None,None,(Proof _ | Unreadable_proof _) ->
          Error "A before-dispatch declaration ending has original host execution evidence");
      observe=(fun () ->
        let* proof=proof_json files in
        let* record=Exact.recovery_of_files ~store:files.store ~declaration_id:target.declaration_id
          ~schema:target.schema target.exact ~record:files.record ~proof in
        Exact.observe_record ~declaration_id:target.declaration_id ~schema:target.schema target.exact record);
      latest=(fun () -> latest_files ~declaration_id:target.declaration_id ~schema:target.schema target.exact files);
    } in
    let* ended=Keeper_librarian_declaration_replacement.ended_with ~reads ~original
      ~exact:target.exact ~captured in
    if ended then Ok () else Error "Original Librarian has no confirmed declaration ending"
(* A proof link the original's request names while no record of it is left.
   Fresh state deletes it with the owner's scopes. *)
let recordless_proof (target:Final.target) (files:Preflight.exact_files) =
  match files.record,files.proof with
  | None,(Preflight.Proof _ | Unreadable_proof _) ->
    [Exact.Retained_key.proof_path
       (Exact.Retained_key.of_request ~declaration_id:target.declaration_id target.exact)]
  | Some _,_ | None,No_proof -> []

(* One original whose consumer reads its Exact files: its request with the
   declaration and schema, what the consumer does with the files, the words
   the consumer's confirm_final uses, and what it reads after a body refusal. *)
type exact_original = {target:Final.target;read:consumer_read;wording:Final.unconfirmed -> string;
  body_refusal:body_refusal_read}
let installation_id (destination:Lane_addon_captured_destination.t) =
  destination.Lane_addon_captured_destination.installation_id
(* [None] when the consumer reads no Exact file of this original: a manual
   installation names no declaration, and some phases read none. *)
let exact_original ~wording ~body_refusal ~destination exact (record:Owner.retained) =
  let installation_id=installation_id destination in
  let* installation=Owner.installation_of_id installation_id in
  match installation with
  | Owner.Manual _ -> Ok None
  | Owner.Configuration _ ->
    let* target=Final.target ~installation_id exact in
    let+ read=consumer_read ~target ~destination record in
    Option.map (fun read -> {target;read;wording;body_refusal}) read
(* Phase one decodes what the consumer reads, as the consumer decodes it; a
   failure there is a payload the consumer refuses. Phase two reads the Exact
   files. *)
let original_verdict ~(read_exact:Preflight.exact_reader) = function
  | Error detail -> Preflight.Payload_invalid detail
  | Ok (_,None) -> Preflight.Payload_valid
  | Ok (scopes,Some {target;read;wording;body_refusal}) ->
    (match read_exact ~declaration_id:target.Final.declaration_id target.Final.exact with
     | Error detail -> Preflight.Exact_root_differs detail
     | Ok files ->
       (match judge_files ~wording ~body_refusal target files read with
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
  exact_original ~wording:Admission.unconfirmed_detail ~body_refusal:Size_proof
    ~destination:(Admission.destination capture) exact record
(* A history original an operator fenced is left out of resume and
   validation, so its consumer reads no Exact file. *)
let history_original ~read_fence ~owner (record:Owner.retained) =
  let* fence=read_fence ~scope:record.scope ~request_id:record.request_id in
  match fence with
  | Some _ -> Ok None
  | None ->
    let* capture=History.restore_payload ~owner record in
    let* exact=History.request capture in
    exact_original ~wording:Final.unconfirmed_detail ~body_refusal:Final_alone
      ~destination:(History.destination capture) exact record
let floor_original ~owner record =
  let* step=Floor.restore ~owner record in
  let* exact=Floor.request step in
  exact_original ~wording:Final.unconfirmed_detail ~body_refusal:Final_alone
    ~destination:(Floor.destination step) exact record

(* The forest of each owner, read once for the scan by the first record that
   needs it. A check that fails reads it again before it refuses: a part or
   partition published after the first read belongs to the forest the
   consumer reads. *)
let forest_reads () =
  let read=Hashtbl.create 16 in
  fun ~again ~read_scope ~owner ->
    let key=admission_key owner in
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

(* A gate record's consumer reads the Exact files of the execution the record
   names, so a journal's records all read one execution's files. A passed
   verdict is kept while the scan stays in the scope and the execution reads
   the same. A refused one is not: each record that names the execution is
   judged again and refused as before. *)
let gate_verdict passed ~owner_key ~(parent:Owner.retained) judge =
  match Hashtbl.find_opt passed parent.request_id with
  | Some (key,read) when String.equal key owner_key && read == parent -> Preflight.Payload_valid
  | Some _ | None ->
    match judge () with
    | Preflight.Payload_valid ->
      Hashtbl.replace passed parent.request_id (owner_key,parent);
      Preflight.Payload_valid
    | (Payload_invalid _ | Consumer_stops_on_exact _ | Exact_root_differs _) as refused -> refused

let exact_check () =
  let forest=forest_reads () in
  let scope_passed=per_scope (fun () -> Hashtbl.create 8) in
  fun ~read ~read_scope ~read_body ~read_archive ~read_fence ~read_exact (record:Owner.retained) ->
  let passed=scope_passed record.scope in
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
      match
        let* request_id=Keeper_librarian_admission_gate.parent_execution_id record in
        parent ~read ~scope:(Admission.scope owner) ~request_id
      with
      | Error detail -> Preflight.Payload_invalid detail
      | Ok parent ->
        gate_verdict passed ~owner_key:(admission_key owner) ~parent (fun () ->
          original_verdict ~read_exact
            (let+ original=admission_original ~read ~owner parent in scopes,original)))
  | Some Admission_part -> admission (forest_check Parts.check_frontier_evidence)
  | Some Admission_partition -> admission (forest_check Parts.check_partition_proof)
  | Some History_execution ->
    original_verdict ~read_exact
      (let* owner=history_owner record in
       let+ original=history_original ~read_fence ~owner record in history_scopes owner,original)
  | Some History_gate ->
    (match
       let* request_id=Keeper_librarian_durable_gate.parent_execution_id record in
       let* owner=history_owner record in
       let+ parent=parent ~read ~scope:(History.scope owner) ~request_id in owner,parent
     with
     | Error detail -> Preflight.Payload_invalid detail
     | Ok (owner,parent) ->
       gate_verdict passed ~owner_key:(history_key owner) ~parent (fun () ->
         original_verdict ~read_exact
           (let+ original=history_original ~read_fence ~owner parent in history_scopes owner,original)))
  | Some Floor_execution ->
    original_verdict ~read_exact
      (let* owner=history_owner record in
       let+ original=floor_original ~owner record in floor_scopes owner,original)
  | Some Floor_gate ->
    (match
       let* request_id=Keeper_librarian_floor_step_gate.parent_execution_id record in
       let* owner=history_owner record in
       let+ parent=parent ~read ~scope:(Floor.scope owner) ~request_id in owner,parent
     with
     | Error detail -> Preflight.Payload_invalid detail
     | Ok (owner,parent) ->
       gate_verdict passed ~owner_key:(history_key owner) ~parent (fun () ->
         original_verdict ~read_exact
           (let+ original=floor_original ~owner parent in floor_scopes owner,original)))

let preflight () =
  let validate=validator () and exact=exact_check () in
  fun ~read ~read_scope ~read_body ~read_archive ~read_fence ~read_resolution ~read_exact
    (record:Owner.retained) ->
  match validate ~read ~read_scope ~read_body ~read_archive ~read_fence ~read_resolution record with
  | Error detail -> Preflight.Payload_invalid detail
  | Ok () -> exact ~read ~read_scope ~read_body ~read_archive ~read_fence ~read_exact record

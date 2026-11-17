module Step = Keeper_librarian_floor_step_request
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Runtime = Keeper_librarian_runtime
module Durable = Keeper_librarian_durable_request
module Ending = Keeper_librarian_declaration_replacement
module Gate = Keeper_librarian_floor_step_gate
module Edge = Keeper_librarian_durable_edge
module Ids = Map.Make (String)
open Result.Syntax
let require condition detail = if condition then Ok () else Error detail
let owned result = Result.map_error Owner.error_to_string result
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f
let equal left right =
  let* left=Lane_addon_action.canonical left in
  let+ right=Lane_addon_action.canonical right in Yojson.Safe.equal left right
type node = {record:Owner.retained;step:Step.t}
type t = {selected:node list}
let steps t=List.map (fun node -> node.record,node.step) t.selected
let source step = match (Step.step step).mode with
  | Runtime.Retained_original source -> Ok source
  | Ordinary_floor -> Error "Declaration replacement requires retained original mode"
let known_ending node =
  let* _=source node.step in
  let* exact=Step.request node.step in
  let progress=node.record.progress in
  let* ()=require (Progress.preparation progress=None && Progress.settlement progress=None)
    "Replaced question has Gate work or a refusal disposition" in
  let* allowed=match Progress.phase progress with
    | Progress.Rejected {stage=Before_dispatch;_} -> Ok true
    | Rejected {stage=Execution;evidence} ->
      let* schema=Option.to_result ~none:"Replaced question lacks its exact schema" exact.Exact.schema in
      let+ retained=Exact.retained_final_of_json ~schema evidence in
      (match retained with
       | Exact.Retained_not_allowed {reason=Replaced_declaration} -> true
       | Retained_not_allowed {reason=Permission_refused _} | Retained_unknown _
       | Retained_call _ | Retained_request_id_reused -> false)
    | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
    | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> Ok false in
  let* ()=require allowed "Question has no known non-executed declaration ending" in
  let* ended=Ending.ended_payload ~original:(Owner.listed node.record) ~exact
    ~captured:(Step.destination node.step) in
  require ended "Question declaration ending is not bound to its original"
let no_gate ~store node =
  let* gates=Gate.Inventory.read ~store ~owner:(Step.physical_owner node.step) in
  require (Gate.Inventory.execution_records gates ~execution_id:node.record.request_id=[])
    "Replaced question has an actual absorption Gate"
let confirm_ending ~store node =
  let* ()=known_ending node in
  let* ()=Step.confirm_owner node.step in
  let* ()=no_gate ~store node in
  let* exact=Step.request node.step in
  let* ended=Ending.ended ~store ~original:(Owner.listed node.record) ~exact
    ~captured:(Step.destination node.step) in
  require ended "Question declaration ending differs from its actual host evidence"
let unconfirmed node =
  let progress=node.record.progress in
  let* ()=require (Progress.preparation progress=None && Progress.replacement progress=None
    && Progress.settlement progress=None) "Unacknowledged question already owns other work" in
  match Progress.phase progress with
  | Progress.Captured -> Ok ()
  | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
    Error "Unacknowledged replacement question has progressed"
let confirm_unconfirmed ~store node =
  let* ()=unconfirmed node in
  let* ()=no_gate ~store node in
  let* exact=Step.request node.step in
  Ending.confirm_no_execution ~store ~original:(Owner.listed node.record) ~exact_digest:(Exact.digest exact)
let check_child parent intended =
  let* child=Step.of_json ~owner:(Step.physical_owner parent.step) intended.Progress.request in
  let* ()=require (Step.request_id child=intended.request_id) "Replacement child differs from its intended ID" in
  let* expected=Step.replace_declaration ~request_id:intended.request_id
    ~destination:(Step.destination child) parent.step in
  let* same=equal (Step.to_json expected) (Step.to_json child) in
  let+ ()=require same "Replacement changed its original coordinate, frozen question, anchor or transaction" in child
type edge = {child:Step.t;confirmed:bool}
let resolve ~verify_parent ~verify_child nodes =
  let by_id=List.fold_left (fun found node -> Ids.add node.record.request_id node found) Ids.empty nodes in
  let* ()=require (Ids.cardinal by_id=List.length nodes) "Retained question inventory repeats an original ID" in
  let* edges,incoming=List.fold_left (fun result node ->
    let* edges,incoming=result in
    match Progress.replacement node.record.progress with
    | None -> Ok (edges,incoming)
    | Some (Preparation_pending intended | Preparation_confirmed intended as publication) ->
      let* ()=verify_parent node in
      let* child=check_child node intended in
      let id=Step.request_id child in
      let* ()=require (not (List.mem id incoming)) "Two questions claim the same replacement child" in
      let confirmed=match publication with Preparation_confirmed _ -> true | Preparation_pending _ -> false in
      let* ()=match Ids.find_opt id by_id with
        | None -> require (not confirmed) "Confirmed replacement question is absent"
        | Some actual ->
          let* ()=Step.confirm_record child actual.record in
          if confirmed then Ok () else verify_child actual in
      Ok (Ids.add node.record.request_id {child;confirmed} edges,id::incoming)) (Ok (Ids.empty,[])) nodes in
  let positions=List.map (fun node -> Step.position node.step) nodes |> List.sort_uniq Int.compare in
  let rec visit seen node =
    let id=node.record.request_id in
    let* ()=require (not (List.mem id seen)) "Retained question replacement contains a cycle" in
    let seen=id::seen in
    match Ids.find_opt id edges with
    | None -> Ok (node,seen)
    | Some edge ->
      let id=Step.request_id edge.child in
      match edge.confirmed,Ids.find_opt id by_id with
      | true,Some child -> visit seen child
      | true,None -> Error "Confirmed replacement question disappeared"
      | false,None -> Ok (node,seen)
      | false,Some child ->
        let* ()=verify_child child in Ok (node,id::seen) in
  let* selected,seen=List.fold_left (fun result position ->
    let* selected,seen=result in
    let roots=List.filter (fun node -> Step.position node.step=position
      && not (List.mem node.record.request_id incoming)) nodes in
    let* root=match roots with [root] -> Ok root
      | [] | _::_ -> Error "Retained coordinate has no unique replacement root" in
    let+ leaf,visited=visit [] root in leaf::selected,visited @ seen) (Ok ([],[])) positions in
  let* ()=require (List.length seen=List.length nodes) "Retained coordinate has an orphan or cyclic question" in
  let selected=List.rev selected in
  let* _=List.fold_left (fun result node ->
    let* position,previous=result in
    let* ()=require (Step.position node.step=position && Step.previous node.step=previous)
      "Retained logical questions have a gap or a changed previous answer" in
    Ok (position+1,Some ({Step.request_id=node.record.request_id;
      request_digest=node.record.request_digest}:Step.link))) (Ok (0,None)) selected in
  Ok {selected}
let captures ~owner ~(range:Step.link) ~source records =
  List.fold_left (fun result record ->
    let* nodes=result in
    let* index=Step.index_of_summary (Owner.listed record) in
    if index.header.range.request_id<>range.request_id then Ok nodes else
    let* ()=require (index.owner=owner && index.header.range=range && index.header.retained_source=Some source)
      "Retained range has another physical owner, source or preparation mode" in
    let+ step=Step.restore ~owner record in {record;step}::nodes) (Ok []) records
let payload_nodes ~read_scope ~owner ~range ~source =
  let* records=read_scope ~scope:(Step.scope owner) in
  let* nodes=captures ~owner ~range ~source records in
  let+ _=resolve ~verify_parent:known_ending ~verify_child:unconfirmed nodes in nodes
let validate_payload ~read_scope ~owner ~range ~source =
  let+ _=payload_nodes ~read_scope ~owner ~range ~source in ()
type payload_status = Original_question | Child_awaiting_publication
let payload_status ~read_scope ~owner ~range ~source ~request_id =
  let* nodes=payload_nodes ~read_scope ~owner ~range ~source in
  let+ ()=require (List.exists (fun node -> node.record.request_id=request_id) nodes)
    "Retained question is absent from its source graph" in
  if List.exists (fun node -> match Progress.replacement node.record.progress with
    | Some (Preparation_pending intended) -> intended.request_id=request_id
    | None | Some (Preparation_confirmed _) -> false) nodes
  then Child_awaiting_publication else Original_question
let read ~store ~owner ~(range:Step.link) ~source =
  let* listed=Owner.discover ~store ~scope:(Step.scope owner) |> owned in
  let* records=List.fold_left (fun result record ->
    let* records=result in
    let* index=Step.index_of_summary record in
    let* ()=Durable.owner_matches_json owner (Durable.owner_to_json index.owner) in
    if index.header.range.request_id<>range.request_id then Ok records else
    let+ original=Owner.load_listed ~store record |> owned in original::records) (Ok []) listed in
  let* nodes=captures ~owner ~range ~source records in
  resolve ~verify_parent:(confirm_ending ~store) ~verify_child:(confirm_unconfirmed ~store) nodes
let confirm_selected ~store step =
  let* source=source step in
  let* ()=Step.confirm_owner step in
  let* selected=read ~store ~owner:(Step.physical_owner step) ~range:(Step.range step) ~source in
  match List.find_opt (fun node -> node.record.request_id=Step.request_id step) selected.selected with
  | None -> Error "Retained question is not the confirmed selected logical leaf"
  | Some node ->
    let* ()=Step.confirm_record step node.record in
    let* ()=require (Progress.replacement node.record.progress=None)
      "An ended replacement parent cannot dispatch its old question" in
    (match Progress.phase node.record.progress with
     | Progress.Captured | Admission_wait _ | Dispatch_pending _ -> Ok ()
     | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _ | Rejected _
     | Subdividing _ | Subdivided _ -> Error "A terminal retained question cannot dispatch")
let advance ~store record event =
  match Owner.advance ~store ~expected:record ~event with
  | Ok (Owner.Stored record | Already_stored record) -> Ok record
  | Ok (Unconfirmed detail) -> Error detail
  | Error error -> Error (Owner.update_error_to_string error)
let retain ~store child =
  let destination=Step.destination child and owner=Step.physical_owner child in
  let* index=Step.index child in
  let* ()=Owner.retain ~store ~scope:(Step.scope owner) ~request_id:(Step.request_id child)
    ~installation_id:destination.installation_id ~package_id:destination.package_id ~tool:destination.tool
    ~summary:(Step.index_to_json index) ~request:(Step.to_json child) |> owned in
  let* actual=Owner.load ~store ~scope:(Step.scope owner) ~request_id:(Step.request_id child) |> owned in
  let* actual=Option.to_result ~none:"Replacement question is not observable after retention" actual in
  let* _=Step.restore ~owner actual in
  let+ ()=Step.confirm_record child actual in actual
let resume ~store ~config ~reserved ~original ~step =
  Edge.with_destination ~config ~reserved (fun destination -> io (fun () ->
    let* ()=match Lane_addon_captured_destination.relation ~captured:(Step.destination step) ~current:destination with
      | Same | Replaced -> Ok ()
      | Other_owner -> Error "Ready replacement belongs to another question owner" in
    let* actual=Owner.reload ~store original |> owned in
    let* record=Option.to_result ~none:"Replaced question disappeared" actual in
    let* ()=Step.confirm_record step record in
    let* source=source step in
    let* inventory=read ~store ~owner:(Step.physical_owner step) ~range:(Step.range step) ~source in
    let* ()=match Progress.replacement record.progress with
      | Some (Preparation_confirmed _) -> Ok ()
      | None | Some (Preparation_pending _) ->
        require (List.for_all (fun (_,existing) -> Step.position existing<=Step.position step) (steps inventory))
          "An ended unanswered coordinate already has later retained questions" in
    let node={record;step} in
    let* ()=confirm_ending ~store node in
    let* record,intended=match Progress.replacement record.progress with
      | Some (Preparation_pending intended | Preparation_confirmed intended) -> Ok (record,intended)
      | None ->
        let* child=Step.replace_declaration ~request_id:(Step.fresh_request_id (Step.physical_owner step))
          ~destination step in
        let intended:Progress.preparation_intent={request_id=Step.request_id child;request=Step.to_json child} in
        let+ record=advance ~store record (Progress.Replacement_intended intended) in record,intended in
    let* child=check_child {record;step} intended in
    let* actual=retain ~store child in
    let* ()=match Progress.replacement record.progress with
      | Some (Preparation_pending _) ->
        let* ()=confirm_unconfirmed ~store {record=actual;step=child} in
        let+ _=advance ~store record (Progress.Replacement_observed intended.request_id) in ()
      | Some (Preparation_confirmed _) -> Ok ()
      | None -> Error "Replacement intent disappeared" in
    (* Rejoin the whole confirmed graph. An older acknowledged child may
       already have a strictly proved successor; observing that publication
       still returns its own immutable intended ID, never the newer leaf. *)
    let+ _=read ~store ~owner:(Step.physical_owner step) ~range:(Step.range step) ~source in
    intended.request_id))

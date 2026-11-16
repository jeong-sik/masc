module Request = Keeper_librarian_durable_request
module Owner = Lane_addon_tool_request_owner
module Fence = Keeper_librarian_history_resolution_state
module Intent = Keeper_librarian_history_resolution_intent
module Store = Lane_addon_store
open Result.Syntax
type reader = scope:string -> request_id:string -> (Yojson.Safe.t option, string) result
let require condition message = if condition then Ok () else Error message
(* One original as lineage reads it: its record, the index of its request, and
   its request when a link needs the whole of it. *)
type node = {record:Owner.Record.t;index:Request.index;body:unit -> (Request.t,string) result}
type node_reader = owner:Request.owner -> request_id:string -> (node option,string) result
(* A fenced original's index is bound to its body here: the fence is read
   with the body in hand, and lineage then reads that index without it. *)
let fenced_original ~store ~request ~original =
  let* observed=Fence.read ~store ~scope:original.Owner.scope ~request_id:original.request_id in
  let+ ()=match observed with
    | None -> Ok ()
    | Some fence ->
      let record=Owner.listed original in
      let* ()=require (Request.request_id request=original.request_id
        && Request.body_digest request=original.request_digest) "History fence request differs from its original" in
      let* ()=Request.confirm_index request record in
      let* index=Request.index_of_summary record in
      Fence.confirm_binding_index ~index ~original:record fence in
  observed
(* The same fence from the record and its index alone. The fence was made
   from the body, so a source digest the index does not share with the body
   differs from the fence here. *)
let fenced_record ~store ~record ~index =
  let* observed=Fence.read ~store ~scope:(Owner.Record.scope record) ~request_id:(Owner.Record.request_id record) in
  let+ ()=match observed with
    | None -> Ok ()
    | Some fence -> Fence.confirm_binding_index ~index ~original:record fence in
  observed
(* The links are checked on values: record identity, the two indexes, the
   fence and the resolution record. Only the known-basis link, whose parent
   holds the child's whole request in its progress, reads requests. The walk
   starts from one original given as those values. *)
let validate_node ~read_node ~read ~read_fence ~read_resolution ~confirm_ending ~require_confirmed
    ~id ~digest ~owner ~predecessor ~basis ~body =
  let rec visit seen ~require_confirmed ~id ~digest ~owner ~predecessor ~basis ~body =
    let* ()=require (not (List.mem id seen)) "History resolution ancestry contains a cycle" in
    match predecessor with
    | None -> Ok ()
    | Some (predecessor:Request.predecessor) ->
      let scope=Request.scope owner in
      let* parent=read_node ~owner ~request_id:predecessor.request_id in
      let* parent=Option.to_result ~none:"History predecessor is absent" parent in
      let parent_id=Owner.Record.request_id parent.record in
      let* ()=require (Owner.Record.scope parent.record=scope && parent_id=predecessor.request_id
        && Owner.Record.request_digest parent.record=predecessor.request_digest) "History predecessor digest differs" in
      let* fence=read_fence ~scope ~request_id:parent_id in
      let* ()=match fence with
        | None ->
          let* request=body () in
          let* ()=Request.validate_predecessor_link_payload ~read ~require_confirmed request in
          confirm_ending parent
        | Some json ->
          let* fence=Fence.of_json json in
          let* ()=Fence.confirm_binding_index ~index:parent.index ~original:parent.record fence in
          let* stored=read_resolution ~scope ~request_id:parent_id in
          let* stored=Option.to_result ~none:"Fenced history parent has no resolution intent" stored in
          let* intents=Intent.decode_published ~scope ~request_id:parent_id stored in
          let* intent=Option.to_result ~none:"Fenced history parent has no acknowledged child intent"
            (List.find_opt (fun intent -> match intent.Intent.phase with
              | Child_confirmed child -> child.request_id=id
              | Child_intended child -> not require_confirmed && child.request_id=id
              | Requested | Refused _ | Fenced -> false) intents) in
          let* ()=require (intent.expected=fence.expected && intent.actor=fence.actor && intent.reason=fence.reason)
            "History child intent does not own the original fence" in
          (* The intent names its child by digest, and equal digests are
             equal requests. *)
          let* intended=Option.to_result ~none:"Resolution child intent is absent" (Intent.child intent) in
          let* ()=require (intended.request_digest=digest) "History child differs from its durable intent" in
          (* Equal basis: the child's source is the parent's with another
             current Memory, which is all [Source.with_current] changes. *)
          let* basis=basis () in
          require (basis=parent.index.source_basis_digest && owner=parent.index.owner)
            "History resolution child changed its original source or owner" in
      visit (id::seen) ~require_confirmed:true ~id:parent_id ~digest:(Owner.Record.request_digest parent.record)
        ~owner:parent.index.owner ~predecessor:parent.index.predecessor
        ~basis:(fun () -> Ok parent.index.source_basis_digest) ~body:parent.body in
  visit [] ~require_confirmed ~id ~digest ~owner ~predecessor ~basis ~body
let validate ~read_node ~read ~read_fence ~read_resolution ~confirm_ending ~require_confirmed request =
  validate_node ~read_node ~read ~read_fence ~read_resolution ~confirm_ending ~require_confirmed
    ~id:(Request.request_id request) ~digest:(Request.body_digest request)
    ~owner:(Request.physical_owner request) ~predecessor:(Request.predecessor request)
    ~basis:(fun () -> Request.source_basis_digest request) ~body:(fun () -> Ok request)
(* A reader that has the body: the index it hands on is made from the request
   it restored, and the record's summary must be that index. *)
let body_node ~restore ~read ~verified ~owner ~request_id =
  let* parent=read ~scope:(Request.scope owner) ~request_id in
  match parent with
  | None -> Ok None
  | Some (parent:Owner.retained) ->
    let record=Owner.listed parent in
    let* request=restore ~owner parent in
    (* The summary was just confirmed equal to the request's index, so it is
       read back and not computed again. *)
    let* ()=Request.confirm_index request record in
    let+ index=Request.index_of_summary record in
    verified parent index;
    Some {record;index;body=(fun () -> Ok request)}
(* A preflight reader verifies the actual bytes on every read and returns the
   same immutable JSON only while those bytes match. Keep just a weak witness
   and the fully checked small index: a scan must not retain every reconstructed
   source/prompt or an old progress tail. The current record still supplies all
   progress, and the lineage walk still reads every fence and child intent. *)
type payload_index = {request:Yojson.Safe.t Weak.t;id:string;digest:string;index:Request.index}
type payload_indexes = (string * string, payload_index) Hashtbl.t
let payload_indexes () = Hashtbl.create 16
let payload_node ~indexes ~read ~owner ~request_id =
  let scope=Request.scope owner in
  let key=scope,request_id in
  let* parent=match read ~scope ~request_id with
    | Error detail -> Hashtbl.remove indexes key; Error detail
    | Ok parent -> Ok parent in
  match parent with
  | None -> Hashtbl.remove indexes key; Ok None
  | Some (parent:Owner.retained) ->
    let record=Owner.listed parent in
    let cached=match Hashtbl.find_opt indexes key with
      | Some previous when String.equal previous.id parent.request_id
          && String.equal previous.digest parent.request_digest
          && previous.index.owner=owner
          && (match Weak.get previous.request 0 with Some request -> request==parent.request | None -> false) ->
        (match Request.index_of_summary record with
         | Ok index when index=previous.index -> Some index
         | Error _ | Ok _ -> None)
      | Some _ | None -> None in
    (match cached with
     | Some index ->
       Ok (Some {record;index;body=(fun () -> Request.restore_payload ~owner parent)})
     | None ->
       Hashtbl.remove indexes key;
       let* request=Request.restore_payload ~owner parent in
       let* ()=Request.confirm_index request record in
       let+ index=Request.index_of_summary record in
       let witness=Weak.create 1 in
       Weak.set witness 0 (Some parent.request);
       Hashtbl.replace indexes key {request=witness;id=parent.request_id;digest=parent.request_digest;index};
       Some {record;index;body=(fun () -> Ok request)})
let validate_predecessor_payload ?indexes ~read ~read_fence ~read_resolution ~require_confirmed request =
  let read_node=match indexes with
    | None -> body_node ~restore:Request.restore_payload ~read ~verified:(fun _ _ -> ())
    | Some indexes -> payload_node ~indexes ~read in
  validate ~read_node ~read ~read_fence ~read_resolution
    ~confirm_ending:(fun _ -> Ok ()) ~require_confirmed request
let store_readers ~store =
  (fun ~scope ~request_id -> Owner.load ~store ~scope ~request_id |> Result.map_error Owner.error_to_string),
  Store.load_history_fence store,Store.load_history_resolution store
let confirm_ending ~store parent =
  match Lane_addon_request_progress.phase (Owner.Record.progress parent.record) with
  | Rejected _ ->
    let* request=parent.body () in
    let* exact=Request.request request in
    let* ended=Keeper_librarian_declaration_replacement.ended ~store
      ~original:parent.record ~exact ~captured:(Request.destination request) in
    require ended "History predecessor has no confirmed declaration ending"
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> Ok ()
let confirm_predecessor_by_body ~store ~require_confirmed request =
  let read,read_fence,read_resolution=store_readers ~store in
  validate ~read_node:(body_node ~restore:Request.restore ~read ~verified:(fun _ _ -> ())) ~read ~read_fence ~read_resolution
    ~confirm_ending:(confirm_ending ~store) ~require_confirmed request
type verified_node = {verified_body:Owner.verified_body;verified_index:Request.index}
module Predecessor_map = Map.Make (String)
type verified_predecessors = {store:Store.t;request:Request.t;nodes:verified_node Predecessor_map.t}
let verify_predecessors ~store ~require_confirmed request =
  let nodes=ref Predecessor_map.empty in
  let verified (original:Owner.retained) index =
    nodes := Predecessor_map.add original.request_id
      {verified_body=Owner.verified_body original;verified_index=index} !nodes in
  let read,read_fence,read_resolution=store_readers ~store in
  let+ ()=validate ~read_node:(body_node ~restore:Request.restore ~read ~verified)
    ~read ~read_fence ~read_resolution ~confirm_ending:(confirm_ending ~store) ~require_confirmed request in
  {store;request;nodes= !nodes}
let recheck_predecessors ~store ~require_confirmed request verified =
  let* ()=require (store==verified.store && request==verified.request)
    "Verified history predecessors belong to another authorization" in
  let read_node ~owner ~request_id =
    let* previous=Option.to_result ~none:"History predecessor was not verified by this authorization"
      (Predecessor_map.find_opt request_id verified.nodes) in
    let* record=Owner.recheck_body ~store previous.verified_body |> Result.map_error Owner.error_to_string in
    let index=previous.verified_index in
    let* ()=require (Owner.Record.scope record=Request.scope owner)
      "Verified history predecessor belongs to another owner scope" in
    let+ ()=Request.confirm_index_source_root index in
    Some {record;index;body=(fun () ->
      let* original=Owner.load_listed ~store record |> Result.map_error Owner.error_to_string in
      Request.restore ~owner:index.owner original)} in
  let read,read_fence,read_resolution=store_readers ~store in
  validate ~read_node ~read ~read_fence ~read_resolution ~confirm_ending:(confirm_ending ~store) ~require_confirmed request
(* The Keeper's pass: an original is its record and the index in that
   record's summary. Its body is read only for a known-basis link. *)
let record_body ~store record (index:Request.index) () =
  let* original=Owner.load_listed ~store record |> Result.map_error Owner.error_to_string in
  Request.restore ~owner:index.owner original
let record_node ~store ~owner ~request_id =
  let* record=Owner.load_record ~store ~scope:(Request.scope owner) ~request_id
    |> Result.map_error Owner.error_to_string in
  match record with
  | None -> Ok None
  | Some record ->
    let* index=Request.index_of_summary record in
    let+ ()=Request.confirm_index_source_root index in
    Some {record;index;body=record_body ~store record index}
let confirm_predecessor ~store ~require_confirmed request =
  let read,read_fence,read_resolution=store_readers ~store in
  validate ~read_node:(record_node ~store) ~read ~read_fence ~read_resolution
    ~confirm_ending:(confirm_ending ~store) ~require_confirmed request
let confirm_predecessor_record ~store ~require_confirmed record (index:Request.index) =
  let read,read_fence,read_resolution=store_readers ~store in
  validate_node ~read_node:(record_node ~store) ~read ~read_fence ~read_resolution
    ~confirm_ending:(confirm_ending ~store) ~require_confirmed
    ~id:(Owner.Record.request_id record) ~digest:(Owner.Record.request_digest record)
    ~owner:index.owner ~predecessor:index.predecessor
    ~basis:(fun () -> Ok index.source_basis_digest) ~body:(record_body ~store record index)
(* Names the acknowledged child only. Its lineage is confirmed by whoever
   reads that child next. *)
let confirmed_resolution_child ~store ~record ~index =
  let* fence=fenced_record ~store ~record ~index in
  match fence with
  | None -> Ok None
  | Some fence ->
    let scope=Owner.Record.scope record and request_id=Owner.Record.request_id record in
    let* json=Store.load_history_resolution store ~scope ~request_id in
    let* json=Option.to_result ~none:"Fenced history original has no resolution intent" json in
    let* intents=Intent.decode_published ~scope ~request_id json in
    let* intent=Option.to_result ~none:"Fenced history original has no active resolution" (List.find_opt (fun intent ->
      intent.Intent.expected=fence.expected && intent.actor=fence.actor && intent.reason=fence.reason) intents) in
    match intent.phase with
    | Intent.Child_confirmed child -> Ok (Some child.request_id)
    | Requested | Refused _ | Fenced | Child_intended _ -> Ok None

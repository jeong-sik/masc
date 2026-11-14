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
let validate_node ~read_node ~read ~read_fence ~read_resolution ~require_confirmed
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
          Request.validate_predecessor_link_payload ~read ~require_confirmed request
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
let validate ~read_node ~read ~read_fence ~read_resolution ~require_confirmed request =
  validate_node ~read_node ~read ~read_fence ~read_resolution ~require_confirmed
    ~id:(Request.request_id request) ~digest:(Request.body_digest request)
    ~owner:(Request.physical_owner request) ~predecessor:(Request.predecessor request)
    ~basis:(fun () -> Request.source_basis_digest request) ~body:(fun () -> Ok request)
(* A reader that has the body: the index it hands on is made from the request
   it restored, and the record's summary must be that index. *)
let body_node ~restore ~read ~owner ~request_id =
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
    Some {record;index;body=(fun () -> Ok request)}
let validate_predecessor_payload ~read ~read_fence ~read_resolution ~require_confirmed request =
  validate ~read_node:(body_node ~restore:Request.restore_payload ~read) ~read ~read_fence ~read_resolution
    ~require_confirmed request
let store_readers ~store =
  (fun ~scope ~request_id -> Owner.load ~store ~scope ~request_id |> Result.map_error Owner.error_to_string),
  Store.load_history_fence store,Store.load_history_resolution store
let confirm_predecessor_by_body ~store ~require_confirmed request =
  let read,read_fence,read_resolution=store_readers ~store in
  validate ~read_node:(body_node ~restore:Request.restore ~read) ~read ~read_fence ~read_resolution
    ~require_confirmed request
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
  validate ~read_node:(record_node ~store) ~read ~read_fence ~read_resolution ~require_confirmed request
let confirm_predecessor_record ~store ~require_confirmed record (index:Request.index) =
  let read,read_fence,read_resolution=store_readers ~store in
  validate_node ~read_node:(record_node ~store) ~read ~read_fence ~read_resolution ~require_confirmed
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

module Request = Keeper_librarian_durable_request
module Source = Keeper_librarian_durable_capture
module Owner = Lane_addon_tool_request_owner
module Fence = Keeper_librarian_history_resolution_state
module Intent = Keeper_librarian_history_resolution_intent
module Store = Lane_addon_store
open Result.Syntax
type reader = scope:string -> request_id:string -> (Yojson.Safe.t option, string) result
let require condition message = if condition then Ok () else Error message
let fenced_original ~store ~request ~original =
  let* observed=Fence.read ~store ~scope:original.Owner.scope ~request_id:original.request_id in
  let+ ()=match observed with None -> Ok () | Some fence -> Fence.confirm_binding ~request ~original fence in observed
let validate ~restore ~read ~read_fence ~read_resolution ~require_confirmed request =
  let rec visit seen ~require_confirmed request =
    let id=Request.request_id request in
    let* ()=require (not (List.mem id seen)) "History resolution ancestry contains a cycle" in
    match Request.predecessor request with
    | None -> Ok ()
    | Some predecessor ->
      let owner=Request.physical_owner request in
      let scope=Request.scope owner in
      let* parent=read ~scope ~request_id:predecessor.request_id in
      let* parent=Option.to_result ~none:"History predecessor is absent" parent in
      let* ()=require (parent.Owner.request_digest=predecessor.request_digest) "History predecessor digest differs" in
      let* parent_request=restore ~owner parent in
      let* fence=read_fence ~scope ~request_id:parent.request_id in
      let* ()=match fence with
        | None -> Request.validate_predecessor_link_payload ~read ~require_confirmed request
        | Some json ->
          let* fence=Fence.of_json json in
          let* ()=Fence.confirm_binding ~request:parent_request ~original:parent fence in
          let* stored=read_resolution ~scope ~request_id:parent.request_id in
          let* stored=Option.to_result ~none:"Fenced history parent has no resolution intent" stored in
          let* intents=Intent.decode_published ~scope ~request_id:parent.request_id stored in
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
          let* ()=require (intended.request_digest=Request.body_digest request) "History child differs from its durable intent" in
          let* expected=Source.with_current ~expected_revision:(Source.expected_revision (Request.source request))
            ~current:(Source.input (Request.source request)).current (Request.source parent_request)
            |> Result.map_error Source.error_to_string in
          require (Source.to_json expected=Source.to_json (Request.source request)
            && Request.owner_to_json owner=Request.owner_to_json (Request.physical_owner parent_request))
            "History resolution child changed its original source or owner" in
      visit (id::seen) ~require_confirmed:true parent_request in
  visit [] ~require_confirmed request
let validate_predecessor_payload ~read ~read_fence ~read_resolution ~require_confirmed request =
  validate ~restore:Request.restore_payload ~read ~read_fence ~read_resolution ~require_confirmed request
let confirm_predecessor ~store ~require_confirmed request =
  validate ~restore:Request.restore ~require_confirmed request
    ~read:(fun ~scope ~request_id -> Owner.load ~store ~scope ~request_id |> Result.map_error Owner.error_to_string)
    ~read_fence:(Store.load_history_fence store) ~read_resolution:(Store.load_history_resolution store)
(* Names the acknowledged child only. Its lineage is confirmed by whoever
   reads that child next. *)
let confirmed_resolution_child ~store ~request ~original =
  let* fence=fenced_original ~store ~request ~original in
  match fence with
  | None -> Ok None
  | Some fence ->
    let* json=Store.load_history_resolution store ~scope:original.Owner.scope ~request_id:original.request_id in
    let* json=Option.to_result ~none:"Fenced history original has no resolution intent" json in
    let* intents=Intent.decode_published ~scope:original.scope ~request_id:original.request_id json in
    let* intent=Option.to_result ~none:"Fenced history original has no active resolution" (List.find_opt (fun intent ->
      intent.Intent.expected=fence.expected && intent.actor=fence.actor && intent.reason=fence.reason) intents) in
    match intent.phase with
    | Intent.Child_confirmed child -> Ok (Some child.request_id)
    | Requested | Refused _ | Fenced | Child_intended _ -> Ok None

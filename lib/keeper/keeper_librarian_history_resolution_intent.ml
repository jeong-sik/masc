module Fence = Keeper_librarian_history_resolution_state
module Request = Keeper_librarian_durable_request
module Source = Keeper_librarian_durable_capture
module Owner = Lane_addon_tool_request_owner
module Store = Lane_addon_store
module Progress = Lane_addon_request_progress
module Json = Candle_json
module Current = Keeper_memory_os_current
module Memory = Keeper_memory_os_current_types
module Receipts = Keeper_memory_os_current_receipt_store
module Codec = Keeper_memory_os_current_range_codec
open Result.Syntax

type refusal = Observation_changed | No_longer_eligible of string
type child = {request_id:string;request_digest:string}
type phase = Requested | Refused of refusal | Fenced
  | Child_intended of child | Child_confirmed of child
type memory_commit = {request_id:string;receipts:Memory.durable_range_receipt list}
type t = {
  intent_id:string;scope:string;original_request_id:string;expected:Fence.guard;
  actor:string;reason:string;submitted_at:float;phase:phase;
  memory_commit:memory_commit option;
}
type error = Invalid of string | Conflict of string | Unavailable of string
  | Publication_uncertain of string
let error_to_string = function
  | Invalid detail | Conflict detail | Unavailable detail | Publication_uncertain detail -> detail
let require condition message = if condition then Ok () else Error message
let unavailable result = Result.map_error (fun detail -> Unavailable detail) result
let digest json = let+ value=Lane_addon_action.canonical json in Store.digest (Yojson.Safe.to_string value)
let payload ~scope ~request_id ~expected ~actor ~reason = `Assoc [
  "scope",`String scope;"original_request_id",`String request_id;
  "expected",Fence.guard_to_json expected;"actor",`String actor;"reason",`String reason]
let child_json (child : child) = `Assoc ["request_id",`String child.request_id;"request_digest",`String child.request_digest]
let phase_json = function
  | Requested -> `Assoc ["kind",`String "requested"]
  | Refused Observation_changed -> `Assoc ["kind",`String "refused";"reason",`String "observation_changed";"detail",`Null]
  | Refused (No_longer_eligible detail) -> `Assoc ["kind",`String "refused";"reason",`String "no_longer_eligible";"detail",`String detail]
  | Fenced -> `Assoc ["kind",`String "fenced"]
  | Child_intended child -> `Assoc ["kind",`String "child_intended";"child",child_json child]
  | Child_confirmed child -> `Assoc ["kind",`String "child_confirmed";"child",child_json child]
let public_fields intent = [
  "intent_id",`String intent.intent_id;"original_request_id",`String intent.original_request_id;
  "expected",Fence.guard_to_json intent.expected;"actor",`String intent.actor;
  "reason",`String intent.reason;"submitted_at",`Float intent.submitted_at;"phase",phase_json intent.phase]
let to_public_json intent = `Assoc (("memory_commit",(match intent.memory_commit with
  | None -> `Null | Some proof -> `Assoc ["request_id",`String proof.request_id]))::public_fields intent)
let to_json intent = `Assoc (("scope",`String intent.scope)::
  ("memory_commit",(match intent.memory_commit with None -> `Null | Some proof ->
    `Assoc ["request_id",`String proof.request_id;"receipts",`List (List.map Codec.durable_range_receipt_to_json proof.receipts)]))::
  public_fields intent)
let hash = function
  | `String value when String_util.is_lowercase_sha256_hex value -> Ok value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ -> Error "Invalid resolution digest"
let clock = function
  | `Float value when Float.is_finite value && value>=0. -> Ok value
  | `Int value when value>=0 -> Ok (float_of_int value)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ -> Error "Invalid resolution submission time"
let child_of_json json =
  let context="history resolution child" in
  let* fields=Json.object_fields ~context json in
  let* request_id,fields=Json.field ~context "request_id" Json.as_non_blank fields in
  let* request_digest,fields=Json.field ~context "request_digest" hash fields in
  let+ ()=Json.finish ~context fields in {request_id;request_digest}
let phase_of_json json =
  let context="history resolution phase" in
  let* fields=Json.object_fields ~context json in
  let* kind,fields=Json.field ~context "kind" Json.as_string fields in
  match kind with
  | "requested" -> let+ ()=Json.finish ~context fields in Requested
  | "fenced" -> let+ ()=Json.finish ~context fields in Fenced
  | "refused" ->
    let* reason,fields=Json.field ~context "reason" Json.as_string fields in
    let* detail,fields=Json.field ~context "detail" (Json.as_nullable Json.as_non_blank) fields in
    let* ()=Json.finish ~context fields in
    (match reason,detail with
     | "observation_changed",None -> Ok (Refused Observation_changed)
     | "no_longer_eligible",Some detail -> Ok (Refused (No_longer_eligible detail))
     | _ -> Error "Unknown history resolution refusal")
  | "child_intended" | "child_confirmed" ->
    let* child,fields=Json.field ~context "child" child_of_json fields in
    let+ ()=Json.finish ~context fields in
    if kind="child_intended" then Child_intended child else Child_confirmed child
  | _ -> Error "Unknown history resolution phase"
let memory_commit_of_json json =
  let context="history resolution Memory receipt" in
  let* fields=Json.object_fields ~context json in
  let* request_id,fields=Json.field ~context "request_id" Json.as_non_blank fields in
  let* receipts,fields=Json.field ~context "receipts" (Json.as_list (fun json ->
    Codec.durable_range_receipt_of_json json |> Result.map_error Keeper_memory_os_types.wire_error_to_string)) fields in
  let* ()=Json.finish ~context fields in
  let+ ()=require (receipts<>[] && List.for_all (function Memory.Committed _ -> true | Prepared _ -> false) receipts)
    "Resolution completion has no committed Memory receipts" in {request_id;receipts}
let child intent = match intent.phase with
  | Child_intended child | Child_confirmed child -> Some child
  | Requested | Refused _ | Fenced -> None
let same_atom (left:Current.durable_range_id) (right:Current.durable_range_id) =
  {left with unread_messages=[]}={right with unread_messages=[]}
let same_official (left:Current.official_range_id) (right:Current.official_range_id) =
  {left with unread_messages=[]}={right with unread_messages=[]}
let matches_source source receipt = match Receipts.receipt_range_id receipt with
  | Memory.Atom_range range -> Option.exists (fun expected -> same_atom expected range) (Source.range_id source)
  | Official_range range -> Option.exists (fun expected -> same_official expected range) (Source.official_range_id source)
  | Explicit_candidate _ | Explicit_candidate_with_recall _ -> false
let complete_receipts source receipts =
  List.for_all (matches_source source) receipts
  && (match Source.range_id source with None -> true | Some expected ->
    List.exists (fun receipt -> match Receipts.receipt_range_id receipt with
      | Memory.Atom_range range -> same_atom expected range
      | Official_range _ | Explicit_candidate _ | Explicit_candidate_with_recall _ -> false) receipts)
  && (match Source.official_range_id source with None -> true | Some expected ->
    List.exists (fun receipt -> match Receipts.receipt_range_id receipt with
      | Memory.Official_range range -> same_official expected range
      | Atom_range _ | Explicit_candidate _ | Explicit_candidate_with_recall _ -> false) receipts)
let of_json json =
  let context="history resolution intent" in
  let* fields=Json.object_fields ~context json in
  let* intent_id,fields=Json.field ~context "intent_id" hash fields in
  let* scope,fields=Json.field ~context "scope" Json.as_non_blank fields in
  let* original_request_id,fields=Json.field ~context "original_request_id" Json.as_non_blank fields in
  let* expected,fields=Json.field ~context "expected" Fence.guard_of_json fields in
  let* actor,fields=Json.field ~context "actor" Json.as_non_blank fields in
  let* reason,fields=Json.field ~context "reason" Json.as_non_blank fields in
  let* submitted_at,fields=Json.field ~context "submitted_at" clock fields in
  let* phase,fields=Json.field ~context "phase" phase_of_json fields in
  let* memory_commit,fields=Json.field ~context "memory_commit" (Json.as_nullable memory_commit_of_json) fields in
  let* ()=Json.finish ~context fields in
  let* expected_id=digest (payload ~scope ~request_id:original_request_id ~expected ~actor ~reason) in
  let* id_scope=Request.scope_of_request_id original_request_id in
  let* ()=require (intent_id=expected_id && id_scope=scope) "Resolution intent identity differs" in
  (* The child is named by ID and digest. Its request is the body file that
     digest names; whoever reads that body checks it there. The request ID
     carries its scope. *)
  let* ()=match phase with
    | Requested | Refused _ | Fenced -> Ok ()
    | Child_intended expected_child | Child_confirmed expected_child ->
      let* child_scope=Request.scope_of_request_id expected_child.request_id in
      require (child_scope=scope && expected_child.request_id<>original_request_id)
        "Resolution child binding differs" in
  (* [observe_memory_commit] proves the receipts against the completed
     original's source when it writes them. A reader does not repeat that. *)
  let* ()=match memory_commit,phase with
    | None,(Requested | Refused _ | Fenced | Child_intended _ | Child_confirmed _) -> Ok ()
    | Some proof,Child_confirmed _ ->
      let* proof_scope=Request.scope_of_request_id proof.request_id in
      require (proof_scope=scope) "Resolution completion belongs to another scope"
    | Some _,(Requested | Refused _ | Fenced | Child_intended _) ->
      Error "Resolution completion precedes its child acknowledgement" in
  Ok {intent_id;scope;original_request_id;expected;actor;reason;submitted_at;phase;memory_commit}
let envelope ~scope ~request_id intents = `Assoc ["schema",`String "keeper.librarian.history-resolution.v2";
  "scope",`String scope;"request_id",`String request_id;"intents",`List (List.map to_json intents)]
let decode ~scope ~request_id json =
  let context="history resolution envelope" in
  let* fields=Json.object_fields ~context json in
  let* schema,fields=Json.field ~context "schema" Json.as_string fields in
  let* stored_scope,fields=Json.field ~context "scope" Json.as_string fields in
  let* stored_id,fields=Json.field ~context "request_id" Json.as_string fields in
  let* values,fields=Json.field ~context "intents" (Json.as_list of_json) fields in
  let* ()=Json.finish ~context fields in
  let* ()=require (schema="keeper.librarian.history-resolution.v2" && stored_scope=scope && stored_id=request_id
    && values<>[] && List.for_all (fun intent -> intent.scope=scope && intent.original_request_id=request_id) values)
    "History resolution envelope binding differs" in
  let ids=List.map (fun intent -> intent.intent_id) values in
  let* ()=require (List.length ids=List.length (List.sort_uniq String.compare ids)) "Duplicate resolution intent" in
  let rec history = function
    | [] | [_] -> Ok ()
    | first::(next::_ as rest) ->
      (match first.phase with
       | Refused _ ->
         let* ()=require (first.expected<>next.expected) "A refused resolution needs a new observation" in
         history rest
       | Requested | Fenced | Child_intended _ | Child_confirmed _ ->
         Error "History resolution has multiple active intents") in
  let+ ()=history values in values
let decode_published = decode
let load ~store ~scope ~request_id =
  let* json=Store.load_history_resolution store ~scope ~request_id |> unavailable in
  let+ values=match json with None -> Ok [] | Some json -> decode ~scope ~request_id json |> unavailable in
  json,values
let scope ~config ~keeper_name ~request_id =
  let* actual=Request.discovery_scope ~base_path:config.Workspace.base_path
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path) ~keeper_id:keeper_name |> unavailable in
  let* expected=Request.scope_of_request_id request_id |> Result.map_error (fun detail -> Invalid detail) in
  if actual=expected then Ok actual else Error (Invalid "Resolution original belongs to another workspace or Keeper")
let persist ~store ~scope ~request_id ~previous values =
  let* next=Lane_addon_action.canonical (envelope ~scope ~request_id values)
    |> Result.map_error (fun detail -> Invalid detail) in
  let* _=decode ~scope ~request_id next |> Result.map_error (fun detail -> Invalid detail) in
  match Store.publish_history_resolution store ~scope ~request_id ~expected:previous ~next with
  | Error detail -> Error (Publication_uncertain detail)
  | Ok Store.History_resolution_changed -> Error (Conflict "Resolution changed before publication")
  | Ok (History_resolution_unconfirmed detail) -> Error (Publication_uncertain detail)
  | Ok History_resolution_stored ->
    let* observed=Store.load_history_resolution store ~scope ~request_id
      |> Result.map_error (fun detail -> Publication_uncertain detail) in
    if observed=Some next then Ok () else Error (Publication_uncertain "Resolution publication readback differs")
let read ~config ~keeper_name ~request_id =
  let* scope=scope ~config ~keeper_name ~request_id in
  let+ _,values=load ~store:(Store.of_config config) ~scope ~request_id in values
let submit ~config ~keeper_name ~request_id ~expected ~actor ~reason ~now =
  let* scope=scope ~config ~keeper_name ~request_id in
  let store=Store.of_config config in
  let* intent_id=digest (payload ~scope ~request_id ~expected ~actor ~reason) |> Result.map_error (fun detail -> Invalid detail) in
  let* candidate=of_json (to_json {intent_id;scope;original_request_id=request_id;expected;actor;reason;
    submitted_at=now;phase=Requested;memory_commit=None}) |> Result.map_error (fun detail -> Invalid detail) in
  let* previous,values=load ~store ~scope ~request_id in
  match List.find_opt (fun intent -> intent.intent_id=intent_id) values with
  | Some existing -> Ok (existing,true)
  | None ->
    let* ()=match List.rev values with
      | [] -> Ok ()
      | latest::_ ->
        (match latest.phase with
         | Refused _ when latest.expected<>expected -> Ok ()
         | Refused _ | Requested | Fenced | Child_intended _ | Child_confirmed _ ->
           Error (Conflict "Original already owns an active resolution or needs a new observation")) in
    let* fence=Fence.read ~store ~scope ~request_id |> unavailable in
    let* ()=match fence with None -> Ok () | Some _ -> Error (Conflict "Original is already fenced") in
    let+ ()=persist ~store ~scope ~request_id ~previous (values@[candidate]) in candidate,false
let active_for_keeper ~config ~keeper_name =
  let store=Store.of_config config in
  let* scope=Request.discovery_scope ~base_path:config.Workspace.base_path
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path) ~keeper_id:keeper_name |> unavailable in
  let* rows=Store.history_resolution_inventory store ~scope |> unavailable in
  List.fold_left (fun result (name,json) ->
    let* values=result in
    let* request_id=match json with
      | `Assoc fields -> (match List.assoc_opt "request_id" fields with Some (`String value) -> Ok value
        | _ -> Error (Unavailable "Resolution inventory has no original ID"))
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error (Unavailable "Invalid resolution inventory record") in
    let* ()=if name=Store.digest request_id ^ ".json" then Ok () else Error (Unavailable "Resolution inventory filename differs") in
    let* intents=decode ~scope ~request_id json |> unavailable in
    match List.rev intents with
    | [] -> Ok values
    | intent::_ ->
      (match intent.memory_commit with
       | Some _ -> Ok values
       | None ->
         (match intent.phase with
          | Refused _ -> Ok values
          | Requested | Fenced | Child_intended _ | Child_confirmed _ -> Ok (intent::values)))) (Ok []) rows
let reload ~store expected =
  let* _,values=load ~store ~scope:expected.scope ~request_id:expected.original_request_id in
  Option.to_result ~none:(Unavailable "Resolution intent disappeared")
    (List.find_opt (fun intent -> intent.intent_id=expected.intent_id) values)
let update ~store ~expected change =
  let* previous,values=load ~store ~scope:expected.scope ~request_id:expected.original_request_id in
  let* actual=Option.to_result ~none:(Unavailable "Resolution intent disappeared")
    (List.find_opt (fun intent -> intent.intent_id=expected.intent_id) values) in
  let* actual_digest=digest (to_json actual) |> unavailable in
  let* expected_digest=digest (to_json expected) |> unavailable in
  let* ()=if actual_digest=expected_digest then Ok () else Error (Conflict "Resolution progress changed") in
  let* next=change actual |> Result.map_error (fun detail -> Conflict detail) in
  let values=List.map (fun intent -> if intent.intent_id=next.intent_id then next else intent) values in
  let+ ()=persist ~store ~scope:expected.scope ~request_id:expected.original_request_id ~previous values in next
let refuse ~store ~expected refusal = update ~store ~expected (fun actual ->
  let+ ()=match actual.phase,refusal with
    | Requested,(Observation_changed | No_longer_eligible _) -> Ok ()
    | Fenced,No_longer_eligible _ ->
      let* fence=Fence.read ~store ~scope:actual.scope ~request_id:actual.original_request_id in
      let* fence=Option.to_result ~none:"Resolution fence is absent" fence in
      require (fence.expected=actual.expected && fence.actor=actual.actor && fence.reason=actual.reason)
        "Resolution refusal has another immutable fence"
    | Fenced,Observation_changed
    | (Refused _ | Child_intended _ | Child_confirmed _),(Observation_changed | No_longer_eligible _) ->
      Error "Only a resolution without a child intent can be refused" in
  {actual with phase=Refused refusal})
let confirm_fence ~store ~expected fence = update ~store ~expected (fun actual ->
  let* ()=require (actual.phase=Requested && fence.Fence.scope=actual.scope
    && fence.request_id=actual.original_request_id && fence.expected=actual.expected
    && fence.actor=actual.actor && fence.reason=actual.reason) "Resolution fence binding differs" in
  let* stored=Fence.read ~store ~scope:actual.scope ~request_id:actual.original_request_id in
  let+ ()=require (Option.map Fence.to_json stored=Some (Fence.to_json fence)) "Resolution fence is not durably observed" in
  {actual with phase=Fenced})
let intend_child ~store ~expected request = update ~store ~expected (fun actual ->
  let* ()=require (actual.phase=Fenced) "Resolution already has a child intent" in
  let* fence=Fence.read ~store ~scope:actual.scope ~request_id:actual.original_request_id in
  let* fence=Option.to_result ~none:"Resolution fence is absent" fence in
  let* parent=Owner.load ~store ~scope:actual.scope ~request_id:actual.original_request_id |> Result.map_error Owner.error_to_string in
  let* parent=Option.to_result ~none:"Resolution original is absent" parent in
  let* owner=Request.owner_of_json fence.physical_owner in
  let* parent_request=Request.restore_payload ~owner parent in
  let* source_hash=digest (Source.to_json (Request.source parent_request)) in
  let* ()=require (parent.request_digest=fence.request_digest && source_hash=fence.source_sha256)
    "Resolution original immutable binding changed" in
  let* rebased=Source.with_current ~expected_revision:(Source.expected_revision (Request.source request))
    ~current:(Source.input (Request.source request)).current (Request.source parent_request)
    |> Result.map_error Source.error_to_string in
  let* ()=require (Source.to_json rebased=Source.to_json (Request.source request)) "Resolution child changed its original source" in
  let* ()=match Request.predecessor request with
    | Some predecessor -> require (predecessor.request_id=parent.request_id && predecessor.request_digest=parent.request_digest)
      "Resolution child has another original predecessor"
    | None -> Error "Resolution child has no original predecessor" in
  (* The child's request is durable under its digest before the intent names
     it. The body is the one file retaining the child writes. *)
  let* staged=Owner.prepare_successor ~store ~scope:actual.scope
    ~request_id:(Request.request_id request) ~request:(Request.to_json request)
    |> Result.map_error Owner.error_to_string in
  let+ ()=require (staged.request_digest=Request.body_digest request)
    "Resolution child body differs from its request digest" in
  {actual with phase=Child_intended {request_id=staged.request_id;request_digest=staged.request_digest}})
let confirm_child ~store ~expected (child:Owner.retained) = update ~store ~expected (fun actual ->
  let* expected_child=match actual.phase with Child_intended child -> Ok child
    | Requested | Refused _ | Fenced | Child_confirmed _ -> Error "Resolution child is not awaiting acknowledgement" in
  let+ ()=require (child.scope=actual.scope && child.request_id=expected_child.request_id
    && child.request_digest=expected_child.request_digest
    && Progress.phase child.progress=Progress.Captured) "Unacknowledged resolution child differs or has execution progress" in
  {actual with phase=Child_confirmed expected_child})
let observe_memory_commit ~store ~expected ~request ~(completed:Owner.retained) =
  update ~store ~expected (fun actual ->
    let* child=match actual.phase with Child_confirmed child -> Ok child
      | Requested | Refused _ | Fenced | Child_intended _ -> Error "Resolution child is not acknowledged" in
    (* The completed original is the resolution child or a replacement that
       descends from it. Only the second needs the child's own body. *)
    let* root=if Request.request_id request=child.request_id then
        let+ ()=require (Request.body_digest request=child.request_digest)
          "Resolution child differs from its durable intent" in request
      else
        let* record=Owner.load ~store ~scope:actual.scope ~request_id:child.request_id
          |> Result.map_error Owner.error_to_string in
        let* record=Option.to_result ~none:"Resolution child is absent" record in
        let* ()=require (record.request_digest=child.request_digest)
          "Resolution child differs from its durable intent" in
        Request.restore_payload ~owner:(Request.physical_owner request) record in
    let* source=Source.with_current ~expected_revision:(Source.expected_revision (Request.source request))
      ~current:(Source.input (Request.source request)).current (Request.source root)
      |> Result.map_error Source.error_to_string in
    let* ()=require (Option.is_none actual.memory_commit && Source.to_json source=Source.to_json (Request.source request)
      && Request.scope (Request.physical_owner request)=actual.scope)
      "Resolution completion changed its original source or was already recorded" in
    let* ()=Request.confirm_record request completed in
    let* ()=match Progress.phase completed.progress with Finished _ -> Ok ()
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> Error "Resolution child is not finished" in
    let owner=Request.physical_owner request in
    let keepers_dir=Request.keepers_dir owner and keeper_id=Request.keeper_id owner in
    let* receipts=Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id (fun () ->
      File_lock_eio.with_lock (Current.path_for_keepers_dir ~keepers_dir ~keeper_id) (fun () ->
        let* ()=Request.confirm_owner request in
        let* snapshot=Current.read_locked_for_keepers_dir ~keepers_dir ~keeper_id in
        let* snapshot=Option.to_result ~none:"Resolution Memory snapshot is absent" snapshot in
        let* bytes=Option.to_result ~none:"Resolution Memory snapshot disappeared"
          (Fs_compat.load_file_opt (Current.path_for_keepers_dir ~keepers_dir ~keeper_id)) in
        let* reading=Receipts.read_durable_range_receipts_cached ~keepers_dir ~keeper_id in
        let* receipts=match reading with Receipts.Cached_receipts entry -> Ok entry.receipts
          | Uncached_receipts (receipts,[]) -> Ok receipts
          | Uncached_receipts (_,_::_) -> Error "Resolution Memory receipts contain unreadable entries" in
        let receipts=List.filter (fun receipt -> matches_source source receipt && match receipt with
          | Memory.Committed {snapshot_revision;snapshot_sha256;_} ->
            snapshot.revision>snapshot_revision || (snapshot.revision=snapshot_revision && Store.digest bytes=snapshot_sha256)
          | Prepared _ -> false) receipts in
        let+ ()=require (receipts<>[] && complete_receipts source receipts) "Resolution Memory commit is not receipt-proved" in receipts)) in
    Ok {actual with memory_commit=Some {request_id=completed.request_id;receipts}})

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
module Program_settlement = Keeper_librarian_history_program_settlement
open Result.Syntax

type refusal = Observation_changed | No_longer_eligible of string
type origin = Worker_absence | Same_binding_cut of Fence.cut_basis
type child = {request_id:string;request_digest:string}
type prepared_child = {child:child;request:Request.t}
type phase = Requested | Refused of refusal | Fenced
  | Child_prepared of prepared_child | Child_intended of child | Child_confirmed of child
type memory_commit = {request_id:string;receipts:Memory.durable_range_receipt list;
  program:Program_settlement.retained option}
type t = {
  intent_id:string;scope:string;original_request_id:string;expected:Fence.guard;origin:origin;
  actor:string;reason:string;submitted_at:float;phase:phase;
  memory_commit:memory_commit option;
}
type error = Invalid of string | Conflict of string | Unavailable of string
  | Publication_uncertain of string | Host_claim_busy
let error_to_string = function
  | Host_claim_busy -> "Original history execution claim is busy"
  | Invalid detail | Conflict detail | Unavailable detail | Publication_uncertain detail -> detail
let require condition message = if condition then Ok () else Error message
let unavailable result = Result.map_error (fun detail -> Unavailable detail) result
let digest json = let+ value=Lane_addon_action.canonical json in Store.digest (Yojson.Safe.to_string value)
let origin_fields = function
  | Worker_absence -> []
  | Same_binding_cut basis -> ["origin",`Assoc ["kind",`String "same_binding_cut";"basis",Fence.cut_to_json basis]]
let origin_of_json json =
  let context="history resolution origin" in
  let* fields=Json.object_fields ~context json in
  let* kind,fields=Json.field ~context "kind" Json.as_string fields in
  let* ()=require (kind="same_binding_cut") "Unknown history resolution origin" in
  let* basis,fields=Json.field ~context "basis" Fence.cut_of_json fields in
  let+ ()=Json.finish ~context fields in Same_binding_cut basis
let payload ~origin ~scope ~request_id ~expected ~actor ~reason = `Assoc (origin_fields origin @ [
  "scope",`String scope;"original_request_id",`String request_id;
  "expected",Fence.guard_to_json expected;"actor",`String actor;"reason",`String reason])
let child_json (child : child) = `Assoc ["request_id",`String child.request_id;"request_digest",`String child.request_digest]
let phase_json = function
  | Requested -> `Assoc ["kind",`String "requested"]
  | Refused Observation_changed -> `Assoc ["kind",`String "refused";"reason",`String "observation_changed";"detail",`Null]
  | Refused (No_longer_eligible detail) -> `Assoc ["kind",`String "refused";"reason",`String "no_longer_eligible";"detail",`String detail]
  | Fenced -> `Assoc ["kind",`String "fenced"]
  | Child_prepared prepared -> `Assoc ["kind",`String "child_prepared";
      "child",child_json prepared.child;"request",Request.to_json prepared.request]
  | Child_intended child -> `Assoc ["kind",`String "child_intended";"child",child_json child]
  | Child_confirmed child -> `Assoc ["kind",`String "child_confirmed";"child",child_json child]
let public_phase_json = function
  | Child_prepared prepared -> `Assoc ["kind",`String "child_prepared";"child",child_json prepared.child]
  | (Requested | Refused _ | Fenced | Child_intended _ | Child_confirmed _) as phase -> phase_json phase
let public_fields ~phase intent = origin_fields intent.origin @ [
  "intent_id",`String intent.intent_id;"original_request_id",`String intent.original_request_id;
  "expected",Fence.guard_to_json intent.expected;"actor",`String intent.actor;
  "reason",`String intent.reason;"submitted_at",`Float intent.submitted_at;"phase",phase]
let to_public_json intent = `Assoc (("memory_commit",(match intent.memory_commit with
  | None -> `Null | Some proof -> `Assoc ["request_id",`String proof.request_id]))::
  public_fields ~phase:(public_phase_json intent.phase) intent)
let to_json intent = `Assoc (("scope",`String intent.scope)::
  ("memory_commit",(match intent.memory_commit with None -> `Null | Some proof ->
    (match proof.program with
     | Some program -> Program_settlement.retained_to_json program
     | None -> `Assoc ["request_id",`String proof.request_id;
         "receipts",`List (List.map Codec.durable_range_receipt_to_json proof.receipts)])))::
  public_fields ~phase:(phase_json intent.phase) intent)
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
let prepared_request_of_json json =
  let* owner=match json with
    | `Assoc fields ->
      let* owner=Option.to_result ~none:"Prepared resolution child has no physical owner"
        (List.assoc_opt "owner" fields) in
      Request.owner_of_json owner
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error "Prepared resolution child must be a complete request" in
  Request.of_json ~owner json
let phase_of_json json =
  let context="history resolution phase" in
  let* fields=Json.object_fields ~context json in
  let* kind,fields=Json.field ~context "kind" Json.as_string fields in
  match kind with
  | "requested" -> let+ ()=Json.finish ~context fields in Requested
  | "fenced" -> let+ ()=Json.finish ~context fields in Fenced
  | "child_prepared" ->
    let* child,fields=Json.field ~context "child" child_of_json fields in
    let* request,fields=Json.field ~context "request" prepared_request_of_json fields in
    let* ()=Json.finish ~context fields in
    let+ ()=require (child.request_id=Request.request_id request && child.request_digest=Request.body_digest request)
      "Prepared resolution child differs from its complete request" in
    Child_prepared {child;request}
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
  match List.assoc_opt "kind" fields with
  | Some _ ->
    let+ program=Program_settlement.retained_of_json json in
    {request_id=program.request_id;receipts=program.receipts;program=Some program}
  | None ->
  let* request_id,fields=Json.field ~context "request_id" Json.as_non_blank fields in
  let* receipts,fields=Json.field ~context "receipts" (Json.as_list (fun json ->
    Codec.durable_range_receipt_of_json json |> Result.map_error Keeper_memory_os_types.wire_error_to_string)) fields in
  let* ()=Json.finish ~context fields in
  let+ ()=require (receipts<>[] && List.for_all (function Memory.Committed _ -> true | Prepared _ -> false) receipts)
    "Resolution completion has no committed Memory receipts" in {request_id;receipts;program=None}
let child intent = match intent.phase with
  | Child_intended child | Child_confirmed child -> Some child
  | Requested | Refused _ | Fenced | Child_prepared _ -> None
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
  let* origin,fields=match List.assoc_opt "origin" fields with
    | None -> Ok (Worker_absence,fields)
    | Some _ -> Json.field ~context "origin" origin_of_json fields in
  let* ()=Json.finish ~context fields in
  let* ()=match origin with
    | Worker_absence -> Ok ()
    | Same_binding_cut basis -> require (basis.request_id=original_request_id) "Cut command names another original" in
  let* expected_id=digest (payload ~origin ~scope ~request_id:original_request_id ~expected ~actor ~reason) in
  let* id_scope=Request.scope_of_request_id original_request_id in
  let* ()=require (intent_id=expected_id && id_scope=scope) "Resolution intent identity differs" in
  (* The child is named by ID and digest. Its request is the body file that
     digest names; whoever reads that body checks it there. The request ID
     carries its scope. *)
  let* ()=match phase with
    | Requested | Refused _ | Fenced -> Ok ()
    | Child_prepared prepared ->
      let* child_scope=Request.scope_of_request_id prepared.child.request_id in
      let* ()=require (child_scope=scope && prepared.child.request_id<>original_request_id)
        "Prepared resolution child belongs to another scope or its parent" in
      (match Request.predecessor prepared.request with
       | Some predecessor -> require (predecessor.request_id=original_request_id)
           "Prepared resolution child names another original predecessor"
       | None -> Error "Prepared resolution child has no original predecessor")
    | Child_intended expected_child | Child_confirmed expected_child ->
      let* child_scope=Request.scope_of_request_id expected_child.request_id in
      require (child_scope=scope && expected_child.request_id<>original_request_id)
        "Resolution child binding differs" in
  (* [observe_memory_commit] proves the receipts against the completed
     original's source when it writes them. A reader does not repeat that. *)
  let* ()=match memory_commit,phase with
    | None,(Requested | Refused _ | Fenced | Child_prepared _ | Child_intended _ | Child_confirmed _) -> Ok ()
    | Some proof,Child_confirmed _ ->
      let* proof_scope=Request.scope_of_request_id proof.request_id in
      let* ()=require (proof_scope=scope) "Resolution completion belongs to another scope" in
      (match proof.program,origin with
       | None,(Worker_absence | Same_binding_cut _) -> Ok ()
       | Some program,(Worker_absence | Same_binding_cut _) -> require (Request.scope program.owner=scope)
           "Ordered completion has another physical owner")
    | Some _,(Requested | Refused _ | Fenced | Child_prepared _ | Child_intended _) ->
      Error "Resolution completion precedes its child acknowledgement" in
  Ok {intent_id;scope;original_request_id;expected;origin;actor;reason;submitted_at;phase;memory_commit}
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
       | Requested | Fenced | Child_prepared _ | Child_intended _ | Child_confirmed _ ->
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
let submit_origin ~origin ~config ~keeper_name ~request_id ~expected ~actor ~reason ~now =
  let* scope=scope ~config ~keeper_name ~request_id in
  let store=Store.of_config config in
  let* intent_id=digest (payload ~origin ~scope ~request_id ~expected ~actor ~reason) |> Result.map_error (fun detail -> Invalid detail) in
  let* candidate=of_json (to_json {intent_id;scope;original_request_id=request_id;expected;origin;actor;reason;
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
         | Refused _ | Requested | Fenced | Child_prepared _ | Child_intended _ | Child_confirmed _ ->
           Error (Conflict "Original already owns an active resolution or needs a new observation")) in
    let* fence=Fence.read ~store ~scope ~request_id |> unavailable in
    let* ()=match fence with None -> Ok () | Some _ -> Error (Conflict "Original is already fenced") in
    let+ ()=persist ~store ~scope ~request_id ~previous (values@[candidate]) in candidate,false
let submit ~config ~keeper_name ~request_id ~expected ~actor ~reason ~now =
  submit_origin ~origin:Worker_absence ~config ~keeper_name ~request_id ~expected ~actor ~reason ~now
let submit_cut ~config ~keeper_name ~request_id ~expected ~basis ~actor ~reason ~now =
  submit_origin ~origin:(Same_binding_cut basis) ~config ~keeper_name ~request_id ~expected ~actor ~reason ~now
(* One file of a scope's resolution directory: the record names its own
   original, the file is named by that original, and the envelope decodes. *)
let decode_inventory_row ~scope ~name json =
  let* request_id=match json with
    | `Assoc fields -> (match List.assoc_opt "request_id" fields with Some (`String value) -> Ok value
      | _ -> Error "Resolution inventory has no original ID")
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "Invalid resolution inventory record" in
  let* ()=require (name=Store.digest request_id ^ ".json") "Resolution inventory filename differs" in
  decode ~scope ~request_id json
let check_published_file ~group ~name json =
  let* scope=match json with
    | `Assoc fields -> (match List.assoc_opt "scope" fields with Some (`String value) -> Ok value
      | _ -> Error "Resolution record has no scope")
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "Invalid resolution inventory record" in
  let* ()=require (Store.digest scope=group) "Resolution record is stored under another scope" in
  decode_inventory_row ~scope ~name json |> Result.map (fun _ -> ())
let active_for_keeper ~config ~keeper_name =
  let store=Store.of_config config in
  let* scope=Request.discovery_scope ~base_path:config.Workspace.base_path
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path) ~keeper_id:keeper_name |> unavailable in
  let* rows=Store.history_resolution_inventory store ~scope |> unavailable in
  List.fold_left (fun result (name,json) ->
    let* values=result in
    let* intents=decode_inventory_row ~scope ~name json |> unavailable in
    match List.rev intents with
    | [] -> Ok values
    | intent::_ ->
      (match intent.memory_commit with
       | Some _ -> Ok values
       | None ->
         (match intent.phase with
          | Refused _ -> Ok values
          | Requested | Fenced | Child_prepared _ | Child_intended _ | Child_confirmed _ -> Ok (intent::values)))) (Ok []) rows
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
let matches_fence intent (fence:Fence.t) =
  let* ()=require (fence.scope=intent.scope && fence.request_id=intent.original_request_id
    && fence.actor=intent.actor && fence.reason=intent.reason)
    "History fence belongs to another resolution command" in
  match intent.origin,fence.authority with
  | Worker_absence,Fence.Worker_absent -> require (intent.expected=fence.expected) "Absence fence guard differs"
  | Same_binding_cut expected,Excluded_cut actual ->
    require (expected=actual
      && intent.expected.owner_record_sha256=fence.expected.owner_record_sha256
      && intent.expected.cursors_sha256=fence.expected.cursors_sha256) "Cut fence command basis differs"
  | Worker_absence,Excluded_cut _ | Same_binding_cut _,Worker_absent -> Error "History fence and command origins differ"
let require_successor_authority intent fence =
  let* ()=matches_fence intent fence in
  match intent.origin with
  | Worker_absence -> Fence.require_resolution_successor_authority fence
  | Same_binding_cut _ ->
    match intent.phase with
    | Fenced | Child_prepared _ | Child_intended _ | Child_confirmed _ -> Ok ()
    | Requested | Refused _ -> Error "Cut command has no durable successor grant"
let refuse ~store ~expected refusal = update ~store ~expected (fun actual ->
  let+ ()=match actual.phase,refusal with
    | Requested,(Observation_changed | No_longer_eligible _) -> Ok ()
    | Fenced,No_longer_eligible _ ->
      let* fence=Fence.read ~store ~scope:actual.scope ~request_id:actual.original_request_id in
      let* fence=Option.to_result ~none:"Resolution fence is absent" fence in
      require_successor_authority actual fence
    | Fenced,Observation_changed
    | (Refused _ | Child_prepared _ | Child_intended _ | Child_confirmed _),(Observation_changed | No_longer_eligible _) ->
      Error "Only a resolution without a child intent can be refused" in
  {actual with phase=Refused refusal})
let confirm_cut_fence ~store ~expected grant =
  let* fence=Keeper_librarian_history_resolution.confirm_cut_grant ~store grant |> unavailable in
  let* ()=(match expected.origin with
    | Same_binding_cut _ -> matches_fence expected fence
    | Worker_absence -> Error "An absence command cannot receive a Cut grant") |> unavailable in
  let* next=update ~store ~expected (fun actual ->
    let* ()=matches_fence actual fence in
    match actual.phase with
    | Requested -> Ok {actual with phase=Fenced}
    | Refused _ | Fenced | Child_prepared _ | Child_intended _ | Child_confirmed _ ->
      Error "Resolution command no longer awaits its Cut grant") in
  let+ _=Keeper_librarian_history_resolution.confirm_cut_grant ~store grant |> unavailable in next
let confirm_fence ~store ~expected fence = update ~store ~expected (fun actual ->
  let* ()=Fence.require_resolution_successor_authority fence in
  let* ()=matches_fence actual fence in
  let* ()=require (actual.phase=Requested && fence.Fence.scope=actual.scope
    && fence.request_id=actual.original_request_id && fence.expected=actual.expected
    && fence.actor=actual.actor && fence.reason=actual.reason) "Resolution fence binding differs" in
  let* stored=Fence.read ~store ~scope:actual.scope ~request_id:actual.original_request_id in
  let+ ()=require (Option.map Fence.to_json stored=Some (Fence.to_json fence)) "Resolution fence is not durably observed" in
  {actual with phase=Fenced})
let validate_child ~store actual request =
  let* fence=Fence.read ~store ~scope:actual.scope ~request_id:actual.original_request_id in
  let* fence=Option.to_result ~none:"Resolution fence is absent" fence in
  let* ()=require_successor_authority actual fence in
  let* parent=Owner.load ~store ~scope:actual.scope ~request_id:actual.original_request_id |> Result.map_error Owner.error_to_string in
  let* parent=Option.to_result ~none:"Resolution original is absent" parent in
  let* owner=Request.owner_of_json fence.physical_owner in
  let* parent_request=Request.restore_payload ~owner parent in
  let* ()=Fence.confirm_binding ~request:parent_request ~original:parent fence in
  let* ()=match actual.origin with
    | Worker_absence -> Ok ()
    | Same_binding_cut _ -> require (Lane_addon_captured_destination.same_semantic
        (Request.destination request) (Request.destination parent_request))
        "Cut continuation changed its original semantic destination" in
  let* ()=require (Request.physical_owner request=owner && Request.scope owner=actual.scope
    && Request.request_id request<>parent.request_id)
    "Resolution child changed its original owner or identity" in
  let* ()=Request.confirm_owner request in
  let* rebased=Source.with_current ~expected_revision:(Source.expected_revision (Request.source request))
    ~current:(Source.input (Request.source request)).current (Request.source parent_request)
    |> Result.map_error Source.error_to_string in
  let* ()=require (Source.to_json rebased=Source.to_json (Request.source request)) "Resolution child changed its original source" in
  match Request.predecessor request with
    | Some predecessor -> require (predecessor.request_id=parent.request_id && predecessor.request_digest=parent.request_digest)
      "Resolution child has another original predecessor"
    | None -> Error "Resolution child has no original predecessor"
let prepare_child ~store ~expected request = update ~store ~expected (fun actual ->
  let* ()=require (actual.phase=Fenced) "Resolution already has a child preparation" in
  let+ ()=validate_child ~store actual request in
  let child={request_id=Request.request_id request;request_digest=Request.body_digest request} in
  {actual with phase=Child_prepared {child;request}})
let intend_child ~store ~expected request =
  let* prepared=match expected.phase with
    | Child_prepared prepared -> Ok prepared
    | Requested | Refused _ | Fenced | Child_intended _ | Child_confirmed _ ->
      Error (Conflict "Resolution child has no retained preparation") in
  let* ()=require (Request.request_id request=prepared.child.request_id
    && Request.body_digest request=prepared.child.request_digest)
    "Resolution child differs from its retained preparation" |> unavailable in
  let* ()=validate_child ~store expected request |> unavailable in
  (* A restart takes the complete request from Child_prepared. Neither a
     body write nor an uncertain compacting CAS can make it mint a new ID. *)
  let* staged=Owner.prepare_successor ~store ~scope:expected.scope
    ~request_id:(Request.request_id request) ~request:(Request.to_json request)
    |> Result.map_error (fun error -> Publication_uncertain (Owner.error_to_string error)) in
  let* observed=Owner.load_successor_request ~store ~scope:expected.scope staged
    |> Result.map_error (fun error -> Publication_uncertain (Owner.error_to_string error)) in
  let* canonical=Lane_addon_action.canonical (Request.to_json prepared.request) |> unavailable in
  let* ()=require (staged.request_id=prepared.child.request_id
    && staged.request_digest=prepared.child.request_digest && observed=canonical)
    "Resolution child body readback differs from its retained preparation"
    |> Result.map_error (fun detail -> Publication_uncertain detail) in
  update ~store ~expected (fun actual ->
    let+ ()=match actual.phase with
      | Child_prepared current -> require (current.child=prepared.child
          && Request.body_digest current.request=staged.request_digest) "Resolution child preparation changed"
      | Requested | Refused _ | Fenced | Child_intended _ | Child_confirmed _ ->
        Error "Resolution child preparation is no longer awaiting its body" in
    {actual with phase=Child_intended prepared.child})
let confirm_child ~store ~expected child = update ~store ~expected (fun actual ->
  let module Record=Owner.Record in
  let* expected_child=match actual.phase with Child_intended child -> Ok child
    | Requested | Refused _ | Fenced | Child_prepared _ | Child_confirmed _ -> Error "Resolution child is not awaiting acknowledgement" in
  let+ ()=require (Record.scope child=actual.scope && Record.request_id child=expected_child.request_id
    && Record.request_digest child=expected_child.request_digest
    && Progress.phase (Record.progress child)=Progress.Captured) "Unacknowledged resolution child differs or has execution progress" in
  {actual with phase=Child_confirmed expected_child})
let confirm_source_ack ~plan request =
  let source=Request.source request and owner=Request.physical_owner request in
  let keepers_dir=Source.runtime_keepers_dir source and keeper_name=Request.keeper_id owner in
  let* cursor=Keeper_external_read_cursor.observe ~runtime_keepers_dir:keepers_dir ~keeper_name in
  let through=Keeper_librarian_input_sources.external_through (Source.counterparts source) in
  let* ()=require (Keeper_external_read_cursor.observation_matches_preparation cursor
    ~after:through ~through ~atom:None ~official:None) "Resolution original external ACK is unconfirmed" in
  Keeper_librarian_durable_source_lock.recheck_after plan
let observe_memory_commit ~store ~expected ~request ~(completed:Owner.retained) =
  let retain plan=update ~store ~expected (fun actual ->
    let* child=match actual.phase with Child_confirmed child -> Ok child
      | Requested | Refused _ | Fenced | Child_prepared _ | Child_intended _ -> Error "Resolution child is not acknowledged" in
    (* The completed original is the resolution child or a replacement that
       descends from it. A descendant kept the child's source and changed
       only its current Memory, which is an equal basis digest. *)
    let* same_basis=if Request.request_id request=child.request_id then
        let+ ()=require (Request.body_digest request=child.request_digest)
          "Resolution child differs from its durable intent" in true
      else
        let* record=Owner.load_record ~store ~scope:actual.scope ~request_id:child.request_id
          |> Result.map_error Owner.error_to_string in
        let* record=Option.to_result ~none:"Resolution child is absent" record in
        let* ()=require (Owner.Record.request_digest record=child.request_digest)
          "Resolution child differs from its durable intent" in
        let* (root:Request.index)=Request.index_of_summary record in
        let+ basis=Request.source_basis_digest request in
        basis=root.source_basis_digest && root.owner=Request.physical_owner request in
    let source=Request.source request in
    let* ()=require (Option.is_none actual.memory_commit && same_basis
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
        let* ()=confirm_source_ack ~plan request in
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
    Ok {actual with memory_commit=Some {request_id=completed.request_id;receipts;program=None}}) in
  (* Source locks precede both the intent update and Memory locks. A finished
     answer and its actual complete receipts remain necessary; the plan only
     confirms which already-existing positions must remain unchanged. *)
  match Keeper_librarian_durable_source_lock.with_original_settlement_plan ~request
    (fun plan -> Ok (retain plan)) with
  | Ok result -> result
  | Error detail -> Error (Publication_uncertain detail)

(* Walk to this intent's exact acknowledged child. Only confirmed ordinary
   replacement links or another intent's confirmed fenced child may intervene;
   a shared source digest alone does not establish descendant identity. *)
let confirm_program_descendant ~store intent (child:child) request =
  let owner=Request.physical_owner request in
  let* basis=Request.source_basis_digest request in
  let* root=Owner.load_record ~store ~scope:intent.scope ~request_id:child.request_id
    |> Result.map_error Owner.error_to_string in
  let* root=Option.to_result ~none:"Resolution confirmed child is absent" root in
  let* ()=require (Owner.Record.request_digest root=child.request_digest)
    "Resolution confirmed child digest changed" in
  let* index=Request.index_of_summary root in
  let* ()=require (index.owner=owner && index.source_basis_digest=basis)
    "Program descendant changed the confirmed child's owner or source" in
  let read ~scope ~request_id=Owner.load ~store ~scope ~request_id |> Result.map_error Owner.error_to_string in
  let rec visit seen ~id ~digest ~(index:Request.index) ~body =
    let* ()=require (not (List.mem id seen)) "Program descendant ancestry contains a cycle" in
    if id=child.request_id then
      require (digest=child.request_digest) "Program did not reach the confirmed child"
    else
      let* predecessor=Option.to_result ~none:"Program is not a descendant of the confirmed child"
        index.predecessor in
      let* parent=Owner.load_record ~store ~scope:intent.scope ~request_id:predecessor.request_id
        |> Result.map_error Owner.error_to_string in
      let* parent=Option.to_result ~none:"Program descendant predecessor is absent" parent in
      let parent_id=Owner.Record.request_id parent in
      let* ()=require (Owner.Record.scope parent=intent.scope && parent_id=predecessor.request_id
        && Owner.Record.request_digest parent=predecessor.request_digest)
        "Program descendant predecessor digest changed" in
      let* previous=Request.index_of_summary parent in
      let* ()=require (previous.owner=owner && previous.source_basis_digest=basis)
        "Program descendant predecessor changed its owner or source" in
      let parent_body () =
        let* loaded=Owner.load_listed ~store parent |> Result.map_error Owner.error_to_string in
        Request.restore_payload ~owner loaded in
      let* fence=Fence.read ~store ~scope:intent.scope ~request_id:parent_id in
      let* ()=match fence with
        | None ->
          let* current=body () in
          let* ()=Request.validate_predecessor_link_payload ~read ~require_confirmed:true current in
          (match Progress.phase (Owner.Record.progress parent) with
           | Rejected _ ->
             let* request=parent_body () in
             let* exact=Request.request request in
             let* ended=Keeper_librarian_declaration_replacement.ended ~store
               ~original:parent ~exact ~captured:previous.destination in
             require ended "Program predecessor has no confirmed declaration ending"
           | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
           | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> Ok ())
        | Some fence ->
          let* ()=Fence.confirm_binding_index ~index:previous ~original:parent fence in
          let* _,intents=load ~store ~scope:intent.scope ~request_id:parent_id
            |> Result.map_error error_to_string in
          let* grant=Option.to_result ~none:"Program descendant has no confirmed resolution link"
            (List.find_opt (fun grant -> match grant.phase with
              | Child_confirmed child -> child.request_id=id && child.request_digest=digest
              | Requested | Refused _ | Fenced | Child_prepared _ | Child_intended _ -> false) intents) in
          let* ()=require_successor_authority grant fence in
          (match grant.origin with
           | Worker_absence -> Ok ()
           | Same_binding_cut _ -> require (Lane_addon_captured_destination.same_semantic
               index.destination previous.destination)
               "Program Cut descendant changed its semantic destination") in
      visit (id::seen) ~id:parent_id ~digest:(Owner.Record.request_digest parent) ~index:previous ~body:parent_body in
  let* index=Request.index request in
  visit [] ~id:(Request.request_id request) ~digest:(Request.body_digest request) ~index ~body:(fun () -> Ok request)
let observe_program_commit ~store ~expected ~settled:proof =
  update ~store ~expected (fun actual ->
    let* child=match actual.phase with
      | Child_confirmed child -> Ok child
      | Requested | Refused _ | Fenced | Child_prepared _ | Child_intended _ ->
        Error "Program resolution child is not acknowledged" in
    let* ()=require (Option.is_none actual.memory_commit) "Resolution completion was already recorded" in
    let* fence=Fence.read ~store ~scope:actual.scope ~request_id:actual.original_request_id in
    let* fence=Option.to_result ~none:"Program resolution fence is absent" fence in
    let* ()=require_successor_authority actual fence in
    let* original=Owner.load_record ~store ~scope:actual.scope ~request_id:actual.original_request_id
      |> Result.map_error Owner.error_to_string in
    let* original=Option.to_result ~none:"Program resolution original is absent" original in
    let* index=Request.index_of_summary original in
    let* ()=Fence.confirm_binding_index ~index ~original fence in
    let request=Program_settlement.request proof in
    let* basis=Request.source_basis_digest request in
    let* ()=require (Request.scope (Request.physical_owner request)=actual.scope
      && Request.physical_owner request=index.owner && basis=index.source_basis_digest)
      "Program resolution changed its fenced original source or owner" in
    let* ()=confirm_program_descendant ~store actual child request in
    let* ()=Program_settlement.recheck proof in
    let program=Program_settlement.retained proof in
    Ok {actual with memory_commit=Some {request_id=program.request_id;receipts=program.receipts;program=Some program}})

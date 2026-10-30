module Durable = Keeper_librarian_durable_request
module Question = Keeper_librarian_durable_question
module Final = Keeper_librarian_original_final
module Runtime = Keeper_librarian_runtime
module Input = Keeper_librarian_input_capture
module Machine = Keeper_librarian_message_floor.Machine
module Unread = Keeper_librarian_unread
module Owner = Lane_addon_tool_request_owner
let ( let* ) = Result.bind
let ( let+ ) result f = Result.map f result
let require condition detail = if condition then Ok () else Error detail
let fields expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare expected -> Ok fields
  | _ -> Error "Original floor step has unknown, duplicate or missing fields"
let value name fields = List.assoc name fields
let text = function `String value -> Ok value | _ -> Error "Original floor step expects text"
let nonblank json = let* value=text json in
  let+ ()=require (String.trim value<>"") "Original floor step identity is blank" in value
let integer = function `Int value -> Ok value | _ -> Error "Original floor step expects an integer"
let parse bytes = try Ok (Yojson.Safe.from_string bytes) with Yojson.Json_error detail -> Error detail
let equal left right detail =
  let* left=Lane_addon_action.canonical left in
  let* right=Lane_addon_action.canonical right in
  require (Yojson.Safe.equal left right) detail
let all decode items =
  List.fold_right (fun item rest -> let* rest=rest in let+ item=decode item in item::rest) items (Ok [])

let request_kind = "keeper-librarian-floor-step"
let hash text = Agent_core_sha256.(to_hex (digest_string text))
let scope_prefix = "keeper-librarian-floor-step-"
let is_scope value = String.starts_with ~prefix:scope_prefix value
let scope_for_hash hash = scope_prefix ^ hash
let owner_hash owner = hash (Durable.scope owner)
let scope owner = scope_for_hash (owner_hash owner)
let fresh_request_id owner = Yojson.Safe.to_string
  (`List [`String request_kind;`String (owner_hash owner);`String (Random_id.uuid_v7 ())])
let scope_of_request_id id =
  let* json=parse id in
  match json with
  | `List [`String kind;`String hash;`String nonce]
      when kind=request_kind && String_util.is_lowercase_sha256_hex hash && Yojson.Safe.to_string json=id ->
    let+ _nonce=Random_id.parse_uuid_v7 nonce in scope_for_hash hash
  | _ -> Error "Invalid original floor step request ID"
let minted_on id =
  let* json=parse id in
  match json with
  | `List [`String kind;`String hash;`String nonce]
      when kind=request_kind && String_util.is_lowercase_sha256_hex hash && Yojson.Safe.to_string json=id ->
    let+ time_ms=Random_id.uuid_v7_time_ms nonce in
    Jsonl_writer.day_key ~ts:(Int64.to_float time_ms /. 1000.)
  | _ -> Error "Invalid original floor step request ID"

type link = {request_id:string;request_digest:string}
let link_json link = `Assoc ["request_id",`String link.request_id;"request_digest",`String link.request_digest]
let link_of_json json =
  let* f=fields ["request_id";"request_digest"] json in
  let* request_id=nonblank (value "request_id" f) in
  let* request_digest=nonblank (value "request_digest" f) in
  let+ ()=require (String_util.is_lowercase_sha256_hex request_digest)
    "Original floor step link digest is invalid" in
  {request_id;request_digest}

(* [digest] names the canonical bytes of [to_json], as for a history original. *)
type t = {id:string;owner:Durable.owner;destination:Durable.destination;transaction_id:string;range:link;
  previous:link option;position:int;sources:Unread.source list;step:Runtime.durable_step_preparation;
  digest:string}
let request_id step=step.id
let physical_owner step=step.owner
let destination step=step.destination
let transaction_id step=step.transaction_id
let range step=step.range
let previous step=step.previous
let position step=step.position
let sources step=step.sources
let step step=step.step
let context_json (context:Runtime.durable_step_context) = `Assoc [
  "previous_state",(match context.previous_state with None -> `Null | Some state -> `String state);
  "unread_messages",Unread.list_to_json context.unread_messages]
let context_of_json json =
  let* f=fields ["previous_state";"unread_messages"] json in
  let* previous_state=match value "previous_state" f with
    | `Null -> Ok None
    | `String state -> Ok (Some state)
    | _ -> Error "Original floor step carried state is not text" in
  let+ unread_messages=Unread.list_of_json (value "unread_messages" f) in
  {Runtime.previous_state;unread_messages}
let to_json step = `Assoc ["schema",`Int 1;"kind",`String "completed-history-floor-step";
  "request_id",`String step.id;"owner",Durable.owner_to_json step.owner;
  "destination",Durable.destination_json step.destination;"transaction_id",`String step.transaction_id;
  "range",link_json step.range;
  "previous",(match step.previous with None -> `Null | Some link -> link_json link);
  "position",`Int step.position;"sources",`List (List.map Unread.source_to_json step.sources);
  "context",context_json step.step.context;"input",Input.to_json step.step.preparation.source_input;
  "preparation",Question.to_json step.step.preparation]
let asked (question:Machine.question) ~position ~sources =
  require (position=question.position && sources=question.sources)
    "Original floor step is not the question it was asked"
(* What a step's own encoding must satisfy, with no question to hand. *)
let validate_links ~owner ~id ~range ~previous ~position =
  let* expected_scope=scope_of_request_id id in
  let* ()=require (expected_scope=scope owner) "Original floor step belongs to another physical scope" in
  let* range_scope=Durable.scope_of_request_id range.request_id in
  let* ()=require (range_scope=Durable.scope owner && String_util.is_lowercase_sha256_hex range.request_digest)
    "Original floor step names a range outside its physical scope" in
  let* ()=match previous with
    | None -> Ok ()
    | Some previous ->
      let* previous_scope=scope_of_request_id previous.request_id in
      require (previous_scope=expected_scope && previous.request_id<>id
        && String_util.is_lowercase_sha256_hex previous.request_digest)
        "Original floor step names a previous step outside its scope or itself" in
  require (position>=0 && (previous=None)=(position=0))
    "Original floor step position disagrees with its place in the chain"
let source_digest = function
  | Unread.Atom {message_sha256;_} | Unread.Official_turn {message_sha256;_} -> message_sha256
let validate step =
  let input=step.step.preparation.source_input in
  let* ()=require (String.trim step.transaction_id<>"") "Original floor step has no chain transaction" in
  let* ()=validate_links ~owner:step.owner ~id:step.id ~range:step.range ~previous:step.previous
    ~position:step.position in
  let* ()=require (Keeper_identity.Keeper_id.to_string input.keeper_id=Durable.keeper_id step.owner)
    "Original floor step belongs to another Keeper" in
  let* ()=require (input.goal_context=Keeper_librarian.No_task)
    "Original floor step cannot borrow a task's Goal context" in
  let* ()=match step.sources,input.messages with
    | [],[] -> Ok ()
    | [source],[message] ->
      require (source_digest source=Unread.message_digest message)
        "Original floor step source hash differs from its message"
    | [],_::_ | _::_,[] | _::_::_,_ | _,_::_::_ ->
      Error "Original floor step does not carry exactly its message" in
  Runtime.validate_durable_step_preparation step.step
(* The step is the question the floor asks now: same message, same carried
   state and unread messages, same input. Inputs compare by what is retained. *)
let matches_question (question:Machine.question) step =
  let* ()=asked question ~position:step.position ~sources:step.sources in
  let* ()=require (step.step.context.previous_state=question.previous_state
    && step.step.context.unread_messages=question.unread_messages)
    "Original floor step context differs from its question" in
  equal (Input.to_json step.step.preparation.source_input)
    (Input.to_json (Runtime.durable_step_source_input question.input))
    "Original floor step input differs from its question"
type header = {request_id:string;destination:Durable.destination;transaction_id:string;range:link;
  previous:link option;position:int;sources:Unread.source list}
let header_fields = ["schema";"kind";"request_id";"owner";"destination";"transaction_id";"range";"previous";
  "position";"sources";"context";"input";"preparation"]
(* Everything but the context, input and preparation. *)
let header_of_fields ~owner f =
  let* ()=require (value "schema" f=`Int 1 && value "kind" f=`String "completed-history-floor-step")
    "Unknown original floor step schema or kind" in
  let* request_id=nonblank (value "request_id" f) in
  let* ()=Durable.owner_matches_json owner (value "owner" f) in
  let* destination=Durable.destination_of_json (value "destination" f) in
  let* transaction_id=nonblank (value "transaction_id" f) in
  let* range=link_of_json (value "range" f) in
  let* previous=match value "previous" f with
    | `Null -> Ok None
    | json -> let+ link=link_of_json json in Some link in
  let* position=integer (value "position" f) in
  let* sources=match value "sources" f with
    | `List items -> all Unread.source_of_json items
    | _ -> Error "Original floor step sources are not a list" in
  let+ ()=validate_links ~owner ~id:request_id ~range ~previous ~position in
  {request_id;destination;transaction_id;range;previous;position;sources}
let decode ~owner ~digest json =
  let* f=fields header_fields json in
  let* {request_id=id;destination;transaction_id;range;previous;position;sources}=header_of_fields ~owner f in
  let* context=context_of_json (value "context" f) in
  let* source_input=Input.of_json (value "input" f) in
  let* {Question.parsing_now;policy;rule_prompt;prompt;output_schema;_} as frozen=Question.of_json (value "preparation" f) in
  let* step=Runtime.restore_durable_step_preparation ~context ~source_input
    ~parsing_now ~policy ~rule_prompt ~prompt ~output_schema in
  let* ()=Question.rendered_matches frozen step.preparation in
  let draft={id;owner;destination;transaction_id;range;previous;position;sources;step;digest=""} in
  let* ()=validate draft in
  let* ()=equal json (to_json draft) "Original floor step request encoding differs" in
  let+ digest=match digest with Some digest -> Ok digest | None -> Owner.request_digest json in
  {draft with digest}
let create ~request_id ~owner ~destination ~transaction_id ~range ~previous ~(question:Machine.question) ~step () =
  let* destination=Durable.destination_of_json (Durable.destination_json destination) in
  let draft={id=request_id;owner;destination;transaction_id;range;previous;position=question.position;
    sources=question.sources;step;digest=""} in
  let* ()=validate draft in
  let* ()=matches_question question draft in
  decode ~owner ~digest:None (to_json draft)
let binds_record ~owner ~id ~(destination:Durable.destination) (record:Owner.retained) =
  require (record.scope=scope owner && record.request_id=id
    && record.installation_id=destination.installation_id && record.package_id=destination.package_id
    && record.tool=destination.tool) "Original floor step host binding differs"
let binds step record = binds_record ~owner:step.owner ~id:step.id ~destination:step.destination record
let header ~owner (record:Owner.retained) =
  let* f=fields header_fields record.request in
  let* header=header_of_fields ~owner f in
  let+ ()=binds_record ~owner ~id:header.request_id ~destination:header.destination record in header
let restore ~owner (record:Owner.retained) =
  (* The record's digest named the body [Owner.load] verified, and [decode]
     requires that body to be this request's canonical encoding. *)
  let* step=decode ~owner ~digest:(Some record.request_digest) record.request in
  let* ()=binds step record in
  let+ ()=equal record.request (to_json step) "Original floor step request encoding differs" in step
let observe_record_owner ~base_path ~keepers_dir (record:Owner.retained) =
  let* f=fields header_fields record.request in
  let* original=Durable.owner_of_json (value "owner" f) in
  let* expected_scope=scope_of_request_id record.request_id in
  let* ()=require (record.scope=expected_scope && expected_scope=scope original)
    "Original floor step host record belongs to another scope" in
  let* current=Durable.observe_owner ~base_path ~keepers_dir ~keeper_id:(Durable.keeper_id original) in
  let+ ()=Durable.owner_matches_json current (value "owner" f) in current
let confirm_record step (record:Owner.retained) =
  let* ()=binds step record in
  require (String.equal record.request_digest step.digest) "Original floor step record names another request"
let request step = Question.request ~request_id:step.id step.step.preparation
let confirm_owner step =
  let* current=Durable.observe_owner ~base_path:(Durable.base_path step.owner)
    ~keepers_dir:(Durable.keepers_dir step.owner) ~keeper_id:(Durable.keeper_id step.owner) in
  Durable.owner_matches_json current (Durable.owner_to_json step.owner)
let host_proof_target step =
  let* ()=confirm_owner step in
  let* exact=request step in
  Final.target ~installation_id:step.destination.installation_id exact
let refusal_evidence ~store step final =
  Final.refusal_evidence ~store ~target:(fun () -> host_proof_target step) final
let confirm_final ~store step final =
  let* target=host_proof_target step in
  Final.confirm_final ~store target final
let validate_proposal step output =
  Runtime.validate_durable_step_proposal step.step output |> Result.map_error (function
    | Runtime.Preparation_invalid detail -> detail
    | Proposal_invalid error -> Keeper_librarian.parse_error_to_string error)

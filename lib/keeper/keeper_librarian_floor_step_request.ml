module Durable = Keeper_librarian_durable_request
module Question = Keeper_librarian_durable_question
module Final = Keeper_librarian_original_final
module Runtime = Keeper_librarian_runtime
module Input = Keeper_librarian_input_capture
module Machine = Keeper_librarian_message_floor.Machine
module Unread = Keeper_librarian_unread
module Owner = Lane_addon_tool_request_owner
module Destination = Lane_addon_captured_destination
module Current = Keeper_memory_os_current
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
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      let* x = decode item in
      loop (x :: acc) rest
  in
  loop [] items

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
type retained_chain_basis = {anchor:Current.program_anchor_evidence;sources:Unread.source list}
type t = {id:string;owner:Durable.owner;destination:Durable.destination;transaction_id:string;range:link;
  previous:link option;position:int;sources:Unread.source list;step:Runtime.durable_step_preparation;
  basis:retained_chain_basis option;digest:string}
let request_id step=step.id
let physical_owner step=step.owner
let destination step=step.destination
let transaction_id step=step.transaction_id
let range step=step.range
let previous step=step.previous
let position step=step.position
let sources step=step.sources
let step step=step.step
let chain_basis step=step.basis
let request step = Question.request ~request_id:step.id step.step.preparation
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
let retained_source = function
  | Runtime.Ordinary_floor -> None
  | Retained_original source -> Some source
let retained_source_json (source:Runtime.retained_step_source) = `Assoc [
  "request_id",`String source.request_id;"request_digest",`String source.request_digest;
  "source_basis_digest",`String source.source_basis_digest]
let retained_source_of_json json =
  let* f=fields ["request_id";"request_digest";"source_basis_digest"] json in
  let* request_id=nonblank (value "request_id" f) in
  let* request_digest=nonblank (value "request_digest" f) in
  let* source_basis_digest=nonblank (value "source_basis_digest" f) in
  let+ ()=require (String_util.is_lowercase_sha256_hex request_digest
    && String_util.is_lowercase_sha256_hex source_basis_digest)
    "Retained floor source digest is invalid" in
  {Runtime.request_id;request_digest;source_basis_digest}
let mode_fields source = match source with
  | None -> 1,[]
  | Some source -> 2,["retained_source",retained_source_json source]
let basis_json = function None -> `Null | Some basis -> `Assoc [
  "anchor",Current.program_anchor_evidence_to_json basis.anchor;
  "source_manifest",`List (List.map Unread.source_to_json basis.sources)]
let basis_of_json = function
  | `Null -> Ok None
  | json ->
    let* f=fields ["anchor";"source_manifest"] json in
    let* anchor=Current.program_anchor_evidence_of_json (value "anchor" f) in
    let* sources=match value "source_manifest" f with
      | `List sources -> all Unread.source_of_json sources
      | _ -> Error "Retained floor source manifest is not a list" in
    let rec unique seen = function
      | [] -> Ok ()
      | source::rest ->
        let key=Unread.Source_key.of_source source in
        let* ()=require (not (Unread.Source_keys.mem key seen)) "Retained floor source manifest repeats a coordinate" in
        unique (Unread.Source_keys.add key seen) rest in
    let* ()=require (sources<>[]) "Retained floor source manifest is empty" in
    let+ ()=unique Unread.Source_keys.empty sources in Some {anchor;sources}
let basis_sha256 = function
  | None -> Ok None
  | Some basis -> let+ digest=Owner.request_digest (basis_json (Some basis)) in Some digest
let to_json step =
  let schema,mode=mode_fields (retained_source step.step.mode) in
  let mode=if schema=1 then mode else mode @ ["basis",basis_json step.basis] in
  `Assoc (["schema",`Int schema;"kind",`String "completed-history-floor-step";
  "request_id",`String step.id;"owner",Durable.owner_to_json step.owner;
  "destination",Destination.to_json step.destination;"transaction_id",`String step.transaction_id;
  "range",link_json step.range;
  "previous",(match step.previous with None -> `Null | Some link -> link_json link);
  "position",`Int step.position;"sources",`List (List.map Unread.source_to_json step.sources);
  "context",context_json step.step.context;"input",Input.to_json step.step.preparation.source_input;
  "preparation",Question.to_json step.step.preparation] @ mode)
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
(* Binding checks shared by creation and decode. Decode has already restored
   the preparation; creation separately validates the public supplied step. *)
let validate_binding step =
  let input=step.step.preparation.source_input in
  let* ()=require (String.trim step.transaction_id<>"") "Original floor step has no chain transaction" in
  let* ()=validate_links ~owner:step.owner ~id:step.id ~range:step.range ~previous:step.previous
    ~position:step.position in
  let* ()=require (Keeper_identity.Keeper_id.to_string input.keeper_id=Durable.keeper_id step.owner)
    "Original floor step belongs to another Keeper" in
  let* ()=require (input.goal_context=Keeper_librarian.No_task)
    "Original floor step cannot borrow a task's Goal context" in
  let* ()=match retained_source step.step.mode with
    | None -> require (step.basis=None) "Ordinary floor question cannot carry a retained Memory anchor"
    | Some source -> require (source.request_id=step.range.request_id
        && source.request_digest=step.range.request_digest
        && Option.is_some step.basis=(step.position=0))
        "Retained floor step names another complete original" in
  let* ()=match step.basis with
    | None -> Ok ()
    | Some basis -> require (match basis.sources with first::_ -> step.sources=[first] | [] -> false)
        "Retained floor first question differs from its complete source manifest" in
  match step.sources,input.messages with
    | [],[] -> Ok ()
    | [source],[message] ->
      require (source_digest source=Unread.message_digest message)
        "Original floor step source hash differs from its message"
    | [],_::_ | _::_,[] | _::_::_,_ | _,_::_::_ ->
      Error "Original floor step does not carry exactly its message"
(* The step is the question the floor asks now: same message, same carried
   state and unread messages, same input. Inputs compare by what is retained. *)
let matches_question (question:Machine.question) step =
  let* ()=asked question ~position:step.position ~sources:step.sources in
  let* ()=require (step.step.context.previous_state=question.previous_state
    && step.step.context.unread_messages=question.unread_messages)
    "Original floor step context differs from its question" in
  let input=match step.step.mode with
    | Runtime.Ordinary_floor -> Runtime.durable_step_source_input question.input
    | Retained_original _ -> question.input in
  equal (Input.to_json step.step.preparation.source_input) (Input.to_json input)
    "Original floor step input differs from its question"
type header = {request_id:string;destination:Durable.destination;transaction_id:string;range:link;
  previous:link option;position:int;sources:Unread.source list;
  retained_source:Runtime.retained_step_source option;basis_sha256:string option}
type index = {owner:Durable.owner;header:header;exact_digest:string}
let header_fields = ["schema";"kind";"request_id";"owner";"destination";"transaction_id";"range";"previous";
  "position";"sources";"context";"input";"preparation"]
let versioned_fields ~kind ~retained_fields expected json =
  let* schema=match json with
    | `Assoc f -> (match List.assoc_opt "schema" f with
        | Some (`Int (1 | 2 as version)) -> Ok version
        | Some _ | None -> Error "Unknown original floor step schema")
    | _ -> Error "Original floor step is not an object" in
  let* f=fields (if schema=1 then expected else retained_fields @ expected) json in
  let+ ()=require (value "kind" f=`String kind) "Unknown original floor step schema or kind" in f
let body_fields json =
  versioned_fields ~kind:"completed-history-floor-step" ~retained_fields:["retained_source";"basis"]
    header_fields json
(* Everything but the context, input and preparation. *)
let header_of_fields ~owner f =
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
  let* retained_source=match List.assoc_opt "retained_source" f with
    | None -> Ok None
    | Some json -> let+ source=retained_source_of_json json in Some source in
  let* basis_sha256=match List.assoc_opt "basis" f,List.assoc_opt "basis_sha256" f with
    | None,None -> Ok None
    | Some json,None -> let* basis=basis_of_json json in basis_sha256 basis
    | None,Some `Null -> Ok None
    | None,Some (`String digest) when String_util.is_lowercase_sha256_hex digest -> Ok (Some digest)
    | None,Some _ | Some _,Some _ -> Error "Retained floor anchor digest is invalid" in
  let* ()=match retained_source with
    | None -> require (basis_sha256=None) "Ordinary floor index has a retained Memory anchor"
    | Some source -> require (source.request_id=range.request_id && source.request_digest=range.request_digest
        && Option.is_some basis_sha256=(position=0))
        "Retained floor index names another original" in
  let+ ()=validate_links ~owner ~id:request_id ~range ~previous ~position in
  {request_id;destination;transaction_id;range;previous;position;sources;retained_source;basis_sha256}
let binds_record ~owner ~id ~(destination:Durable.destination) (record:Owner.Record.t) =
  let module Record=Owner.Record in
  require (Record.scope record=scope owner && Record.request_id record=id
    && Record.installation_id record=destination.installation_id
    && Record.package_id record=destination.package_id && Record.tool record=destination.tool)
    "Original floor step host binding differs"
let index (step:t) =
  let* exact=request step in
  let+ basis_sha256=basis_sha256 step.basis in
  {owner=step.owner;header={request_id=step.id;destination=step.destination;
    transaction_id=step.transaction_id;range=step.range;previous=step.previous;
    position=step.position;sources=step.sources;retained_source=retained_source step.step.mode;basis_sha256};
    exact_digest=Lane_addon_exact.digest exact}
let index_to_json (index:index) =
  let header=index.header in
  let schema,mode=mode_fields header.retained_source in
  let mode=if schema=1 then mode else mode @ ["basis_sha256",(match header.basis_sha256 with
    | None -> `Null | Some digest -> `String digest)] in
  `Assoc (["schema",`Int schema;"kind",`String "completed-history-floor-step-index";
    "owner",Durable.owner_to_json index.owner;"request_id",`String header.request_id;
    "destination",Destination.to_json header.destination;"transaction_id",`String header.transaction_id;
    "range",link_json header.range;"previous",(match header.previous with None -> `Null | Some link -> link_json link);
    "position",`Int header.position;"sources",`List (List.map Unread.source_to_json header.sources);
    "exact_digest",`String index.exact_digest] @ mode)
let index_of_summary record =
  let* f=versioned_fields ~kind:"completed-history-floor-step-index"
    ~retained_fields:["retained_source";"basis_sha256"]
    ["schema";"kind";"owner";"request_id";"destination";"transaction_id";
     "range";"previous";"position";"sources";"exact_digest"] (Owner.Record.summary record) in
  let* owner=Durable.owner_of_json (value "owner" f) in
  let* header=header_of_fields ~owner f in
  let* exact_digest=nonblank (value "exact_digest" f) in
  let* ()=require (String_util.is_lowercase_sha256_hex exact_digest) "Original floor step Exact digest is invalid" in
  let+ ()=binds_record ~owner ~id:header.request_id ~destination:header.destination record in
  {owner;header;exact_digest}
let confirm_index step record =
  let* stored=index_of_summary record in
  let* actual=index step in
  require (stored=actual) "Original floor step index differs from its request"
let decode ~owner ~digest json =
  let* f=body_fields json in
  let* {request_id=id;destination;transaction_id;range;previous;position;sources;retained_source;
    basis_sha256=_}=header_of_fields ~owner f in
  let* basis=match retained_source with
    | None -> Ok None
    | Some _ -> basis_of_json (value "basis" f) in
  let* context=context_of_json (value "context" f) in
  let* source_input=Input.of_json (value "input" f) in
  let* {Question.parsing_now;policy;rule_prompt;turn_prompts;prompt;output_schema;_} as frozen=Question.of_json (value "preparation" f) in
  let restore=match retained_source with
    | None -> Runtime.restore_durable_step_preparation
    | Some source -> Runtime.restore_retained_durable_step_preparation ~source in
  let* step=restore ~context ~source_input
    ~parsing_now ~policy ~rule_prompt ~turn_prompts ~prompt ~output_schema in
  let* ()=Question.rendered_matches frozen step.preparation in
  let draft={id;owner;destination;transaction_id;range;previous;position;sources;step;basis;digest=""} in
  let* ()=validate_binding draft in
  let* ()=equal json (to_json draft) "Original floor step request encoding differs" in
  let+ digest=match digest with Some digest -> Ok digest | None -> Owner.request_digest json in
  {draft with digest}
let create ?basis ~request_id ~owner ~destination ~transaction_id ~range ~previous ~(question:Machine.question) ~step () =
  let* destination=Durable.destination_of_json (Destination.to_json destination) in
  let draft={id=request_id;owner;destination;transaction_id;range;previous;position=question.position;
    sources=question.sources;step;basis;digest=""} in
  let* ()=validate_binding draft in
  let* ()=Runtime.validate_durable_step_preparation step in
  let* ()=matches_question question draft in
  decode ~owner ~digest:None (to_json draft)
let of_json ~owner json = decode ~owner ~digest:None json
let binds (step:t) record = binds_record ~owner:step.owner ~id:step.id ~destination:step.destination (Owner.listed record)
let header ~owner (record:Owner.retained) =
  let* f=body_fields record.request in
  let* header=header_of_fields ~owner f in
  let* ()=binds_record ~owner ~id:header.request_id ~destination:header.destination (Owner.listed record) in
  let* index=index_of_summary (Owner.listed record) in
  let+ ()=require (index.owner=owner && index.header=header) "Original floor step header differs from its index" in header
let restore ~owner (record:Owner.retained) =
  (* The record's digest named the body [Owner.load] verified, and [decode]
     requires that body to be this request's canonical encoding. *)
  let* step=decode ~owner ~digest:(Some record.request_digest) record.request in
  let* ()=binds step record in
  let* ()=confirm_index step (Owner.listed record) in
  let+ ()=equal record.request (to_json step) "Original floor step request encoding differs" in step
let validate_ancestry_payload ~read (step:t) =
  let load ~scope (link:link) =
    let* record=read ~scope ~request_id:link.request_id in
    let* record=Option.to_result ~none:"Original floor chain predecessor is absent" record in
    let+ ()=require (record.Owner.request_digest=link.request_digest)
      "Original floor chain predecessor digest changed" in record in
  let rec visit seen (current:t) =
    let* ()=require (not (List.mem current.id seen)) "Original floor chain ancestry contains a cycle" in
    match current.previous with
    | None -> Ok ()
    | Some link ->
      let* record=load ~scope:(scope step.owner) link in
      let* previous=restore ~owner:step.owner record in
      let* ()=require (previous.range=current.range && previous.transaction_id=current.transaction_id
        && retained_source previous.step.mode=retained_source current.step.mode
        && previous.position=current.position-1) "Original floor chain predecessor belongs to another chain or position" in
      visit (current.id::seen) previous in
  visit [] step
let observe_record_owner ~base_path ~keepers_dir (record:Owner.retained) =
  let* f=body_fields record.request in
  let* original=Durable.owner_of_json (value "owner" f) in
  let* expected_scope=scope_of_request_id record.request_id in
  let* ()=require (record.scope=expected_scope && expected_scope=scope original)
    "Original floor step host record belongs to another scope" in
  let* current=Durable.observe_owner ~base_path ~keepers_dir ~keeper_id:(Durable.keeper_id original) in
  let+ ()=Durable.owner_matches_json current (value "owner" f) in current
let confirm_record step (record:Owner.retained) =
  let* ()=binds step record in
  let* ()=require (String.equal record.request_digest step.digest) "Original floor step record names another request" in
  confirm_index step (Owner.listed record)
let confirm_owner (step:t) =
  let* current=Durable.observe_owner ~base_path:(Durable.base_path step.owner)
    ~keepers_dir:(Durable.keepers_dir step.owner) ~keeper_id:(Durable.keeper_id step.owner) in
  Durable.owner_matches_json current (Durable.owner_to_json step.owner)
let host_proof_target step =
  let* ()=confirm_owner step in
  let* exact=request step in
  Final.target ~installation_id:step.destination.installation_id exact
let decode_final ~store step json =
  let* target=host_proof_target step in
  Final.decode_final ~store target json
let refusal_evidence ~store step final =
  Final.refusal_evidence ~store ~target:(fun () -> host_proof_target step) final
let confirm_final ~store step final =
  let* target=host_proof_target step in
  Final.confirm_final ~store target final
let validate_proposal step output =
  Runtime.validate_durable_step_proposal step.step output |> Result.map_error (function
    | Runtime.Preparation_invalid detail -> detail
    | Proposal_invalid error -> Keeper_librarian.parse_error_to_string error)

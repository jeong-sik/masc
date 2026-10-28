module Source = Keeper_librarian_durable_capture
module Memory = Keeper_memory_os_current
module Runtime = Keeper_librarian_runtime
module Owner = Lane_addon_tool_request_owner
module Exact = Lane_addon_exact
module Progress = Lane_addon_request_progress
let ( let* ) = Result.bind
let ( let+ ) result f = Result.map f result
let require condition detail = if condition then Ok () else Error detail
let fields expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare expected -> Ok fields
  | _ -> Error "Original history request has unknown, duplicate or missing fields"
let value name fields = List.assoc name fields
let text = function `String value -> Ok value | _ -> Error "Original history request expects text"
let nonblank json = let* value=text json in
  let+ ()=require (String.trim value<>"") "Original history identity is blank" in value
let integer = function `Int value -> Ok value | _ -> Error "Original history request expects an integer"
let boolean = function `Bool value -> Ok value | _ -> Error "Original history request expects a boolean"
let optional encode = Option.fold ~none:`Null ~some:encode
let option decode = function `Null -> Ok None | json -> let+ value=decode json in Some value
let parse bytes = try Ok (Yojson.Safe.from_string bytes) with Yojson.Json_error detail -> Error detail
let equal left right detail =
  let* left=Lane_addon_action.canonical left in
  let* right=Lane_addon_action.canonical right in
  require (Yojson.Safe.equal left right) detail

type physical = {path:string;device:int;inode:int}
type owner = {workspace:physical;keepers:physical;runtime:physical;keeper_id:string;epoch:string}
let physical_json physical = `Assoc ["path",`String physical.path;"device",`Int physical.device;"inode",`Int physical.inode]
let physical_of_json json =
  let* f=fields ["path";"device";"inode"] json in
  let* path=nonblank (value "path" f) in
  let* device=integer (value "device" f) in
  let* inode=integer (value "inode" f) in
  let+ ()=require (not (Filename.is_relative path)) "Original history root is relative" in
  {path;device;inode}
let canonical_keeper keeper_id =
  match Keeper_identity.Keeper_id.of_string keeper_id with
  | Some id when Keeper_identity.Keeper_id.to_string id=keeper_id && Keeper_config_text.validate_name keeper_id -> Ok keeper_id
  | None | Some _ -> Error "Original history owner requires a canonical Keeper ID"
let physical root =
  let stat=Fs_compat.owned_inventory_root_stat root in
  {path=Fs_compat.owned_inventory_root_path root;device=stat.Unix.st_dev;inode=stat.Unix.st_ino}
let owned value = Result.map_error Fs_compat.owned_regular_file_read_error_to_string value
let observe_roots ~base_path ~keepers_dir ~keeper_id f =
  let* keeper_id=canonical_keeper keeper_id in
  Fs_compat.with_owned_inventory_root base_path (fun workspace ->
    Fs_compat.with_owned_inventory_root keepers_dir (fun keepers ->
      Fs_compat.with_owned_inventory_root (Common.keepers_runtime_dir_of_base ~base_path) (fun runtime ->
        f (physical workspace) (physical keepers) (physical runtime) keeper_id keepers))) |> owned
let address ~workspace ~keepers ~runtime ~keeper_id =
  Yojson.Safe.to_string (`Assoc ["workspace",physical_json workspace;
    "keepers",physical_json keepers;"runtime",physical_json runtime;"keeper_id",`String keeper_id])
let hash text = Agent_core_sha256.(to_hex (digest_string text))
let scope_for_hash hash = "keeper-librarian-history-execution-" ^ hash
let owner_hash owner = hash (address ~workspace:owner.workspace ~keepers:owner.keepers ~runtime:owner.runtime ~keeper_id:owner.keeper_id)
let scope owner = scope_for_hash (owner_hash owner)
let discovery_scope ~base_path ~keepers_dir ~keeper_id =
  observe_roots ~base_path ~keepers_dir ~keeper_id (fun workspace keepers runtime keeper_id _ ->
    Ok (scope_for_hash (hash (address ~workspace ~keepers ~runtime ~keeper_id))))
let observe_owner ~base_path ~keepers_dir ~keeper_id =
  let* keeper_id=canonical_keeper keeper_id in
  let* epoch_entry=Fs_compat.owned_relative_path [Filename.basename (Memory.epoch_path ~keepers_dir ~keeper_id)] in
  let* workspace,keepers,runtime,bytes=observe_roots ~base_path ~keepers_dir ~keeper_id
    (fun workspace keepers runtime _keeper_id root ->
      Fs_compat.with_owned_inventory_regular_file ~owner_uid:(Unix.getuid ()) root epoch_entry
        (fun ~file ~parent:_ ~stat ->
          let bytes=Bytes.create stat.Unix.st_size in
          let rec read offset =
            if offset=Bytes.length bytes then Bytes.to_string bytes
            else match Unix.read file bytes offset (Bytes.length bytes-offset) with
              | 0 -> raise End_of_file
              | count -> read (offset+count)
              | exception Unix.Unix_error (Unix.EINTR,_,_) -> read offset in
          workspace,keepers,runtime,read 0)) in
  let* json=parse bytes in
  let* f=fields ["schema_version";"epoch"] json in
  let* version=integer (value "schema_version" f) in
  let* epoch=nonblank (value "epoch" f) in
  let+ ()=require (version=1 && epoch=String.trim epoch) "Original history Memory epoch is invalid" in
  {workspace;keepers;runtime;keeper_id;epoch}
let keeper_id owner = owner.keeper_id
let base_path owner = owner.workspace.path
let keepers_dir owner = owner.keepers.path
let runtime_keepers_dir owner = owner.runtime.path
let owner_to_json owner = `Assoc ["workspace",physical_json owner.workspace;"keepers",physical_json owner.keepers;
  "runtime",physical_json owner.runtime;"keeper_id",`String owner.keeper_id;"epoch",`String owner.epoch]
let owner_of_json json =
  let* f=fields ["workspace";"keepers";"runtime";"keeper_id";"epoch"] json in
  let* workspace=physical_of_json (value "workspace" f) in
  let* keepers=physical_of_json (value "keepers" f) in
  let* runtime=physical_of_json (value "runtime" f) in
  let* keeper_id=nonblank (value "keeper_id" f) in
  let* keeper_id=canonical_keeper keeper_id in
  let* epoch=nonblank (value "epoch" f) in
  let+ ()=require (epoch=String.trim epoch) "Original history epoch is noncanonical" in
  {workspace;keepers;runtime;keeper_id;epoch}
let owner_matches_json owner json =
  let* original=owner_of_json json in
  require (owner=original) "Original history physical roots or Memory epoch changed"
let fresh_request_id owner = Yojson.Safe.to_string
  (`List [`String "keeper-librarian-history";`String (owner_hash owner);`String (Random_id.uuid_v7 ())])
let parse_request_id id =
  let* json=parse id in
  match json with
  | `List [`String "keeper-librarian-history";`String hash;`String nonce]
      when String_util.is_lowercase_sha256_hex hash && Yojson.Safe.to_string json=id ->
    let+ nonce=Random_id.parse_uuid_v7 nonce in hash,nonce
  | _ -> Error "Invalid original history request ID"
let scope_of_request_id id = let+ hash,_=parse_request_id id in scope_for_hash hash
let minted_on id =
  let* _,nonce=parse_request_id id in
  let+ time_ms=Random_id.uuid_v7_time_ms nonce in
  Jsonl_writer.day_key ~ts:(Int64.to_float time_ms /. 1000.)

type destination = {installation_id:string;package_id:string;tool:string;
  source_revision:string;configuration_revision:string}
let package_id = Keeper_librarian_addon.package_id
let tool = Keeper_librarian_addon.tool Keeper_librarian_addon.Durable
let destination_json (destination:destination) = `Assoc [
  "installation_id",`String destination.installation_id;"package_id",`String destination.package_id;
  "tool",`String destination.tool;"source_revision",`String destination.source_revision;
  "configuration_revision",`String destination.configuration_revision]
let destination_of_json json =
  let* f=fields ["installation_id";"package_id";"tool";"source_revision";"configuration_revision"] json in
  let* installation_id=nonblank (value "installation_id" f) in
  let* actual_package=nonblank (value "package_id" f) in
  let* actual_tool=nonblank (value "tool" f) in
  let* source_revision=nonblank (value "source_revision" f) in
  let* configuration_revision=nonblank (value "configuration_revision" f) in
  let* installation=Owner.installation_of_id installation_id in
  let* ()=match installation with Owner.Configuration _ -> Ok ()
    | Manual _ -> Error "Original history requires a configured installation" in
  let+ ()=require (actual_package=package_id && actual_tool=tool) "Original history package/tool differs" in
  {installation_id;package_id=actual_package;tool=actual_tool;source_revision;configuration_revision}
let prompt_json (p:Prompt_registry.prompt_resolution) = `Assoc [
  "effective",`String p.effective;"source",`String (Prompt_registry.prompt_source_to_string p.source);
  "file_value",optional (fun text -> `String text) p.file_value;
  "override_value",optional (fun text -> `String text) p.override_value;
  "file_path",optional (fun text -> `String text) p.file_path;
  "file_exists",`Bool p.file_exists;"has_override",`Bool p.has_override]
let prompt_of_json json =
  let* f=fields ["effective";"source";"file_value";"override_value";"file_path";"file_exists";"has_override"] json in
  let* effective=text (value "effective" f) in
  let* source=text (value "source" f) in
  let* source=match source with "file" -> Ok Prompt_registry.File | "override" -> Ok Prompt_registry.Override
    | "missing" -> Ok Prompt_registry.Missing | _ -> Error "Unknown original history prompt source" in
  let* file_value=option text (value "file_value" f) in
  let* override_value=option text (value "override_value" f) in
  let* file_path=option text (value "file_path" f) in
  let* file_exists=boolean (value "file_exists" f) in
  let+ has_override=boolean (value "has_override" f) in
  {Prompt_registry.effective;source;file_value;override_value;file_path;file_exists;has_override}
(* The substitutions and the rendered prompt repeat the input, so they are
   rendered again on restore; the digest names the prompt the host was sent. *)
let preparation_json (p:Runtime.durable_preparation) = `Assoc [
  "parsing_now",`Float p.parsing_now;
  "policy",`Assoc ["facts_max_bytes",`Int p.policy.facts_max_bytes;"category_cap",`Int p.policy.category_cap;
    "facts_per_category_cap",`Int p.policy.facts_per_category_cap];
  "rule_prompt",prompt_json p.rule_prompt;"prompt",prompt_json p.prompt;
  "rendered_prompt_sha256",`String (hash p.rendered_prompt);"output_schema",p.output_schema]
let preparation_of_json ~source_input json =
  let* f=fields ["parsing_now";"policy";"rule_prompt";"prompt";"rendered_prompt_sha256";"output_schema"] json in
  let* parsing_now=match value "parsing_now" f with
    | `Float time when Float.is_finite time -> Ok time | `Int time -> Ok (float_of_int time)
    | _ -> Error "Original history parse time is not finite" in
  let* limits=fields ["facts_max_bytes";"category_cap";"facts_per_category_cap"] (value "policy" f) in
  let* facts_max_bytes=integer (value "facts_max_bytes" limits) in
  let* category_cap=integer (value "category_cap" limits) in
  let* facts_per_category_cap=integer (value "facts_per_category_cap" limits) in
  let policy : Runtime.durable_policy = {facts_max_bytes;category_cap;facts_per_category_cap} in
  let* rule_prompt=prompt_of_json (value "rule_prompt" f) in
  let* prompt=prompt_of_json (value "prompt" f) in
  let* rendered_prompt_sha256=text (value "rendered_prompt_sha256" f) in
  let* p=Runtime.restore_durable_preparation ~source_input ~parsing_now ~policy ~rule_prompt ~prompt
    ~output_schema:(value "output_schema" f) in
  let+ ()=require (String.equal (hash p.rendered_prompt) rendered_prompt_sha256)
    "Original history prompt differs from the one its host request named" in p

type predecessor = {request_id:string;request_digest:string}
(* [digest] names the canonical bytes of [to_json]: the record's digest for a
   restored original, computed once for a new or freestanding one. Equal
   digests are equal requests, so a re-check of the same record compares this
   instead of decoding the body again. *)
type t = {id:string;owner:owner;destination:destination;source:Source.t;source_text:string;
  predecessor:predecessor option;
  preparation:Runtime.durable_preparation;digest:string}
let predecessor capture=capture.predecessor
let predecessor_json = function
  | None -> `Null
  | Some predecessor -> `Assoc ["request_id",`String predecessor.request_id;
      "request_digest",`String predecessor.request_digest]
let predecessor_of_json = function
  | `Null -> Ok None
  | json ->
    let* f=fields ["request_id";"request_digest"] json in
    let* request_id=nonblank (value "request_id" f) in
    let* request_digest=nonblank (value "request_digest" f) in
    let+ ()=require (String_util.is_lowercase_sha256_hex request_digest)
      "Original history predecessor digest is invalid" in
    Some {request_id;request_digest}
let request_id capture=capture.id
let physical_owner capture=capture.owner
let destination capture=capture.destination
let source capture=capture.source
let preparation capture=capture.preparation
let to_json capture = `Assoc ["schema",`Int 2;"kind",`String "completed-history-execution";
  "request_id",`String capture.id;"owner",owner_to_json capture.owner;
  "destination",destination_json capture.destination;"source_text",`String capture.source_text;
  "predecessor",predecessor_json capture.predecessor;
  "preparation",preparation_json capture.preparation]
let header_fields json = fields ["schema";"kind";"request_id";"owner";"destination";"source_text";"predecessor";"preparation"] json
let validate capture =
  let* expected_scope=scope_of_request_id capture.id in
  let* ()=require (expected_scope=scope capture.owner) "Original history execution belongs to another physical scope" in
  let* ()=match capture.predecessor with
    | None -> Ok ()
    | Some predecessor ->
      let* parent_scope=scope_of_request_id predecessor.request_id in
      require (parent_scope=expected_scope && predecessor.request_id<>capture.id
        && String_util.is_lowercase_sha256_hex predecessor.request_digest)
        "Original history predecessor belongs to another scope or itself" in
  let* ()=require (capture.preparation.source_input=Source.input capture.source)
    "Original history source and preparation input differ" in
  let* ()=require (Keeper_identity.Keeper_id.to_string (Source.input capture.source).keeper_id=capture.owner.keeper_id)
    "Original history source belongs to another Keeper" in
  let facts=match (Source.input capture.source).current with None -> [] | Some current -> current.facts in
  let ids=List.map Keeper_memory_os_types.memory_id facts in
  let* ()=require (List.length ids=List.length (List.sort_uniq String.compare ids))
    "Original history current Memory repeats an identity" in
  Runtime.validate_durable_preparation capture.preparation
let confirm_source_root capture =
  let* actual=Fs_compat.with_owned_inventory_root (Source.runtime_keepers_dir capture.source)
    (fun root -> Ok (physical root)) |> owned in
  require (actual=capture.owner.runtime)
    "Original history source came from another physical runtime/output root"
let create ?predecessor ~request_id ~owner ~destination ~source ~(preparation:Runtime.durable_preparation) () =
  let* destination=destination_of_json (destination_json destination) in
  let source_text=Yojson.Safe.to_string (Source.to_json source) in
  let* source=Source.of_json (Source.to_json source) |> Result.map_error Source.error_to_string in
  let* ()=require (preparation.source_input=Source.input source)
    "Original history preparation does not describe its source" in
  let* preparation=preparation_of_json ~source_input:(Source.input source) (preparation_json preparation) in
  let capture={id=request_id;owner;destination;source;source_text;predecessor;preparation;digest=""} in
  let* ()=validate capture in
  let* ()=confirm_source_root capture in
  let+ digest=Owner.request_digest (to_json capture) in {capture with digest}
let decode ~owner ~digest json =
  let* f=header_fields json in
  let* ()=require (value "schema" f=`Int 2 && value "kind" f=`String "completed-history-execution")
    "Unknown original history schema or kind" in
  let* id=nonblank (value "request_id" f) in
  let* ()=owner_matches_json owner (value "owner" f) in
  let* destination=destination_of_json (value "destination" f) in
  let* predecessor=predecessor_of_json (value "predecessor" f) in
  let* source_text=text (value "source_text" f) in
  let* source_json=parse source_text in
  let* source=Source.of_json source_json |> Result.map_error Source.error_to_string in
  let* ()=require (Yojson.Safe.to_string (Source.to_json source)=source_text)
    "Original history source text is not its complete canonical encoding" in
  let* preparation=preparation_of_json ~source_input:(Source.input source) (value "preparation" f) in
  let capture={id;owner;destination;source;source_text;predecessor;preparation;digest=""} in
  let* ()=validate capture in
  let* ()=equal json (to_json capture) "Original history request encoding differs" in
  let+ digest=match digest with Some digest -> Ok digest | None -> Owner.request_digest json in
  {capture with digest}
let of_json ~owner json = decode ~owner ~digest:None json
let restore ~owner (record:Owner.retained) =
  (* The record's digest named the body [Owner.load] verified, and [decode]
     requires that body to be this request's canonical encoding. *)
  let* capture=decode ~owner ~digest:(Some record.request_digest) record.request in
  let* ()=confirm_source_root capture in
  let id=capture.id and destination=capture.destination in
  let* ()=require (record.scope=scope owner && record.request_id=id
    && record.installation_id=destination.installation_id && record.package_id=destination.package_id
    && record.tool=destination.tool) "Original history host binding differs" in
  let+ ()=equal record.request (to_json capture) "Original history request encoding differs" in capture
let confirm_record capture (record:Owner.retained) =
  let* ()=confirm_source_root capture in
  let destination=capture.destination in
  let* ()=require (record.scope=scope capture.owner && record.request_id=capture.id
    && record.installation_id=destination.installation_id && record.package_id=destination.package_id
    && record.tool=destination.tool) "Original history host binding differs" in
  require (String.equal record.request_digest capture.digest)
    "Original history record names another request"
let confirm_predecessor ~store ~require_confirmed capture =
  match capture.predecessor with
  | None -> Ok ()
  | Some predecessor ->
    let owner=capture.owner in
    let* parent=Owner.load ~store ~scope:(scope owner) ~request_id:predecessor.request_id
      |> Result.map_error Owner.error_to_string in
    let* parent=Option.to_result ~none:"History replacement predecessor is absent" parent in
    let* ()=require (parent.request_digest=predecessor.request_digest)
      "History replacement predecessor digest changed" in
    let* _=restore ~owner parent in
    let* ()=match Progress.phase parent.progress with
      | Progress.Conflicted _ -> Ok ()
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Rejected _ | Subdividing _ | Subdivided _ ->
        Error "History replacement predecessor is not conflicted" in
    let* intended=match Progress.replacement parent.progress with
      | Some (Preparation_confirmed intended) -> Ok intended
      | Some (Preparation_pending intended) when not require_confirmed -> Ok intended
      | None | Some (Preparation_pending _) ->
        Error "History replacement has no acknowledged original publication" in
    let* ()=require (intended.request_id=capture.id)
      "History replacement predecessor names another child" in
    equal intended.request (to_json capture) "History replacement differs from its full original parent intent"
let observe_record_owner ~base_path ~keepers_dir (record:Owner.retained) =
  let* f=header_fields record.request in
  let* original=owner_of_json (value "owner" f) in
  let* expected_scope=scope_of_request_id record.request_id in
  let* ()=require (record.scope=expected_scope && expected_scope=scope original)
    "Original history host record belongs to another scope" in
  let* current=observe_owner ~base_path ~keepers_dir ~keeper_id:original.keeper_id in
  let+ ()=owner_matches_json current (value "owner" f) in current
let request capture = Exact.request_of_json (`Assoc ["kind",`String "exact_output";
  "request_id",`String capture.id;"output",`String "durable";
  "messages",`List [`Assoc ["role",`String "user";"text",`String capture.preparation.rendered_prompt]];
  "schema",capture.preparation.output_schema])
let confirm_owner capture =
  let* current=observe_owner ~base_path:capture.owner.workspace.path ~keepers_dir:capture.owner.keepers.path
    ~keeper_id:capture.owner.keeper_id in
  owner_matches_json current (owner_to_json capture.owner)
let confirm_final ~store capture final =
  let* ()=confirm_owner capture in
  let* exact=request capture in
  let* schema=Option.to_result ~none:"Original history request lacks its schema" exact.Exact.schema in
  let* installation=Owner.installation_of_id capture.destination.installation_id in
  let* declaration_id=match installation with Owner.Configuration id -> Ok id
    | Manual _ -> Error "Original history requires a configured host installation" in
  let* observed=Exact.observe_retained ~store ~declaration_id ~schema exact in
  match observed with
  | Exact.Retained_absent ->
    (* addons/exact_worker.py [submit] writes the refusal before the
       [store.write accepted] line, so the host never retains this request.
       The worker's deployed behavior is what makes this final the only one
       taken without a host terminal. *)
    if Exact.refused_before_host final then Ok ()
    else Error "Original history host terminal is absent"
  | Retained_open -> Error "Original history host terminal is unresolved"
  | Retained_terminal actual ->
  let* ()=equal (Exact.final_to_json (Exact.delivered actual)) (Exact.final_to_json final)
    "Original history final differs from the actual host terminal" in
  match final with
  | Exact.Call_final expected ->
    let* latest=Exact.read_latest_original_execution ~store ~declaration_id ~schema exact in
    (match latest with
     | Exact.No_completed_latest -> Error "Original history latest host execution proof is incomplete"
     | Completed_latest {attempt_ordinal;execution={outcome=Exact.Call_ended actual;_}} ->
       let* ()=require (attempt_ordinal>0) "Original history host attempt ordinal is invalid" in
       equal (Exact.final_to_json (Exact.Call_final expected)) (Exact.final_to_json (Exact.Call_final actual))
         "Original history final differs from its latest completed host execution"
     | Completed_latest {execution={outcome=Exact.Call_refused _;_};_} ->
       Error "Original history refused host execution cannot confirm a call result")
  | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused -> Ok ()
let validate_proposal capture output =
  Runtime.validate_durable_proposal capture.preparation output |> Result.map_error (function
    | Runtime.Preparation_invalid detail -> detail
    | Proposal_invalid error -> Keeper_librarian.parse_error_to_string error)

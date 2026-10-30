module L = Keeper_librarian
module Runtime = Keeper_librarian_runtime
module Queue = Keeper_memory_admission_queue
module Current = Keeper_memory_os_current
module Judgment = Keeper_memory_admission_judgment
module Types = Keeper_memory_os_types
module Owner = Lane_addon_tool_request_owner
let ( let* ) = Result.bind
let ( let+ ) result f = Result.map f result

let object_fields expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare expected -> Ok fields
  | _ -> Error "Original Librarian capture has unknown, missing or repeated fields"
let value key fields = List.assoc key fields
let text = function `String value -> Ok value | _ -> Error "Original Librarian capture expects text"
let nonblank json = let* value=text json in
  if String.trim value<>"" then Ok value else Error "Original Librarian capture expects nonblank text"
let integer = function `Int value -> Ok value | _ -> Error "Original Librarian capture expects an integer"
let number = function
  | `Float value when Float.is_finite value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error "Original Librarian capture expects a finite time"
let boolean = function `Bool value -> Ok value | _ -> Error "Original Librarian capture expects a boolean"
let list decode = function
  | `List values -> List.fold_right (fun value result -> let* value=decode value in let+ rest=result in value::rest) values (Ok [])
  | _ -> Error "Original Librarian capture expects an array"
let option decode = function `Null -> Ok None | json -> let+ value=decode json in Some value
let optional encode = Option.fold ~none:`Null ~some:encode
let parse raw = try Ok (Yojson.Safe.from_string raw) with Yojson.Json_error detail -> Error detail
let same_json left right =
  let* left=Lane_addon_action.canonical left in
  let+ right=Lane_addon_action.canonical right in Yojson.Safe.equal left right
let wire result = Result.map_error Types.wire_error_to_string result

type physical = {path:string;device:int;inode:int}
type owner = {workspace:physical;keepers:physical;keeper_id:string;epoch:string;queue_generation:string}
type scope_identity = string
let physical_json physical = `Assoc ["device",`Int physical.device;"inode",`Int physical.inode;"path",`String physical.path]
let physical_of_json json =
  let* fields=object_fields ["path";"device";"inode"] json in
  let* path=nonblank (value "path" fields) in
  let* device=integer (value "device" fields) in
  let* inode=integer (value "inode" fields) in
  if Filename.is_relative path then Error "Original owner path is relative" else Ok {path;device;inode}
let owner_to_json owner = `Assoc ["epoch",`String owner.epoch;"keeper_id",`String owner.keeper_id;
  "keepers",physical_json owner.keepers;"queue_generation",`String owner.queue_generation;
  "workspace",physical_json owner.workspace]
let scope_identity owner = Yojson.Safe.to_string (`Assoc [
  "keeper_id",`String owner.keeper_id;"keepers",physical_json owner.keepers;
  "queue_generation",`String owner.queue_generation;"workspace",physical_json owner.workspace])
let scope_hash identity = Agent_core_sha256.(to_hex (digest_string identity))
let keeper_id owner = owner.keeper_id
let base_path owner = owner.workspace.path
let keepers_dir owner = owner.keepers.path
let owner_of_json json =
  let* fields=object_fields ["workspace";"keepers";"keeper_id";"epoch";"queue_generation"] json in
  let* workspace=physical_of_json (value "workspace" fields) in
  let* keepers=physical_of_json (value "keepers" fields) in
  let* keeper_id=nonblank (value "keeper_id" fields) in
  let* epoch=nonblank (value "epoch" fields) in
  let* queue_generation=nonblank (value "queue_generation" fields) in
  let* ()=match Keeper_identity.Keeper_id.of_string keeper_id with
    | Some id when Keeper_identity.Keeper_id.to_string id=keeper_id && Keeper_config_text.validate_name keeper_id -> Ok ()
    | Some _ | None -> Error "Original Librarian owner requires a canonical Keeper ID" in
  if epoch=String.trim epoch && queue_generation=String.trim queue_generation
  then Ok {workspace;keepers;keeper_id;epoch;queue_generation}
  else Error "Original Memory incarnation epoch is noncanonical"
let owner_matches_json owner json =
  let* restored=owner_of_json json in
  if owner=restored then Ok () else Error "Original Librarian physical owner or Memory incarnation changed"
let observe_owner ~base_path ~keepers_dir ~keeper_id =
  let* canonical_keeper=match Keeper_identity.Keeper_id.of_string keeper_id with
    | Some id when Keeper_identity.Keeper_id.to_string id=keeper_id && Keeper_config_text.validate_name keeper_id -> Ok keeper_id
    | Some _ | None -> Error "Original Librarian owner requires a canonical Keeper ID" in
  (* The epoch file is read below the held keepers root, so it is named by its
     components from that root, not by a path spelled from [keepers_dir]. *)
  let* epoch_entry=Fs_compat.owned_relative_path
    [Filename.basename (Current.epoch_path ~keepers_dir ~keeper_id:canonical_keeper)] in
  let physical root=let stat=Fs_compat.owned_inventory_root_stat root in
    {path=Fs_compat.owned_inventory_root_path root;device=stat.Unix.st_dev;inode=stat.Unix.st_ino} in
  let observed=Fs_compat.with_owned_inventory_root base_path (fun workspace ->
    Fs_compat.with_owned_inventory_root keepers_dir (fun keepers ->
      let workspace=physical workspace and keepers_identity=physical keepers in
      Fs_compat.with_owned_inventory_regular_file ~owner_uid:(Unix.getuid ()) keepers epoch_entry
        (fun ~file ~parent:_ ~stat ->
          let bytes=Bytes.create stat.Unix.st_size in
          let rec read position =
            if position=Bytes.length bytes then Bytes.to_string bytes
            else match Unix.read file bytes position (Bytes.length bytes-position) with
              | 0 -> raise End_of_file
              | count -> read (position+count)
              | exception Unix.Unix_error (Unix.EINTR,_,_) -> read position in
          let queue_generation=Queue.read_generation ~keepers_dir:keepers_identity.path
            ~keeper_id:canonical_keeper in
          workspace,keepers_identity,queue_generation,read 0)))
    |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
  let* workspace,keepers,generation,bytes=observed in
  let* generation=generation in
  let* queue_generation=match generation with
    | Some generation -> Ok generation
    | None -> Error "Original Librarian owner has no persisted Queue generation" in
  let* json=parse bytes in
  let* fields=object_fields ["schema_version";"epoch"] json in
  let* schema=integer (value "schema_version" fields) in
  let* epoch=nonblank (value "epoch" fields) in
  if schema<>1 || epoch<>String.trim epoch then Error "Invalid original Memory incarnation epoch"
  else Ok {workspace;keepers;keeper_id=canonical_keeper;epoch;queue_generation}

type destination = {installation_id:string;package_id:string;tool:string;source_revision:string;configuration_revision:string}
let owner_hash owner = scope_hash (scope_identity owner)
let scope_for_hash hash="keeper-librarian-execution-" ^ hash
let scope owner=scope_for_hash (owner_hash owner)
let fresh_request_id owner=Yojson.Safe.to_string (`List [
  `String "keeper-librarian";`String (owner_hash owner);`String (Random_id.uuid_v7 ())])
let scope_of_request_id request_id =
  let* json=parse request_id in
  match json with
  | `List [`String "keeper-librarian";`String hash;`String nonce]
      when String_util.is_lowercase_sha256_hex hash && Yojson.Safe.to_string json=request_id ->
    let+ _=Random_id.parse_uuid_v7 nonce in scope_for_hash hash
  | _ -> Error "Invalid original Librarian execution request ID"
let package_id = Keeper_librarian_addon.package_id
let tool = Keeper_librarian_addon.tool Keeper_librarian_addon.Admission
let observe_record_owner ~base_path ~keepers_dir (retained:Owner.retained) =
  let* fields=object_fields ["schema";"kind";"request_id";"parent_part_id";"owner";"destination";
    "candidate_ids";"batch_text";"input_text";"expected_revision";"now";"retirement_text";"preparation"] retained.request in
  let owner_json=value "owner" fields in
  let* original_owner=owner_of_json owner_json in
  let* expected_scope=scope_of_request_id retained.request_id in
  let* ()=if retained.scope=expected_scope && expected_scope=scope original_owner
    then Ok () else Error "Original request has another physical execution scope" in
  let* owner=observe_owner ~base_path ~keepers_dir ~keeper_id:original_owner.keeper_id in
  let* ()=owner_matches_json owner owner_json in Ok owner
let destination_json destination = `Assoc ["installation_id",`String destination.installation_id;
  "package_id",`String destination.package_id;"tool",`String destination.tool;
  "source_revision",`String destination.source_revision;"configuration_revision",`String destination.configuration_revision]
let destination_of_json json =
  let* fields=object_fields ["installation_id";"package_id";"tool";"source_revision";"configuration_revision"] json in
  let* installation_id=nonblank (value "installation_id" fields) in
  let* package_id=nonblank (value "package_id" fields) in
  let* tool=nonblank (value "tool" fields) in
  let* source_revision=nonblank (value "source_revision" fields) in
  let+ configuration_revision=nonblank (value "configuration_revision" fields) in
  {installation_id;package_id;tool;source_revision;configuration_revision}

let input_json = Keeper_librarian_input_capture.to_json
let check_pending_input (input:L.input) =
  if input.historical_task_contexts=[] && input.working_context=Keeper_librarian_context.empty
    && input.messages=[] && input.tool_observations=[] && input.counterpart_observations=[]
  then Ok () else Error "Explicit-candidate execution cannot replace another Librarian pass's original input"
let input_of_json json =
  let* input=Keeper_librarian_input_capture.of_json json in
  let* ()=check_pending_input input in
  let* same=same_json json (input_json input) in
  if same then Ok input else Error "Original pending-candidate input has noncanonical typed content"

let retirement_json = function
  | Judgment.Unavailable detail -> `Assoc ["kind",`String "unavailable";"detail",`String detail]
  | Available archive -> `Assoc ["kind",`String "available";"archive",`List (List.map (fun (entry:Current.archived_fact) ->
      let removal=entry.removal in
      `Assoc ["original",Types.fact_to_json entry.original;"removal",`Assoc [
        "removed_in_revision",`Int removal.removed_in_revision;"removed_at",`Float removal.removed_at;
        "removed_by",`Assoc ["kind",`String (Current.source_kind_to_string removal.removed_by.kind);
          "trace_id",`String removal.removed_by.trace_id];
        "removed_origin",`String (Types.origin_kind_to_string removal.removed_origin);
        "drop_reason",optional (fun value -> `String value) removal.drop_reason]]) archive)]
let retirement_of_json json =
  let* all=match json with `Assoc fields -> Ok fields | _ -> Error "Original retirement evidence is not an object" in
  let* kind=nonblank (match List.assoc_opt "kind" all with Some value -> value | None -> `Null) in
  match kind with
  | "unavailable" -> let* fields=object_fields ["kind";"detail"] json in let+ detail=text (value "detail" fields) in Judgment.Unavailable detail
  | "available" ->
    let* fields=object_fields ["kind";"archive"] json in
    let+ archive=list (fun json ->
      let* fields=object_fields ["original";"removal"] json in
      let* original=Types.fact_of_json (value "original" fields) |> wire in
      let* fields=object_fields ["removed_in_revision";"removed_at";"removed_by";"removed_origin";"drop_reason"] (value "removal" fields) in
      let* removed_in_revision=integer (value "removed_in_revision" fields) in
      let* removed_at=number (value "removed_at" fields) in
      let* source_fields=object_fields ["kind";"trace_id"] (value "removed_by" fields) in
      let* kind=nonblank (value "kind" source_fields) in
      let* kind=match kind with "librarian" -> Ok Current.Librarian | "explicit_write" -> Ok Current.Explicit_write
        | "explicit_retract" -> Ok Current.Explicit_retract | _ -> Error "Unknown original retirement source" in
      let* trace_id=text (value "trace_id" source_fields) in
      let* origin=nonblank (value "removed_origin" fields) in
      let* removed_origin=match origin with "authored" -> Ok Types.Authored | "injected" -> Ok Types.Injected
        | _ -> Error "Unknown original retirement origin" in
      let* drop_reason=option text (value "drop_reason" fields) in
      if removed_in_revision<0 || removed_at<0. then Error "Invalid original retirement coordinate"
      else Ok {Current.original;removal={Current.removed_in_revision;removed_at;removed_by={Current.kind;trace_id};removed_origin;drop_reason}})
      (value "archive" fields) in Judgment.Available archive
  | _ -> Error "Unknown original retirement availability"

let prompt_json (p:Prompt_registry.prompt_resolution) = `Assoc ["effective",`String p.effective;
  "source",`String (Prompt_registry.prompt_source_to_string p.source);
  "file_value",optional (fun value -> `String value) p.file_value;
  "override_value",optional (fun value -> `String value) p.override_value;
  "file_path",optional (fun value -> `String value) p.file_path;
  "file_exists",`Bool p.file_exists;"has_override",`Bool p.has_override]
let prompt_of_json json =
  let* fields=object_fields ["effective";"source";"file_value";"override_value";"file_path";"file_exists";"has_override"] json in
  let* effective=text (value "effective" fields) in
  let* source=nonblank (value "source" fields) in
  let* source=match source with "file" -> Ok Prompt_registry.File | "override" -> Ok Prompt_registry.Override
    | "missing" -> Ok Prompt_registry.Missing | _ -> Error "Unknown original prompt source" in
  let* file_value=option text (value "file_value" fields) in
  let* override_value=option text (value "override_value" fields) in
  let* file_path=option text (value "file_path" fields) in
  let* file_exists=boolean (value "file_exists" fields) in
  let+ has_override=boolean (value "has_override" fields) in
  {Prompt_registry.effective;source;file_value;override_value;file_path;file_exists;has_override}
let preparation_json (prepared:Runtime.admission_preparation) = `Assoc [
  "policy",`Assoc ["facts_max_bytes",`Int prepared.policy.facts_max_bytes;
    "category_cap",`Int prepared.policy.category_cap;"facts_per_category_cap",`Int prepared.policy.facts_per_category_cap];
  "rule_prompt",prompt_json prepared.rule_prompt;"prompt",prompt_json prepared.prompt;
  "admission_prompt",prompt_json prepared.admission_prompt;
  "retirement_prompt",prompt_json prepared.retirement_prompt;
  "variables",`List (List.map (fun (key,value) -> `Assoc ["key",`String key;"value",`String value]) prepared.variables);
  "rendered_prompt",`String prepared.rendered_prompt;"output_schema",prepared.output_schema]
let preparation_of_json json =
  let* fields=object_fields ["policy";"rule_prompt";"prompt";"admission_prompt";"retirement_prompt";"variables";"rendered_prompt";"output_schema"] json in
  let* policy_fields=object_fields ["facts_max_bytes";"category_cap";"facts_per_category_cap"] (value "policy" fields) in
  let* facts_max_bytes=integer (value "facts_max_bytes" policy_fields) in
  let* category_cap=integer (value "category_cap" policy_fields) in
  let* facts_per_category_cap=integer (value "facts_per_category_cap" policy_fields) in
  let policy={Runtime.facts_max_bytes;category_cap;facts_per_category_cap} in
  let* rule_prompt=prompt_of_json (value "rule_prompt" fields) in
  let* prompt=prompt_of_json (value "prompt" fields) in
  let* admission_prompt=prompt_of_json (value "admission_prompt" fields) in
  let* retirement_prompt=prompt_of_json (value "retirement_prompt" fields) in
  let* variables=list (fun json -> let* fields=object_fields ["key";"value"] json in
    let* key=nonblank (value "key" fields) in let+ value=text (value "value" fields) in key,value)
    (value "variables" fields) in
  let+ rendered_prompt=nonblank (value "rendered_prompt" fields) in
  {Runtime.policy;rule_prompt;prompt;admission_prompt;retirement_prompt;variables;rendered_prompt;output_schema=value "output_schema" fields}

let candidate_json (id:Current.explicit_candidate_id) = `Assoc [
  "queue_generation",`String id.queue_generation;"request_id",`String id.request_id;
  "sequence",`Int id.sequence;"input_sha256",`String id.input_sha256]
let candidate_of_json json =
  let* fields=object_fields ["queue_generation";"request_id";"sequence";"input_sha256"] json in
  let* queue_generation=nonblank (value "queue_generation" fields) in
  let* request_id=nonblank (value "request_id" fields) in
  let* sequence=integer (value "sequence" fields) in
  let* input_sha256=nonblank (value "input_sha256" fields) in
  if queue_generation<>String.trim queue_generation || request_id<>String.trim request_id
    || sequence<=0 || not (String_util.is_lowercase_sha256_hex input_sha256)
  then Error "Invalid original candidate identity"
  else Ok {Current.queue_generation;request_id;sequence;input_sha256}

type t = {
  id:string; parent:string; owner:owner; destination:destination;
  original_batch:Queue.batch; original_input:L.input; revision:int option; parsing_now:float;
  retirement:Judgment.retirement_evidence; preparation:Runtime.admission_preparation;
  batch_text:string; input_text:string; retirement_text:string;
}
let request_id capture=capture.id
let parent_part_id capture=capture.parent
let destination capture=capture.destination
let batch capture=capture.original_batch
let input capture=capture.original_input
let expected_revision capture=capture.revision
let now capture=capture.parsing_now
let to_json capture = `Assoc ["schema",`Int 2;"kind",`String "execution";
  "request_id",`String capture.id;"parent_part_id",`String capture.parent;"owner",owner_to_json capture.owner;
  "destination",destination_json capture.destination;
  "candidate_ids",`List (List.map candidate_json (Queue.candidate_ids capture.original_batch));
  "batch_text",`String capture.batch_text;"input_text",`String capture.input_text;
  "expected_revision",optional (fun revision -> `Int revision) capture.revision;
  "now",`Float capture.parsing_now;"retirement_text",`String capture.retirement_text;
  "preparation",preparation_json capture.preparation]
let validate capture =
  let* ()=if capture.id<>"" && capture.id=String.trim capture.id
      && capture.parent<>"" && capture.parent=String.trim capture.parent && capture.id<>capture.parent
    then Ok () else Error "Invalid original execution or parent-part identity" in
  let* expected_scope=scope_of_request_id capture.id in
  let* ()=if expected_scope=scope capture.owner then Ok ()
    else Error "Original execution ID belongs to another physical Keeper/epoch" in
  let* ()=if List.for_all (fun (id : Current.explicit_candidate_id) ->
      id.queue_generation=capture.owner.queue_generation) (Queue.candidate_ids capture.original_batch)
    then Ok () else Error "Original batch belongs to another Queue generation" in
  let* ()=check_pending_input capture.original_input in
  let* ()=if Keeper_identity.Keeper_id.to_string capture.original_input.keeper_id=capture.owner.keeper_id
    then Ok () else Error "Original execution input belongs to another Keeper" in
  let* ()=if Float.is_finite capture.parsing_now && capture.parsing_now>=0.
    then Ok () else Error "Invalid original parsing time" in
  let* ()=match capture.revision,capture.original_input.current with
    | None,None -> Ok ()
    | Some revision,Some _ when revision>=0 -> Ok ()
    | (None|Some _),(None|Some _) -> Error "Original Memory revision and full snapshot presence differ" in
  let* ()=if capture.destination.package_id=package_id && capture.destination.tool=tool
    then Ok () else Error "Original execution has another package or tool" in
  let* installation=Owner.installation_of_id capture.destination.installation_id in
  let* ()=match installation with Owner.Configuration _ -> Ok ()
    | Owner.Manual _ -> Error "Original Librarian execution requires a configured installation" in
  let facts=match capture.original_input.current with None -> [] | Some current -> current.facts in
  let ids=List.map Types.memory_id facts in
  let* ()=if List.length ids=List.length (List.sort_uniq String.compare ids) then Ok ()
    else Error "Original current Memory contains duplicate identities" in
  Runtime.validate_admission_preparation ~batch:capture.original_batch ~retirement:capture.retirement
    ~input:capture.original_input capture.preparation
let create ~request_id ~parent_part_id ~owner ~destination ~batch ~input ~expected_revision ~now
    ~retirement ~preparation =
  let* ()=check_pending_input input in
  let* destination=destination_of_json (destination_json destination) in
  let batch_text=Yojson.Safe.to_string (Queue.batch_to_json batch)
  and input_text=Yojson.Safe.to_string (input_json input)
  and retirement_text=Yojson.Safe.to_string (retirement_json retirement) in
  (* Round-trip the typed snapshots through the same strict decoder used after
     retention, while preserving the original substitution byte strings. *)
  let* original_batch=Queue.batch_of_json ~expected_candidate_ids:(Queue.candidate_ids batch)
    (Queue.batch_to_json batch) in
  let* original_input=input_of_json (input_json input) in
  let* retirement=retirement_of_json (retirement_json retirement) in
  let* preparation=preparation_of_json (preparation_json preparation) in
  let capture={id=request_id;parent=parent_part_id;owner;destination;original_batch;original_input;
    revision=expected_revision;parsing_now=now;retirement;preparation;batch_text;input_text;retirement_text} in
  let* ()=validate capture in Ok capture
let restore ~owner ~load_parent (retained:Owner.retained) =
  let* fields=object_fields ["schema";"kind";"request_id";"parent_part_id";"owner";"destination";
    "candidate_ids";"batch_text";"input_text";"expected_revision";"now";"retirement_text";"preparation"] retained.request in
  let* schema=integer (value "schema" fields) in
  let* kind=nonblank (value "kind" fields) in
  let* ()=if schema=2 && kind="execution" then Ok () else Error "Unknown original Librarian execution schema/kind" in
  let* id=nonblank (value "request_id" fields) in
  let* parent=nonblank (value "parent_part_id" fields) in
  let* ()=owner_matches_json owner (value "owner" fields) in
  let* destination=destination_of_json (value "destination" fields) in
  let* candidate_ids=list candidate_of_json (value "candidate_ids" fields) in
  let* batch_text=text (value "batch_text" fields) in
  let* batch_json=parse batch_text in
  let* original_batch=Queue.batch_of_json ~expected_candidate_ids:candidate_ids batch_json in
  let* input_text=text (value "input_text" fields) in
  let* input_json=parse input_text in
  let* original_input=input_of_json input_json in
  let* revision=option integer (value "expected_revision" fields) in
  let* parsing_now=number (value "now" fields) in
  let* retirement_text=text (value "retirement_text" fields) in
  let* retirement_json=parse retirement_text in
  let* retirement=retirement_of_json retirement_json in
  let* preparation=preparation_of_json (value "preparation" fields) in
  let capture={id;parent;owner;destination;original_batch;original_input;revision;parsing_now;
    retirement;preparation;batch_text;input_text;retirement_text} in
  let* ()=validate capture in
  let* ()=if retained.scope=scope owner && retained.request_id=id
      && retained.installation_id=destination.installation_id && retained.package_id=destination.package_id
      && retained.tool=destination.tool then Ok () else Error "Original execution differs from its retained host owner" in
  let* same=same_json retained.request (to_json capture) in
  let* ()=if same then Ok () else Error "Noncanonical original execution capture" in
  let* parent_batch=load_parent ~request_id:parent in
  let* same=same_json (Queue.batch_to_json parent_batch) (Queue.batch_to_json original_batch) in
  if same && Queue.candidate_ids parent_batch=candidate_ids then Ok capture
  else Error "Original execution batch differs from its strictly restored parent part"
let request capture = Lane_addon_exact.request_of_json (`Assoc [
  "kind",`String "exact_output";"request_id",`String capture.id;"output",`String "admission";
  "messages",`List [`Assoc ["role",`String "user";"text",`String capture.preparation.rendered_prompt]];
  "schema",capture.preparation.output_schema])
let validate_proposal capture output =
  Runtime.validate_admission_proposal ~now:capture.parsing_now ~batch:capture.original_batch
    ~input:capture.original_input output |> Result.map_error L.parse_error_to_string

let confirm_final ~store (capture:t) (final:Lane_addon_exact.final) =
  let module Exact = Lane_addon_exact in
  let* actual_owner = observe_owner ~base_path:(base_path capture.owner)
    ~keepers_dir:(keepers_dir capture.owner) ~keeper_id:(keeper_id capture.owner) in
  let* () = owner_matches_json actual_owner (owner_to_json capture.owner) in
  let* original = request capture in
  let* schema = Option.to_result ~none:"Original admission host proof has no schema" original.Exact.schema in
  let* installation = Owner.installation_of_id capture.destination.installation_id in
  let* declaration_id = match installation with
    | Owner.Configuration id -> Ok id
    | Manual _ -> Error "Original admission host proof requires its configured installation" in
  let* observed = Exact.observe_retained ~store ~declaration_id ~schema original in
  (* The worker refuses an unlistable request before the host retains it
     (addons/exact_worker.py [submit]), so the host holds no terminal and no
     execution proof for it. Keeper_librarian_durable_request.confirm_final
     answers the same way for the same final. *)
  let host_never_retained = match observed with
    | Exact.Retained_absent -> Exact.refused_before_host final
    | Retained_open | Retained_terminal _ -> false in
  if host_never_retained then Ok () else
  let* () = match observed with
    | Exact.Retained_absent -> Error "Original admission host terminal is absent"
    | Retained_open -> Error "Original admission host terminal remains unresolved"
    | Retained_terminal retained ->
      let* same = same_json (Exact.final_to_json (Exact.delivered retained)) (Exact.final_to_json final) in
      if same then Ok () else Error "Admission final differs from its original host terminal" in
  match final with
  | Exact.Call_final call_final ->
    let* latest = Exact.read_latest_original_execution ~store ~declaration_id ~schema original in
    (match latest with
     | Exact.No_completed_latest -> Error "Original admission has no completed latest host execution proof"
     | Completed_latest {attempt_ordinal;execution={outcome=Exact.Call_ended actual;_}} ->
       let* same = same_json (Exact.final_to_json (Exact.Call_final actual))
         (Exact.final_to_json (Exact.Call_final call_final)) in
       if attempt_ordinal>0 && same then Ok ()
       else Error "Admission final differs from its latest original host execution proof"
     | Completed_latest {execution={outcome=Exact.Call_refused _;_};_} ->
       Error "Original refused execution cannot confirm a completed admission answer")
  | Outcome_unknown | Not_allowed _ | Request_id_reused -> Ok ()

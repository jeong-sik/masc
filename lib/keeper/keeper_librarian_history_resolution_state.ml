module Request = Keeper_librarian_durable_request
module Source = Keeper_librarian_durable_capture
module Owner = Lane_addon_tool_request_owner
module Store = Lane_addon_store
module Json = Candle_json
open Result.Syntax

type guard = {
  owner_record_sha256 : string;
  memory_revision : int option;
  memory_sha256 : string option;
  cursors_sha256 : string;
}
type t = {
  scope : string; request_id : string; request_digest : string;
  physical_owner : Yojson.Safe.t; source_sha256 : string;
  original_record : Yojson.Safe.t; expected : guard;
  actor : string; reason : string; fenced_at : float;
}
let require condition message = if condition then Ok () else Error message
let sha bytes = Agent_core_sha256.(to_hex (digest_string bytes))
let digest json = let+ canonical = Lane_addon_action.canonical json in
  sha (Yojson.Safe.to_string canonical)
let hash = function
  | `String value when String_util.is_lowercase_sha256_hex value -> Ok value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
    Error "Expected a lowercase SHA-256 digest"
let revision = function
  | `Int value when value >= 0 -> Ok value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
    Error "Expected a nonnegative Memory revision"
let option encode = function None -> `Null | Some value -> encode value
let guard_to_json guard = `Assoc [
  "owner_record_sha256", `String guard.owner_record_sha256;
  "memory_revision", option (fun value -> `Int value) guard.memory_revision;
  "memory_sha256", option (fun value -> `String value) guard.memory_sha256;
  "cursors_sha256", `String guard.cursors_sha256]
let guard_of_json json =
  let context = "history fence guard" in
  let* fields = Json.object_fields ~context json in
  let* owner_record_sha256, fields = Json.field ~context "owner_record_sha256" hash fields in
  let* memory_revision, fields = Json.field ~context "memory_revision" (Json.as_nullable revision) fields in
  let* memory_sha256, fields = Json.field ~context "memory_sha256" (Json.as_nullable hash) fields in
  let* cursors_sha256, fields = Json.field ~context "cursors_sha256" hash fields in
  let* () = Json.finish ~context fields in
  let+ () = require (Option.is_some memory_revision = Option.is_some memory_sha256)
    "History fence Memory observation has inconsistent presence" in
  {owner_record_sha256; memory_revision; memory_sha256; cursors_sha256}
let to_json fence = `Assoc [
  "schema", `String "keeper.librarian.history-fence.v1";
  "scope", `String fence.scope; "request_id", `String fence.request_id;
  "request_digest", `String fence.request_digest;
  "physical_owner", fence.physical_owner; "source_sha256", `String fence.source_sha256;
  "original_record", fence.original_record; "expected", guard_to_json fence.expected;
  "actor", `String fence.actor; "reason", `String fence.reason;
  "fenced_at", `Float fence.fenced_at]
let of_json json =
  let context = "history fence" in
  let* fields = Json.object_fields ~context json in
  let* schema, fields = Json.field ~context "schema" Json.as_string fields in
  let* () = require (schema = "keeper.librarian.history-fence.v1") "Unknown history fence schema" in
  let* scope, fields = Json.field ~context "scope" Json.as_non_blank fields in
  let* request_id, fields = Json.field ~context "request_id" Json.as_non_blank fields in
  let* request_digest, fields = Json.field ~context "request_digest" hash fields in
  let* owner, fields = Json.field ~context "physical_owner" Request.owner_of_json fields in
  let* source_sha256, fields = Json.field ~context "source_sha256" hash fields in
  let* original_record, fields = Json.field ~context "original_record" Result.ok fields in
  let* original = Owner.decode_published ~directory_name:(sha scope)
    ~file_name:(sha request_id ^ ".json") original_record in
  let* expected, fields = Json.field ~context "expected" guard_of_json fields in
  let* actor, fields = Json.field ~context "actor" Json.as_non_blank fields in
  let* reason, fields = Json.field ~context "reason" Json.as_non_blank fields in
  let clock = function
    | `Float value when Float.is_finite value && value >= 0. -> Ok value
    | `Int value when value >= 0 -> Ok (float_of_int value)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
      Error "Invalid history fence time" in
  let* fenced_at, fields = Json.field ~context "fenced_at" clock fields in
  let* () = Json.finish ~context fields in
  let* original_sha256 = digest original_record in
  let* id_scope = Request.scope_of_request_id request_id in
  let* () = require (id_scope = scope && Request.scope owner = scope
    && Owner.Record.request_id original = request_id
    && Owner.Record.request_digest original = request_digest
    && expected.owner_record_sha256 = original_sha256)
    "History fence original identity differs" in
  let+ () = match Lane_addon_request_progress.phase (Owner.Record.progress original) with
    | Dispatch_pending (Some (Absent _)) -> Ok ()
    | Captured | Admission_wait _ | Dispatch_pending (None | Some (Waiting _ | Outcome_unknown _))
    | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _ | Rejected _
    | Subdividing _ | Subdivided _ -> Error "History fence lacks the original worker absence observation" in
  {scope; request_id; request_digest; physical_owner=Request.owner_to_json owner;
   source_sha256; original_record; expected; actor; reason; fenced_at}
let create ~request ~(original:Owner.retained) ~expected ~actor ~reason ~now =
  let* request_digest = Owner.request_digest (Request.to_json request) in
  let* () = require (Request.request_id request=original.request_id
    && request_digest=original.request_digest) "History fence request differs from its original" in
  let* source_sha256 = digest (Source.to_json (Request.source request)) in
  of_json (to_json {scope=original.scope;request_id=original.request_id;
    request_digest=original.request_digest;
    physical_owner=Request.owner_to_json (Request.physical_owner request);
    source_sha256;original_record=Owner.to_json original;expected;actor;reason;fenced_at=now})
let read ~store ~scope ~request_id =
  let* stored = Store.load_history_fence store ~scope ~request_id in
  match stored with
  | None -> Ok None
  | Some json ->
    let* fence = of_json json in
    let+ () = require (fence.scope = scope && fence.request_id = request_id)
      "History fence is stored under another original" in
    Some fence
let confirm_binding ~request ~(original:Owner.retained) fence =
  let* source_sha256 = digest (Source.to_json (Request.source request)) in
  require (fence.scope=original.scope && fence.request_id=original.request_id
    && fence.request_digest = original.request_digest
    && fence.source_sha256 = source_sha256
    && fence.physical_owner = Request.owner_to_json (Request.physical_owner request))
    "History fence immutable binding differs; publication remains blocked"
(* The same binding from the record and its index, without the body. Whoever
   reads the body binds the index to it. *)
let confirm_binding_index ~(index:Request.index) ~original fence =
  let module Record=Owner.Record in
  require (fence.scope=Record.scope original && fence.request_id=Record.request_id original
    && fence.request_digest=Record.request_digest original
    && fence.source_sha256=index.source_digest
    && fence.physical_owner=Request.owner_to_json index.owner)
    "History fence immutable binding differs; publication remains blocked"
let check_unfenced ~store ~request ~(original:Owner.retained) =
  let* fence = read ~store ~scope:original.scope ~request_id:original.request_id in
  match fence with
  | None -> Ok ()
  | Some fence ->
    let* () = confirm_binding ~request ~original fence in
    Error "This original history result is durably fenced by an operator"
let publish ~store fence =
  Store.publish_history_fence store ~scope:fence.scope ~request_id:fence.request_id
    ~expected_owner:fence.original_record ~fence:(to_json fence)

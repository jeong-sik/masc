module History = Agent_core.History
module Request = Keeper_sandbox_remote.Stdio_request
module Channel = Keeper_continuation_channel

let ( let* ) = Result.bind

type error =
  | Invalid_binding of string
  | Source_unavailable of History.media_error

let error_to_string = function
  | Invalid_binding detail -> "invalid media reading original: " ^ detail
  | Source_unavailable error -> History.show_media_error error

let invalid detail = Error (Invalid_binding detail)
let checked result = Result.map_error (fun detail -> Invalid_binding detail) result
let canonical json = checked (Lane_addon_action.canonical json)
let hash json = Lane_addon_store.digest (Yojson.Safe.to_string json)
let object_ fields = `Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b) fields)
let optional encode = function None -> `Null | Some value -> encode value

let fields ~label ~keys = function
  | `Assoc values ->
    let* () = checked (Json_util.reject_unknown_fields ~surface:label ~allowed:keys values) in
    if List.length values = List.length keys then Ok values
    else invalid (label ^ " has missing fields")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    invalid (label ^ " must be an object")

let text values key = checked (Json_util.require_field_string ~surface:"media original" key values)
let nonnegative label = function
  | `Int value when value >= 0 -> Ok value
  | `Int _ | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
    invalid (label ^ " must be a nonnegative integer")

let nonblank label value =
  if String.trim value = "" then invalid (label ^ " must not be blank") else Ok ()

let no_nul label value =
  if String.contains value '\000' then invalid (label ^ " must not contain NUL") else Ok ()

let identity label value =
  let* () = nonblank label value in
  no_nul label value

let sha256 label value =
  match History.stored ~sha256:value ~bytes:0 with
  | Ok _ -> Ok ()
  | Error error -> invalid (label ^ ": " ^ History.stored_error_to_string error)

let absolute_path label value =
  let* () = identity label value in
  if Filename.is_relative value then invalid (label ^ " must be absolute")
  else
    let* normalized =
      Config_dir_resolver.canonical_base_path value
      |> Result.map_error (fun error -> Invalid_binding
           (Config_dir_resolver.canonical_base_path_error_to_string error))
    in
    if String.equal value normalized then Ok () else invalid (label ^ " is not canonical")

type workspace =
  { base_path : string
  ; root_path : string
  ; device : int
  ; inode : int
  ; uid : int
  }

type owner = { workspace : workspace; keeper_name : string }
type subject =
  { owner : owner
  ; kind : Media_reading_kind.t
  ; media_type : string
  ; stored : History.stored
  }
type verified_source = { subject : subject; uri : string }

let owner_base_path (owner : owner) = owner.workspace.base_path
let owner_keeper_name (owner : owner) = owner.keeper_name
let check_owner ~(expected : owner) (owner : owner) =
  if owner = expected then Ok ()
  else invalid "the current workspace root or Keeper differs from the captured owner"

let subject_base_path (subject : subject) = owner_base_path subject.owner
let subject_keeper_name (subject : subject) = owner_keeper_name subject.owner

let observe_owner ~base_path ~keeper_name =
  let* keeper = checked (Keeper_id.Keeper_name.of_string keeper_name) in
  let* base_path = Config_dir_resolver.canonical_base_path base_path
    |> Result.map_error (fun error -> Invalid_binding
         (Config_dir_resolver.canonical_base_path_error_to_string error)) in
  let* workspace =
    Fs_compat.Systhread_host.run ~label:"media-original-owner" (fun () ->
      Fs_compat.with_owned_inventory_root base_path (fun root ->
        let stat = Fs_compat.owned_inventory_root_stat root in
        Ok { base_path; root_path = Fs_compat.owned_inventory_root_path root;
             device = stat.Unix.st_dev; inode = stat.st_ino; uid = stat.st_uid }))
    |> Result.map_error (fun error -> Invalid_binding
         (Fs_compat.owned_regular_file_read_error_to_string error))
  in
  if workspace.uid <> Unix.geteuid () then invalid "workspace root belongs to another user"
  else Ok { workspace; keeper_name = Keeper_id.Keeper_name.to_string keeper }

let subject owner ~kind ~media_type stored =
  let* () = nonblank "media_type" media_type in
  Ok { owner; kind; media_type; stored }

let same_subject (left : subject) (right : subject) = left = right

let check_workspace (owner : owner) (subject : subject) =
  if owner.workspace = subject.owner.workspace then Ok ()
  else invalid "the original's captured workspace root differs from the current owner"

let kind_to_string = function Media_reading_kind.Audio -> "audio" | Document -> "document"
let kind_of_string = function
  | "audio" -> Ok Media_reading_kind.Audio
  | "document" -> Ok Media_reading_kind.Document
  | value -> invalid ("unknown media kind " ^ value)

let workspace_to_json (workspace : workspace) =
  object_ ["base_path", `String workspace.base_path; "root_path", `String workspace.root_path;
           "device", `Int workspace.device; "inode", `Int workspace.inode; "uid", `Int workspace.uid]

let workspace_of_json json =
  let* values = fields ~label:"workspace" ~keys:["base_path"; "root_path"; "device"; "inode"; "uid"] json in
  let* base_path = text values "base_path" in
  let* root_path = text values "root_path" in
  let* () = absolute_path "base_path" base_path in
  let* () = absolute_path "root_path" root_path in
  let* device = nonnegative "device" (List.assoc "device" values) in
  let* inode = nonnegative "inode" (List.assoc "inode" values) in
  let* uid = nonnegative "uid" (List.assoc "uid" values) in
  Ok { base_path; root_path; device; inode; uid }

let subject_to_json (subject : subject) =
  object_ ["workspace", workspace_to_json subject.owner.workspace;
           "keeper_name", `String subject.owner.keeper_name;
           "kind", `String (kind_to_string subject.kind);
           "source", History.stored_source_to_json ~media_type:subject.media_type subject.stored]

let subject_of_json json =
  let* values = fields ~label:"subject" ~keys:["workspace"; "keeper_name"; "kind"; "source"] json in
  let* workspace = workspace_of_json (List.assoc "workspace" values) in
  let* keeper_name = text values "keeper_name" in
  let* keeper = checked (Keeper_id.Keeper_name.of_string keeper_name) in
  let* kind_text = text values "kind" in
  let* kind = kind_of_string kind_text in
  match History.stored_source_of_json (List.assoc "source" values) with
  | History.Not_stored_source -> invalid "subject source must be a Stored reference"
  | History.Invalid_stored_source error -> invalid (History.decode_error_to_string error)
  | History.Decoded_stored_source { media_type; stored } ->
    subject { workspace; keeper_name = Keeper_id.Keeper_name.to_string keeper } ~kind ~media_type stored

let data_prefix media_type =
  let* () = nonblank "data URI media_type" media_type in
  if String.exists (function '\000' | '\r' | '\n' | ',' -> true | _ -> false) media_type
  then invalid "media_type contains a data URI delimiter or control character"
  else Ok ("data:" ^ media_type ^ ";base64,")

let source_from_raw subject raw =
  let actual = History.stored_of_raw raw in
  if actual <> subject.stored then
    Error (Source_unavailable (History.Digest_mismatch { expected = subject.stored; actual }))
  else
    let* prefix = data_prefix subject.media_type in
    Ok { subject; uri = prefix ^ Base64.encode_string raw }

let verify_source ~media_store subject =
  let* raw = media_store.History.get subject.stored |> Result.map_error (fun error -> Source_unavailable error) in
  source_from_raw subject raw

let source_of_arguments subject json =
  let* values = fields ~label:"adapter arguments" ~keys:["uri"] json in
  let* uri = text values "uri" in
  let* prefix = data_prefix subject.media_type in
  if not (String.starts_with ~prefix uri) then invalid "input URI does not name the exact source MIME"
  else
    let encoded = String.sub uri (String.length prefix) (String.length uri - String.length prefix) in
    let* raw = Base64.decode ~pad:true encoded
      |> Result.map_error (fun (`Msg detail) -> Invalid_binding ("invalid source base64: " ^ detail)) in
    let* source = source_from_raw subject raw in
    if String.equal source.uri uri then Ok source else invalid "source URI is not canonical padded base64"

let adapter_to_string = function Runtime_schema.Markitdown_mcp -> "markitdown_mcp"

let declaration_to_json (declaration : Runtime_schema.media_reader_decl) =
  object_ ["id", `String declaration.id; "revision", `String declaration.revision;
           "kind", `String (kind_to_string declaration.kind);
           "media_types", `List (List.map (fun value -> `String value) declaration.media_types);
           "adapter", `String (adapter_to_string declaration.adapter);
           "command", `String declaration.command;
           "args", `List (List.map (fun value -> `String value) declaration.args)]

let declaration_digest declaration = hash (declaration_to_json declaration)

let string_list label validate = function
  | `List values ->
    let rec loop reversed = function
      | [] -> Ok (List.rev reversed)
      | `String value :: rest -> let* () = validate value in loop (value :: reversed) rest
      | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) :: _ ->
        invalid (label ^ " must contain only strings")
    in loop [] values
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
    invalid (label ^ " must be a list")

let declaration_of_json json =
  let* values = fields ~label:"declaration"
    ~keys:["id"; "revision"; "kind"; "media_types"; "adapter"; "command"; "args"] json in
  let* id = text values "id" in
  let* revision = text values "revision" in
  let* kind_text = text values "kind" in
  let* kind = kind_of_string kind_text in
  let* media_types = string_list "media_types" (nonblank "media type") (List.assoc "media_types" values) in
  let* adapter_text = text values "adapter" in
  let* adapter = match adapter_text with
    | "markitdown_mcp" -> Ok Runtime_schema.Markitdown_mcp
    | value -> invalid ("unknown media adapter " ^ value) in
  let* command = text values "command" in
  let* () = no_nul "command" command in
  let* args = string_list "args" (no_nul "argument") (List.assoc "args" values) in
  Ok { Runtime_schema.id; revision; kind; media_types; adapter; command; args }

let decode_canonical ~encode decode json =
  let* json = canonical json in
  let* value = checked (decode json) in
  let* encoded = canonical (encode value) in
  if Yojson.Safe.equal encoded json then Ok value else invalid "nested value is not its canonical representation"

let causal_to_json = function
  | None -> `Null
  | Some (context : Keeper_gate.causal_context) ->
    object_ ["turn_id", optional (fun value -> `Int value) context.turn_id;
             "origin", Keeper_approval_origin.to_yojson context.origin; "snapshot", context.snapshot]

let causal_of_json = function
  | `Null -> Ok None
  | `Assoc _ as json ->
    let* values = fields ~label:"causal_context" ~keys:["turn_id"; "origin"; "snapshot"] json in
    let* turn_id = match List.assoc "turn_id" values with
      | `Null -> Ok None
      | (`Int _ | `Intlit _ | `Float _ | `Bool _ | `String _ | `List _ | `Assoc _) as value ->
        nonnegative "turn_id" value |> Result.map Option.some in
    let* origin = decode_canonical ~encode:Keeper_approval_origin.to_yojson
      Keeper_approval_origin.of_yojson (List.assoc "origin" values) in
    let* snapshot = canonical (List.assoc "snapshot" values) in
    Ok (Some { Keeper_gate.turn_id; origin; snapshot })
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    invalid "causal_context must be null or an object"

let origin_of_context = function
  | None -> Keeper_approval_origin.unavailable
  | Some (context : Keeper_gate.causal_context) -> context.origin

type t =
  { source : verified_source
  ; declaration : Runtime_schema.media_reader_decl
  ; launch : Request.binding
  ; causal_context : Keeper_gate.causal_context option
  ; task_id : string option
  ; continuation_channel : Channel.t
  ; execution_id : string
  ; request_id : string
  ; json : Yojson.Safe.t
  ; digest : string
  }

let schema = "keeper.media-reading-original.v1"
let request_prefix = "media-reading-"
let summary_schema = "keeper.media-reading-original-summary.v1"

let create ~execution_id ~source ~declaration ~launch ~causal_context ~task_id ~continuation_channel =
  let* () = identity "execution_id" execution_id in
  let* () = match task_id with None -> Ok () | Some value -> identity "task_id" value in
  let* declaration = declaration_of_json (declaration_to_json declaration) in
  let* () =
    if declaration.kind = source.subject.kind && List.mem source.subject.media_type declaration.media_types
    then Ok () else invalid "declaration does not support this exact kind and MIME" in
  let* () = Request.validate_binding launch
      ~base_path:(subject_base_path source.subject) ~keeper_name:(subject_keeper_name source.subject)
      ~expected_argv:(declaration.command :: declaration.args)
    |> Result.map_error (function
      | Request.Owner_mismatch -> Invalid_binding "prepared launch belongs to another workspace or Keeper"
      | Request.Payload_argv_mismatch -> Invalid_binding "prepared launch argv differs from the complete declaration") in
  let* causal_context = causal_of_json (causal_to_json causal_context) in
  let* continuation_channel = decode_canonical ~encode:Channel.to_yojson Channel.of_yojson
    (Channel.to_yojson continuation_channel) in
  let* capture = canonical (object_
    ["schema", `String schema; "subject", subject_to_json source.subject;
     "declaration", declaration_to_json declaration;
     "declaration_digest", `String (declaration_digest declaration);
     "launch", Request.binding_to_json launch; "execution_id", `String execution_id;
     "arguments", object_ ["uri", `String source.uri];
     "origin", Keeper_approval_origin.to_yojson (origin_of_context causal_context);
     "causal_context", causal_to_json causal_context;
     "task_id", optional (fun value -> `String value) task_id;
     "continuation_channel", Channel.to_yojson continuation_channel]) in
  let request_id = request_prefix ^ hash capture in
  let json = object_ ["request_id", `String request_id; "capture", capture] in
  Ok { source; declaration; launch; causal_context; task_id; continuation_channel;
       execution_id; request_id; json; digest = hash json }

let original_subject original = original.source.subject
let declaration original = original.declaration
let launch original = original.launch
let arguments original = object_ ["uri", `String original.source.uri]
let data_uri original = original.source.uri
let origin original = origin_of_context original.causal_context
let causal_context original = original.causal_context
let task_id original = original.task_id
let continuation_channel original = original.continuation_channel
let execution_id original = original.execution_id
let request_id original = original.request_id
let original_digest original = original.digest
let to_json original = original.json

let of_json json =
  let* json = canonical json in
  let* outer = fields ~label:"original" ~keys:["request_id"; "capture"] json in
  let* expected_request_id = text outer "request_id" in
  let* values = fields ~label:"capture"
    ~keys:["schema"; "subject"; "declaration"; "declaration_digest"; "launch"; "execution_id";
           "arguments"; "origin"; "causal_context"; "task_id"; "continuation_channel"]
    (List.assoc "capture" outer) in
  let* version = text values "schema" in
  let* () = if String.equal version schema then Ok () else invalid "unknown original schema" in
  let* subject = subject_of_json (List.assoc "subject" values) in
  let* source = source_of_arguments subject (List.assoc "arguments" values) in
  let* declaration = declaration_of_json (List.assoc "declaration" values) in
  let* expected_declaration = text values "declaration_digest" in
  let* () = if String.equal expected_declaration (declaration_digest declaration) then Ok ()
    else invalid "declaration digest mismatch" in
  let* launch = checked (Request.binding_of_json (List.assoc "launch" values)) in
  let* execution_id = text values "execution_id" in
  let* causal_context = causal_of_json (List.assoc "causal_context" values) in
  let* captured_origin = decode_canonical ~encode:Keeper_approval_origin.to_yojson
    Keeper_approval_origin.of_yojson (List.assoc "origin" values) in
  let* () = if captured_origin = origin_of_context causal_context then Ok ()
    else invalid "origin differs from the captured causal context" in
  let* task_id = match List.assoc "task_id" values with
    | `Null -> Ok None
    | `String value -> let* () = identity "task_id" value in Ok (Some value)
    | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ ->
      invalid "task_id must be null or text" in
  let* continuation_channel = decode_canonical ~encode:Channel.to_yojson Channel.of_yojson
    (List.assoc "continuation_channel" values) in
  let* original = create ~execution_id ~source ~declaration ~launch ~causal_context ~task_id ~continuation_channel in
  if String.equal original.request_id expected_request_id && Yojson.Safe.equal original.json json
  then Ok original else invalid "original request identity or canonical capture mismatch"

let summary original =
  object_ ["schema", `String summary_schema; "subject", subject_to_json original.source.subject;
           "request_id", `String original.request_id; "execution_id", `String original.execution_id;
           "original_digest", `String original.digest;
           "declaration_digest", `String (declaration_digest original.declaration)]

let summary_subject ~request_id:expected_request_id ~request_digest json =
  let* json = canonical json in
  let* values = fields ~label:"original summary"
    ~keys:["schema"; "subject"; "request_id"; "execution_id"; "original_digest"; "declaration_digest"] json in
  let* version = text values "schema" in
  let* () = if String.equal version summary_schema then Ok () else invalid "unknown summary schema" in
  let* request_id = text values "request_id" in
  let* () = if String.starts_with ~prefix:request_prefix request_id then
      sha256 "request_id" (String.sub request_id (String.length request_prefix)
        (String.length request_id - String.length request_prefix))
    else invalid "unknown media request ID form" in
  let* execution_id = text values "execution_id" in
  let* () = identity "execution_id" execution_id in
  let* original_digest = text values "original_digest" in
  let* () = sha256 "original_digest" original_digest in
  let* declaration_digest = text values "declaration_digest" in
  let* () = sha256 "declaration_digest" declaration_digest in
  if not (String.equal request_id expected_request_id && String.equal original_digest request_digest)
  then invalid "summary request identity or body digest differs from the discovered record"
  else subject_of_json (List.assoc "subject" values)

let restore (retained : Lane_addon_tool_request_owner.retained) =
  let* original = of_json retained.request in
  let* retained_summary = canonical retained.summary in
  let* expected_summary = canonical (summary original) in
  if String.equal retained.request_id original.request_id
     && String.equal retained.request_digest original.digest
     && Yojson.Safe.equal retained_summary expected_summary
  then Ok original else invalid "retained record differs from its original identity, digest or summary"

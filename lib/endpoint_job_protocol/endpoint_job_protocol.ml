let capability = "endpoint_jobs_v1"

module Id = struct
  type t = string
  let hex = function '0' .. '9' | 'a' .. 'f' -> true | _ -> false
  let of_string value =
    let rec valid i =
      i=36 || ((if i=8 || i=13 || i=18 || i=23 then value.[i]='-' else hex value.[i]) && valid (i+1)) in
    if String.length value=36 && valid 0 then Ok value
    else Error "expected a canonical lowercase UUID"
  let to_string value = value
end

module Sha256 = struct
  type t = string
  let of_string value =
    if String.length value=64 && String.for_all Id.hex value then Ok value
    else Error "expected a lowercase SHA256 digest"
  let to_string value = value
end

type backend = Apple_container | Microsandbox | Nerdctl_kata | Remote_ssh

type route = { backend : backend; endpoint_incarnation : Id.t; boot_id : Id.t }
type owner = { workspace_id : Id.t; keeper_name : string }
type isolated_preparation =
  { preparation_id : Id.t
  ; image_sha256 : Sha256.t
  ; input_manifest_sha256 : Sha256.t
  }

type domain = Workspace_process | Isolated_job of isolated_preparation

type spec =
  { domain : domain; argv : string list; env : (string * string) list
  ; cwd : string; remote_root : string; stdin : string
  ; mode : Exec_ssh_protocol.mode; network_policy_sha256 : Sha256.t option }

let no_nul value = not (String.contains value '\000')
let absolute value = String.length value>0 && value.[0]='/' && no_nul value
let name_head = function 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false
let name_tail = function '0' .. '9' -> true | c -> name_head c
let env_name value = String.length value>0 && name_head value.[0] && String.for_all name_tail value

module Names = Set.Make (String)

let spec ~domain ~argv ~env ~cwd ~remote_root ~stdin ~mode ~network_policy_sha256 =
  let rec unique_names seen = function
    | [] -> true
    | (name,value)::rest ->
      env_name name && no_nul value && not (Names.mem name seen)
      && unique_names (Names.add name seen) rest in
  match argv with
  | [] -> Error "argv requires a program"
  | program::_ when program="" -> Error "argv requires a nonempty program"
  | _::_ ->
    if not (List.for_all no_nul argv) then Error "argv contains NUL"
    else if not (unique_names Names.empty env) then Error "environment names/values are invalid or duplicated"
    else if not (absolute cwd && absolute remote_root) then Error "cwd and remote_root must be absolute non-NUL paths"
    else Ok {domain;argv;env;cwd;remote_root;stdin;mode;network_policy_sha256}

let backend_tag = function
  | Apple_container -> "apple_container" | Microsandbox -> "microsandbox"
  | Nerdctl_kata -> "nerdctl_kata" | Remote_ssh -> "remote_ssh"
let domain_json = function
  | Workspace_process -> `Assoc ["kind",`String "workspace_process"]
  | Isolated_job p -> `Assoc ["kind",`String "isolated_job";
      "preparation_id",`String (Id.to_string p.preparation_id);
      "image_sha256",`String (Sha256.to_string p.image_sha256);
      "input_manifest_sha256",`String (Sha256.to_string p.input_manifest_sha256)]
type stream = Stdout | Stderr
let stream_tag = function Stdout -> "stdout" | Stderr -> "stderr"

let b64 value = `String (Base64.encode_string value)
let digest_json = function None -> `Null | Some digest -> `String (Sha256.to_string digest)
let spec_json s = `Assoc
  [ "domain",domain_json s.domain
  ; "argv",`List (List.map b64 s.argv)
  ; "env",`List (List.map (fun (name,value) -> `List [b64 name;b64 value]) s.env)
  ; "cwd",b64 s.cwd; "remote_root",b64 s.remote_root; "stdin",b64 s.stdin
  ; "mode",`String (Exec_ssh_protocol.mode_to_string s.mode)
  ; "network_policy_sha256",digest_json s.network_policy_sha256 ]

let hash value = Agent_core_sha256.(digest_string value |> to_hex)
let spec_sha256 s = hash ("masc-endpoint-job-spec-v1\000" ^ Yojson.Safe.to_string (spec_json s))

type binding =
  { route : route; owner : owner; operation_id : Id.t
  ; invocation_sha256 : Sha256.t; spec_sha256 : Sha256.t }

let binding ~route ~owner ~operation_id ~invocation_sha256 ~spec_sha256 =
  if owner.keeper_name="" || not (no_nul owner.keeper_name) then
    Error "keeper_name must be nonempty and contain no NUL"
  else Ok {route;owner;operation_id;invocation_sha256;spec_sha256}

type original = { binding : binding; admission_id : Id.t }
let original ~binding ~admission_id = {binding;admission_id}

type request =
  | Start of { binding : binding; spec : spec }
  | Reconcile_admission of binding
  | Activate of original
  | Inspect of original
  | Read_output of { original : original; stream : stream; offset : int64; max_bytes : int }
  | Cancel of original
  | Release of { original : original; result_sha256 : Sha256.t }

type exit_status = Exited of int | Signaled of int
type non_start = Cancelled_before_activation | Launch_rejected
type phase = Queued | Starting | Running | Finished of exit_status | Not_started of non_start
  | Termination_observed of exit_status
type extent = Growing of int64 | Sealed of { byte_length : int64; sha256 : Sha256.t }
type refusal =
  | Unsupported | Unauthenticated | Owner_mismatch | Request_conflict
  | Endpoint_replaced | Admission_refused | Release_refused
type hold = Registry_unavailable | Supervisor_unavailable | Operation_not_found | Output_unavailable of stream

type result_availability = Result_pending | Result_ready of Sha256.t

type response =
  | Admitted of { original : original; revision : int64 }
  | Status of { original : original; revision : int64; phase : phase; cancel_requested : bool; result : result_availability; stdout : extent; stderr : extent }
  | Output of { original : original; revision : int64; stream : stream; offset : int64; data : string; extent : extent }
  | Released of { original : original; revision : int64; result_sha256 : Sha256.t }
  | Refused of { binding : binding; reason : refusal }
  | Held of { binding : binding; reason : hold }

type codec_error =
  | Missing_field of string | Duplicate_field of string | Unexpected_field of string
  | Invalid_field of string | Version_unsupported | Tag_unsupported of string
  | Spec_digest_mismatch | Binding_mismatch | Original_admission_mismatch | Response_kind_mismatch | Output_range_mismatch
  | Output_digest_mismatch
  | Response_revision_stale

let error_to_string = function
  | Missing_field field -> "endpoint job protocol: missing field " ^ field
  | Duplicate_field field -> "endpoint job protocol: duplicate field " ^ field
  | Unexpected_field field -> "endpoint job protocol: unexpected field " ^ field
  | Invalid_field field -> "endpoint job protocol: invalid field " ^ field
  | Version_unsupported -> "endpoint job protocol: unsupported version"
  | Tag_unsupported field -> "endpoint job protocol: unsupported tag in " ^ field
  | Spec_digest_mismatch -> "endpoint job protocol: launch specification digest mismatch"
  | Original_admission_mismatch -> "endpoint job protocol: original admission mismatch"
  | Binding_mismatch -> "endpoint job protocol: response operation/route/owner binding mismatch"
  | Response_kind_mismatch -> "endpoint job protocol: response kind does not match request"
  | Output_range_mismatch -> "endpoint job protocol: output does not match requested range"
  | Output_digest_mismatch -> "endpoint job protocol: complete output does not match sealed digest"
  | Response_revision_stale -> "endpoint job protocol: response predates accepted state"

open Result.Syntax
let invalid field = Error (Invalid_field field)

(* Field names in diagnostics come from this schema, not attacker-controlled
   unknown keys: a malformed object may itself contain credential bytes. *)
let object_fields field ~required value =
  match value with
  | `Assoc fields ->
    let rec names seen = function
      | [] -> Ok ()
      | (key,_)::rest ->
        if not (List.mem key required) then Error (Unexpected_field field)
        else if List.mem key seen then Error (Duplicate_field (field ^ "." ^ key))
        else names (key::seen) rest in
    let* () = names [] fields in
    let rec present = function
      | [] -> Ok fields
      | key::rest ->
        if List.mem_assoc key fields then present rest
        else Error (Missing_field (field ^ "." ^ key)) in
    present required
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> invalid field

let get fields key = List.assoc key fields
let text field = function
  | `String value -> Ok value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> invalid field
let boolean field = function
  | `Bool value -> Ok value
  | `Null | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ -> invalid field
let bytes field value =
  let* encoded = text field value in
  match Base64.decode encoded with
  | Ok value when Base64.encode_string value=encoded -> Ok value
  | Ok _ | Error _ -> invalid field
let identifier field value =
  let* value = text field value in
  Id.of_string value |> Result.map_error (fun _ -> Invalid_field field)
let digest field value =
  let* value = text field value in
  Sha256.of_string value |> Result.map_error (fun _ -> Invalid_field field)
let digest_option field = function `Null -> Ok None | value -> Result.map Option.some (digest field value)
let nonnegative field value =
  let* value = text field value in
  match Int64.of_string_opt value with
  | Some n when n>=0L && Int64.to_string n=value -> Ok n
  | None | Some _ -> invalid field
let positive_int field value =
  let* n = nonnegative field value in
  if n>0L && n<=Int64.of_int max_int then Ok (Int64.to_int n) else invalid field
let list field read = function
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | value::rest -> let* value = read value in loop (value::acc) rest in
    loop [] values
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> invalid field

let read_backend value =
  let* value = text "binding.route.backend" value in
  match value with
  | "apple_container" -> Ok Apple_container | "microsandbox" -> Ok Microsandbox
  | "nerdctl_kata" -> Ok Nerdctl_kata | "remote_ssh" -> Ok Remote_ssh
  | _ -> Error (Tag_unsupported "binding.route.backend")
let read_stream value =
  let* value = text "stream" value in
  match value with "stdout" -> Ok Stdout | "stderr" -> Ok Stderr | _ -> Error (Tag_unsupported "stream")

let binding_json b = `Assoc
  [ "route",`Assoc ["backend",`String (backend_tag b.route.backend);
      "endpoint_incarnation",`String (Id.to_string b.route.endpoint_incarnation);
      "boot_id",`String (Id.to_string b.route.boot_id)]
  ; "owner",`Assoc ["workspace_id",`String (Id.to_string b.owner.workspace_id);"keeper_name",b64 b.owner.keeper_name]
  ; "operation_id",`String (Id.to_string b.operation_id)
  ; "invocation_sha256",`String (Sha256.to_string b.invocation_sha256)
  ; "spec_sha256",`String (Sha256.to_string b.spec_sha256) ]

let read_binding value =
  let* f = object_fields "binding" ~required:["route";"owner";"operation_id";"invocation_sha256";"spec_sha256"] value in
  let* r = object_fields "binding.route" ~required:["backend";"endpoint_incarnation";"boot_id"] (get f "route") in
  let* backend = read_backend (get r "backend") in
  let* endpoint_incarnation = identifier "binding.route.endpoint_incarnation" (get r "endpoint_incarnation") in
  let* boot_id = identifier "binding.route.boot_id" (get r "boot_id") in
  let* o = object_fields "binding.owner" ~required:["workspace_id";"keeper_name"] (get f "owner") in
  let* workspace_id = identifier "binding.owner.workspace_id" (get o "workspace_id") in
  let* keeper_name = bytes "binding.owner.keeper_name" (get o "keeper_name") in
  let* operation_id = identifier "binding.operation_id" (get f "operation_id") in
  let* invocation_sha256 = digest "binding.invocation_sha256" (get f "invocation_sha256") in
  let* spec_sha256 = digest "binding.spec_sha256" (get f "spec_sha256") in
  binding ~route:{backend;endpoint_incarnation;boot_id} ~owner:{workspace_id;keeper_name}
    ~operation_id ~invocation_sha256 ~spec_sha256 |> Result.map_error (fun _ -> Invalid_field "binding.owner.keeper_name")

let read_domain value =
  let* kind = match value with
    | `Assoc f -> (match List.assoc_opt "kind" f with
        | None -> Error (Missing_field "spec.domain.kind")
        | Some value -> text "spec.domain.kind" value)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> invalid "spec.domain" in
  match kind with
  | "workspace_process" ->
    let* _ = object_fields "spec.domain" ~required:["kind"] value in Ok Workspace_process
  | "isolated_job" ->
    let* f = object_fields "spec.domain" ~required:["kind";"preparation_id";"image_sha256";"input_manifest_sha256"] value in
    let* preparation_id = identifier "spec.domain.preparation_id" (get f "preparation_id") in
    let* image_sha256 = digest "spec.domain.image_sha256" (get f "image_sha256") in
    let* input_manifest_sha256 = digest "spec.domain.input_manifest_sha256" (get f "input_manifest_sha256") in
    Ok (Isolated_job {preparation_id;image_sha256;input_manifest_sha256})
  | _ -> Error (Tag_unsupported "spec.domain.kind")

let read_spec value =
  let* f = object_fields "spec" ~required:["domain";"argv";"env";"cwd";"remote_root";"stdin";"mode";"network_policy_sha256"] value in
  let* domain = read_domain (get f "domain") in
  let* argv = list "spec.argv" (bytes "spec.argv") (get f "argv") in
  let env_pair = function
    | `List [name;value] -> let* name = bytes "spec.env.name" name in
      let* value = bytes "spec.env.value" value in Ok (name,value)
    | `List _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> invalid "spec.env" in
  let* env = list "spec.env" env_pair (get f "env") in
  let* cwd = bytes "spec.cwd" (get f "cwd") in
  let* remote_root = bytes "spec.remote_root" (get f "remote_root") in
  let* stdin = bytes "spec.stdin" (get f "stdin") in
  let* mode = text "spec.mode" (get f "mode") in
  let* mode = match Exec_ssh_protocol.mode_of_string mode with
    | Some mode -> Ok mode | None -> Error (Tag_unsupported "spec.mode") in
  let* network_policy_sha256 = digest_option "spec.network_policy_sha256" (get f "network_policy_sha256") in
  spec ~domain ~argv ~env ~cwd ~remote_root ~stdin ~mode ~network_policy_sha256
  |> Result.map_error (fun _ -> Invalid_field "spec")

let envelope tag binding fields = `Assoc
  (["protocol",`String "masc_endpoint_jobs";"version",`Int 1;"operation",`String tag;"binding",binding_json binding] @ fields)
let read_envelope value =
  (* Select the closed operation only after refusing duplicate envelope keys.
     Per-operation field validation below refuses irrelevant optional fields. *)
  let* f = object_fields "envelope"
    ~required:["protocol";"version";"operation";"binding"]
    (match value with
     | `Assoc fields -> `Assoc (List.filter (fun (k,_) ->
         List.mem k ["protocol";"version";"operation";"binding"]) fields)
     | value -> value) in
  let* protocol = text "protocol" (get f "protocol") in
  let* () = if protocol="masc_endpoint_jobs" then Ok () else Error (Tag_unsupported "protocol") in
  let* () = match get f "version" with `Int 1 -> Ok ()
    | `Int _ | `Intlit _ -> Error Version_unsupported
    | `Null | `Bool _ | `Float _ | `String _ | `Assoc _ | `List _ -> invalid "version" in
  let* tag = text "operation" (get f "operation") in
  let* binding = read_binding (get f "binding") in
  Ok (tag,binding)

let operation_fields value extra = object_fields "envelope"
  ~required:(["protocol";"version";"operation";"binding"] @ extra) value
let count n = `String (Int64.to_string n)

let original_envelope tag original extra =
  envelope tag original.binding
    (("admission_id",`String (Id.to_string original.admission_id)) :: extra)
let read_original binding fields =
  let* admission_id = identifier "admission_id" (get fields "admission_id") in
  Ok {binding;admission_id}

let validate_request = function
  | Start {binding;spec} -> if binding.spec_sha256=spec_sha256 spec then Ok () else Error Spec_digest_mismatch
  | Read_output {offset;max_bytes;_} -> if offset>=0L && max_bytes>0 then Ok () else Error Output_range_mismatch
  | Reconcile_admission _ | Activate _ | Inspect _ | Cancel _ | Release _ -> Ok ()

let request_to_json request =
  let* () = validate_request request in
  Ok (match request with
    | Start {binding;spec} -> envelope "start" binding ["spec",spec_json spec]
    | Reconcile_admission binding -> envelope "reconcile_admission" binding []
    | Activate original -> original_envelope "activate" original []
    | Inspect original -> original_envelope "inspect" original []
    | Read_output {original;stream;offset;max_bytes} -> original_envelope "read_output" original
        ["stream",`String (stream_tag stream);"offset",count offset;"max_bytes",count (Int64.of_int max_bytes)]
    | Cancel original -> original_envelope "cancel" original []
    | Release {original;result_sha256} -> original_envelope "release" original ["result_sha256",`String (Sha256.to_string result_sha256)])

let request_of_json value =
  let* tag,binding = read_envelope value in
  let* request = match tag with
    | "start" -> let* f = operation_fields value ["spec"] in
      let* spec = read_spec (get f "spec") in Ok (Start {binding;spec})
    | "reconcile_admission" -> let* _ = operation_fields value [] in Ok (Reconcile_admission binding)
    | "activate" -> let* f = operation_fields value ["admission_id"] in
      let* original = read_original binding f in Ok (Activate original)
    | "inspect" -> let* f = operation_fields value ["admission_id"] in
      let* original = read_original binding f in Ok (Inspect original)
    | "cancel" -> let* f = operation_fields value ["admission_id"] in
      let* original = read_original binding f in Ok (Cancel original)
    | "read_output" -> let* f = operation_fields value ["admission_id";"stream";"offset";"max_bytes"] in
      let* original = read_original binding f in
      let* stream = read_stream (get f "stream") in
      let* offset = nonnegative "offset" (get f "offset") in
      let* max_bytes = positive_int "max_bytes" (get f "max_bytes") in Ok (Read_output {original;stream;offset;max_bytes})
    | "release" -> let* f = operation_fields value ["admission_id";"result_sha256"] in
      let* original = read_original binding f in
      let* result_sha256 = digest "result_sha256" (get f "result_sha256") in Ok (Release {original;result_sha256})
    | _ -> Error (Tag_unsupported "operation") in
  let* () = validate_request request in Ok request

let extent_bytes = function Growing n -> n | Sealed {byte_length;_} -> byte_length
let extent_json = function
  | Growing byte_length -> `Assoc ["state",`String "growing";"byte_length",count byte_length]
  | Sealed {byte_length;sha256} -> `Assoc
      ["state",`String "sealed";"byte_length",count byte_length;"sha256",`String (Sha256.to_string sha256)]
let read_extent value =
  (* The state selector is read from a full object with only its two possible
     shapes. State-specific validation still requires every exact field. *)
  let* state = match value with
    | `Assoc fields ->
      (match List.assoc_opt "state" fields with
       | Some state -> text "extent.state" state
       | None -> Error (Missing_field "extent.state"))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> invalid "extent" in
  match state with
  | "growing" ->
    let* f = object_fields "extent" ~required:["state";"byte_length"] value in
    let* n = nonnegative "extent.byte_length" (get f "byte_length") in Ok (Growing n)
  | "sealed" ->
    let* f = object_fields "extent" ~required:["state";"byte_length";"sha256"] value in
    let* byte_length = nonnegative "extent.byte_length" (get f "byte_length") in
    let* sha256 = digest "extent.sha256" (get f "sha256") in Ok (Sealed {byte_length;sha256})
  | _ -> Error (Tag_unsupported "extent.state")

let non_start_tag = function
  | Cancelled_before_activation -> "cancelled_before_activation"
  | Launch_rejected -> "launch_rejected"

let read_non_start = function
  | "cancelled_before_activation" -> Ok Cancelled_before_activation
  | "launch_rejected" -> Ok Launch_rejected
  | _ -> Error (Tag_unsupported "phase.reason")

let phase_json = function
  | Queued -> `Assoc ["state",`String "queued"]
  | Starting -> `Assoc ["state",`String "starting"]
  | Running -> `Assoc ["state",`String "running"]
  | Not_started reason -> `Assoc ["state",`String "not_started";"reason",`String (non_start_tag reason)]
  | Finished (Exited code) -> `Assoc ["state",`String "exited";"code",count (Int64.of_int code)]
  | Finished (Signaled signal) -> `Assoc ["state",`String "signaled";"signal",count (Int64.of_int signal)]
  | Termination_observed status -> `Assoc ["state",`String "termination_observed";
      "physical_status",(match status with
        | Exited code -> `Assoc ["kind",`String "exited";"code",count (Int64.of_int code)]
        | Signaled signal -> `Assoc ["kind",`String "signaled";"signal",count (Int64.of_int signal)])]
let read_phase value =
  let* state = match value with
    | `Assoc fields ->
      (match List.assoc_opt "state" fields with
       | Some state -> text "phase.state" state
       | None -> Error (Missing_field "phase.state"))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> invalid "phase" in
  match state with
  | "queued" -> let* _ = object_fields "phase" ~required:["state"] value in Ok Queued
  | "starting" -> let* _ = object_fields "phase" ~required:["state"] value in Ok Starting
  | "running" -> let* _ = object_fields "phase" ~required:["state"] value in Ok Running
  | "not_started" ->
    let* f = object_fields "phase" ~required:["state";"reason"] value in
    let* reason = text "phase.reason" (get f "reason") in
    let* reason = read_non_start reason in Ok (Not_started reason)
  | "exited" ->
    let* f = object_fields "phase" ~required:["state";"code"] value in
    let* code = nonnegative "phase.code" (get f "code") in
    if code<=Int64.of_int max_int then Ok (Finished (Exited (Int64.to_int code))) else invalid "phase.code"
  | "signaled" ->
    let* f = object_fields "phase" ~required:["state";"signal"] value in
    let* signal = positive_int "phase.signal" (get f "signal") in Ok (Finished (Signaled signal))
  | "termination_observed" ->
    let* f=object_fields "phase" ~required:["state";"physical_status"] value in
    let status=get f "physical_status" in
    let* kind=match status with
      | `Assoc fields -> (match List.assoc_opt "kind" fields with
          | Some value -> text "phase.physical_status.kind" value
          | None -> Error (Missing_field "phase.physical_status.kind"))
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> invalid "phase.physical_status" in
    let* status=match kind with
      | "exited" ->
        let* fields=object_fields "phase.physical_status" ~required:["kind";"code"] status in
        let* code=nonnegative "phase.physical_status.code" (get fields "code") in
        if code<=Int64.of_int max_int then Ok (Exited (Int64.to_int code)) else invalid "phase.physical_status.code"
      | "signaled" ->
        let* fields=object_fields "phase.physical_status" ~required:["kind";"signal"] status in
        let* signal=positive_int "phase.physical_status.signal" (get fields "signal") in Ok (Signaled signal)
      | _ -> Error (Tag_unsupported "phase.physical_status.kind") in
    Ok (Termination_observed status)
  | _ -> Error (Tag_unsupported "phase.state")

let refusal_tag = function
  | Unsupported -> "unsupported" | Unauthenticated -> "unauthenticated"
  | Owner_mismatch -> "owner_mismatch" | Request_conflict -> "request_conflict"
  | Endpoint_replaced -> "endpoint_replaced" | Admission_refused -> "admission_refused"
  | Release_refused -> "release_refused"
let read_refusal value =
  let* value = text "refusal" value in
  match value with
  | "unsupported" -> Ok Unsupported | "unauthenticated" -> Ok Unauthenticated
  | "owner_mismatch" -> Ok Owner_mismatch | "request_conflict" -> Ok Request_conflict
  | "endpoint_replaced" -> Ok Endpoint_replaced | "admission_refused" -> Ok Admission_refused
  | "release_refused" -> Ok Release_refused | _ -> Error (Tag_unsupported "refusal")
let hold_json = function
  | Registry_unavailable -> `Assoc ["state",`String "registry_unavailable"]
  | Supervisor_unavailable -> `Assoc ["state",`String "supervisor_unavailable"]
  | Operation_not_found -> `Assoc ["state",`String "operation_not_found"]
  | Output_unavailable stream -> `Assoc ["state",`String "output_unavailable";"stream",`String (stream_tag stream)]
let read_hold value =
  let* state = match value with
    | `Assoc fields ->
      (match List.assoc_opt "state" fields with
       | Some state -> text "hold.state" state | None -> Error (Missing_field "hold.state"))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> invalid "hold" in
  match state with
  | "registry_unavailable" -> let* _ = object_fields "hold" ~required:["state"] value in Ok Registry_unavailable
  | "supervisor_unavailable" -> let* _ = object_fields "hold" ~required:["state"] value in Ok Supervisor_unavailable
  | "operation_not_found" -> let* _ = object_fields "hold" ~required:["state"] value in Ok Operation_not_found
  | "output_unavailable" -> let* f = object_fields "hold" ~required:["state";"stream"] value in
    let* stream = read_stream (get f "stream") in Ok (Output_unavailable stream)
  | _ -> Error (Tag_unsupported "hold.state")

let result_json = function
  | Result_pending -> `Assoc ["state",`String "pending"]
  | Result_ready sha256 -> `Assoc ["state",`String "ready";"sha256",`String (Sha256.to_string sha256)]
let read_result value =
  let* state = match value with
    | `Assoc f -> (match List.assoc_opt "state" f with
        | None -> Error (Missing_field "result.state") | Some state -> text "result.state" state)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> invalid "result" in
  match state with
  | "pending" -> let* _ = object_fields "result" ~required:["state"] value in Ok Result_pending
  | "ready" -> let* f = object_fields "result" ~required:["state";"sha256"] value in
    let* sha256 = digest "result.sha256" (get f "sha256") in Ok (Result_ready sha256)
  | _ -> Error (Tag_unsupported "result.state")

let validate_empty_extent = function
  | Growing bytes -> if bytes=0L then Ok () else invalid "status.not_started_output"
  | Sealed {byte_length;sha256} ->
    if byte_length=0L && sha256=hash "" then Ok () else invalid "status.not_started_output"

let validate_response = function
  | Admitted {revision;_} -> if revision>0L then Ok () else invalid "revision"
  | Status {revision;phase;cancel_requested;result;stdout;stderr;_} ->
    let* () = match result with
      | Result_pending -> Ok ()
      | Result_ready _ -> (match phase with
          | Queued | Starting | Running -> invalid "status.result"
          | Finished _ | Not_started _ | Termination_observed _ -> match stdout,stderr with
            | Sealed _,Sealed _ -> Ok ()
            | Growing _,(Growing _ | Sealed _) | Sealed _,Growing _ -> invalid "status.result") in
    if revision<=0L then invalid "revision"
    else if extent_bytes stdout<0L || extent_bytes stderr<0L then invalid "status.extent"
    else (match phase with
      | Finished (Exited code) | Termination_observed (Exited code) -> if code>=0 then Ok () else invalid "phase.code"
      | Finished (Signaled signal) | Termination_observed (Signaled signal) -> if signal>0 then Ok () else invalid "phase.signal"
      | Starting | Running -> Ok ()
      | Not_started reason ->
          let* () = match reason with
            | Cancelled_before_activation -> if cancel_requested then Ok () else invalid "status.cancel_requested"
            | Launch_rejected -> Ok () in
          let* () = validate_empty_extent stdout in validate_empty_extent stderr
      | Queued -> (match stdout,stderr with
          | Growing 0L,Growing 0L -> Ok ()
          | (Growing _ | Sealed _),(Growing _ | Sealed _) -> invalid "status.queued_output"))
  | Output {revision;offset;data;extent;_} ->
    let size = extent_bytes extent and length = Int64.of_int (String.length data) in
    if revision<=0L then invalid "revision"
    else if offset<0L || size<0L || offset>size || length>Int64.sub size offset then Error Output_range_mismatch
    else (match extent with
      | Sealed {byte_length;sha256} when offset=0L && length=byte_length ->
        if hash data=sha256 then Ok () else Error Output_digest_mismatch
      | Sealed _ | Growing _ -> Ok ())
  | Released {revision;_} -> if revision<=0L then invalid "revision" else Ok ()
  | Refused _ | Held _ -> Ok ()

let response_to_json response =
  let* () = validate_response response in
  Ok (match response with
    | Admitted {original;revision} -> original_envelope "admitted" original ["revision",count revision]
    | Status {original;revision;phase;cancel_requested;result;stdout;stderr} -> original_envelope "status" original
        ["revision",count revision;"phase",phase_json phase;"cancel_requested",`Bool cancel_requested;"result",result_json result;
         "stdout",extent_json stdout;"stderr",extent_json stderr]
    | Output {original;revision;stream;offset;data;extent} -> original_envelope "output" original
        ["revision",count revision;"stream",`String (stream_tag stream);"offset",count offset;"data",b64 data;"extent",extent_json extent]
    | Released {original;revision;result_sha256} -> original_envelope "released" original ["revision",count revision;"result_sha256",`String (Sha256.to_string result_sha256)]
    | Refused {binding;reason} -> envelope "refused" binding ["reason",`String (refusal_tag reason)]
    | Held {binding;reason} -> envelope "held" binding ["reason",hold_json reason])

let response_of_json value =
  let* tag,binding = read_envelope value in
  let* response = match tag with
    | "admitted" -> let* f = operation_fields value ["admission_id";"revision"] in
      let* original = read_original binding f in
      let* revision = nonnegative "revision" (get f "revision") in Ok (Admitted {original;revision})
    | "status" -> let* f = operation_fields value ["admission_id";"revision";"phase";"cancel_requested";"result";"stdout";"stderr"] in
      let* original = read_original binding f in
      let* revision = nonnegative "revision" (get f "revision") in
      let* phase = read_phase (get f "phase") in
      let* cancel_requested = boolean "cancel_requested" (get f "cancel_requested") in
      let* result = read_result (get f "result") in
      let* stdout = read_extent (get f "stdout") in
      let* stderr = read_extent (get f "stderr") in Ok (Status {original;revision;phase;cancel_requested;result;stdout;stderr})
    | "output" -> let* f = operation_fields value ["admission_id";"revision";"stream";"offset";"data";"extent"] in
      let* original = read_original binding f in
      let* revision = nonnegative "revision" (get f "revision") in
      let* stream = read_stream (get f "stream") in
      let* offset = nonnegative "offset" (get f "offset") in
      let* data = bytes "data" (get f "data") in
      let* extent = read_extent (get f "extent") in Ok (Output {original;revision;stream;offset;data;extent})
    | "released" -> let* f = operation_fields value ["admission_id";"revision";"result_sha256"] in
      let* original = read_original binding f in
      let* revision = nonnegative "revision" (get f "revision") in
      let* result_sha256 = digest "result_sha256" (get f "result_sha256") in Ok (Released {original;revision;result_sha256})
    | "refused" -> let* f = operation_fields value ["reason"] in
      let* reason = read_refusal (get f "reason") in Ok (Refused {binding;reason})
    | "held" -> let* f = operation_fields value ["reason"] in
      let* reason = read_hold (get f "reason") in Ok (Held {binding;reason})
    | _ -> Error (Tag_unsupported "operation") in
  let* () = validate_response response in Ok response

let request_binding = function
  | Start {binding;_} | Reconcile_admission binding -> binding
  | Activate original | Inspect original | Cancel original
  | Read_output {original;_} | Release {original;_} -> original.binding
let response_binding = function
  | Admitted {original;_} | Status {original;_} | Output {original;_} | Released {original;_} -> original.binding
  | Refused {binding;_} | Held {binding;_} -> binding
let request_original = function
  | Start _ | Reconcile_admission _ -> None
  | Activate original | Inspect original | Cancel original
  | Read_output {original;_} | Release {original;_} -> Some original
let response_original = function
  | Admitted {original;_} | Status {original;_} | Output {original;_} | Released {original;_} -> Some original
  | Refused _ | Held _ -> None

let check_response ~minimum_revision ~request response =
  let* () = if minimum_revision>=0L then Ok () else invalid "minimum_revision" in
  let* () = validate_request request in
  let* () = validate_response response in
  let* () = if request_binding request=response_binding response then Ok () else Error Binding_mismatch in
  let* () = match request_original request,response_original response with
    | Some expected,Some observed ->
        if expected.admission_id=observed.admission_id then Ok () else Error Original_admission_mismatch
    | None,(None | Some _) | Some _,None -> Ok () in
  let* () = match response with
    | Admitted {revision;_} | Status {revision;_} | Output {revision;_} | Released {revision;_} ->
      if revision>=minimum_revision then Ok () else Error Response_revision_stale
    | Refused _ | Held _ -> Ok () in
  match response with
    | Refused _ | Held _ -> Ok ()
    | Admitted _ -> (match request with
        | Start _ | Reconcile_admission _ -> Ok ()
        | Activate _ | Inspect _ | Cancel _ | Read_output _ | Release _ -> Error Response_kind_mismatch)
    | Status _ -> (match request with
        | Activate _ | Inspect _ | Cancel _ -> Ok ()
        | Start _ | Reconcile_admission _ | Read_output _ | Release _ -> Error Response_kind_mismatch)
    | Output output -> (match request with
        | Read_output read ->
          if output.stream=read.stream && output.offset=read.offset && String.length output.data<=read.max_bytes then Ok ()
          else Error Output_range_mismatch
        | Start _ | Reconcile_admission _ | Activate _ | Inspect _ | Cancel _ | Release _ -> Error Response_kind_mismatch)
    | Released released -> (match request with
        | Release release -> if released.result_sha256=release.result_sha256 then Ok () else Error Binding_mismatch
        | Start _ | Reconcile_admission _ | Activate _ | Inspect _ | Read_output _ | Cancel _ -> Error Response_kind_mismatch)

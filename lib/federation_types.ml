(** Federation types and utilities — types, validation, file I/O. *)
open Types [@@warning "-33"]

(** Federation Module - Level 3 Cross-Organization Collaboration

    Implements the A2A-inspired federation protocol for:
    - Organization discovery (local and remote)
    - Secure handshake with challenge-response
    - Task delegation with trust management
    - Shared state coordination

    @see HOLONIC-ARCHITECTURE.md Level 3: 단체 (Corps / Federation)
    @see https://arxiv.org/html/2501.06322v1 (Google A2A Protocol)

    Quality Improvements (2026-01-10):
    - Thread-safe with Mutex
    - Result-based error handling for I/O
    - Input validation for all IDs
    - Path traversal prevention
*)

open Types

(** Re-export config type from Room_utils *)
type config = Room_utils.config

(* ============================================ *)
(* Federation Types (synced with main branch)   *)
(* ============================================ *)

(** Trust level for federation members *)
type trust_level =
  | Trusted
  | Verified
  | Pending
  | Untrusted
[@@deriving yojson, show, eq]

(** Member status *)
type member_status =
  | Active
  | Inactive
  | Suspended
[@@deriving yojson, show, eq]

(** Organization in the federation *)
type organization = {
  id: string;
  name: string;
  endpoint: string option;
  public_key: string option;
  trust_level: trust_level;
  joined_at: string option;
  rooms: string list;
} [@@deriving yojson, show, eq]

(** Federation member *)
type federation_member = {
  member_id: string;
  organization: organization;
  capabilities: string list;
  active: bool;
  trust_level: trust_level;
  status: member_status;
  joined_at: string;
} [@@deriving yojson, show, eq]

(** Shared state entry *)
type shared_state_entry = {
  key: string;
  value: string;
  version: int;
  updated_by: string;
  updated_at: string;
} [@@deriving yojson, show, eq]

(** Federation configuration *)
type federation_config = {
  id: string;
  name: string;
  local_org: organization;
  members: federation_member list;
  shared_state: shared_state_entry list;
  created_at: string;
  protocol_version: string;
} [@@deriving yojson, show, eq]

(** Handshake challenge for joining federation *)
type handshake_challenge = {
  challenge_id: string;
  from_org: organization;
  nonce: string;
  created_at: string;
  expires_at: string;
} [@@deriving yojson, show, eq]

(** Handshake response *)
type handshake_response = {
  challenge_id: string;
  nonce: string;
  signature: string;
  responder_org: organization;
} [@@deriving yojson, show, eq]

(** Delegation request *)
type delegation_request = {
  id: string;
  from_org: string;
  to_org: string;
  task: task;  (* Types.task *)
  priority: int;
  timeout_seconds: int option;
  created_at: string;
  status: string;
  result: string option;
} [@@deriving show]

(** Manual JSON conversion for delegation_request (task has custom serialization) *)
let delegation_request_to_yojson r =
  `Assoc [
    ("id", `String r.id);
    ("from_org", `String r.from_org);
    ("to_org", `String r.to_org);
    ("task", task_to_yojson r.task);
    ("priority", `Int r.priority);
    ("timeout_seconds", match r.timeout_seconds with Some t -> `Int t | None -> `Null);
    ("created_at", `String r.created_at);
    ("status", `String r.status);
    ("result", match r.result with Some s -> `String s | None -> `Null);
  ]

let delegation_request_of_yojson json =
  let module U = Yojson.Safe.Util in
  try
    match json |> U.member "task" |> task_of_yojson with
    | Error e -> Error (Printf.sprintf "task parsing failed: %s" e)
    | Ok task ->
        Ok {
          id = json |> U.member "id" |> U.to_string;
          from_org = json |> U.member "from_org" |> U.to_string;
          to_org = json |> U.member "to_org" |> U.to_string;
          task;
          priority = json |> U.member "priority" |> U.to_int;
          timeout_seconds = json |> U.member "timeout_seconds" |> U.to_int_option;
          created_at = json |> U.member "created_at" |> U.to_string;
          status = json |> U.member "status" |> U.to_string;
          result = json |> U.member "result" |> U.to_string_option;
        }
  with e -> Error (Printexc.to_string e)

(** Federation event - variant type with inline records *)
type federation_event =
  | HandshakeSuccess of { org_id: string; timestamp: string }
  | OrgJoined of { org_id: string; timestamp: string }
  | OrgLeft of { org_id: string; reason: string; timestamp: string }
  | TaskDelegated of { task_id: string; from_org: string; to_org: string; task: string; timestamp: string }
  | TaskCompleted of { task_id: string; result: string; timestamp: string }
  | TrustUpdated of { org_id: string; old_level: trust_level; new_level: trust_level; timestamp: string }
  | ConfigUpdated of { timestamp: string }
[@@deriving yojson, show, eq]

(** Trust too low error details *)
type trust_too_low_error = {
  org_id: string;
  required: trust_level;
  actual: trust_level;
} [@@deriving yojson, show, eq]

(** Delegation failed error details *)
type delegation_failed_error = {
  task_id: string;
  reason: string;
} [@@deriving yojson, show, eq]

(** Federation error *)
type federation_error =
  | InvalidChallenge
  | ExpiredChallenge
  | InvalidSignature
  | OrgNotFound of string
  | ConfigError of string
  | HandshakeError of string
  | TrustTooLow of trust_too_low_error
  | DelegationFailed of delegation_failed_error
  | FederationNotInitialized
[@@deriving yojson, show, eq]

(** Default trust threshold for delegation *)
let default_trust_threshold : trust_level = Verified

(** Helper: Create local organization *)
let make_local_org ~id ~name ?(capabilities = []) () : organization = {
  id;
  name;
  endpoint = None;
  public_key = None;
  trust_level = Trusted;  (* Local org is fully trusted *)
  joined_at = None;
  rooms = capabilities;  (* Use capabilities as rooms for local org *)
}

(** Helper: Create federation member from organization *)
let make_federation_member ~(org : organization) ~now : federation_member = {
  member_id = org.id;
  organization = org;
  capabilities = org.rooms;
  active = true;
  trust_level = org.trust_level;
  status = Active;
  joined_at = now;
}

(* ============================================ *)
(* Thread Safety: Eio.Mutex for Global State   *)
(* ============================================ *)

(** Eio-cooperative mutex for fiber-safe state access.
    Stdlib.Mutex blocks the OS thread and starves other Eio fibers. *)
let state_mutex = Eio.Mutex.create ()

(** Execute function with Eio mutex held (read-write). *)
let with_lock f =
  Eio.Mutex.use_rw ~protect:true state_mutex (fun () -> f ())

(* ============================================ *)
(* Input Validation                            *)
(* ============================================ *)

(** Validate organization/task ID format *)
let validate_id (id : string) (field_name : string) : (string, string) result =
  if String.length id = 0 then
    Error (Printf.sprintf "%s cannot be empty" field_name)
  else if String.length id > 256 then
    Error (Printf.sprintf "%s too long (max 256 chars)" field_name)
  else if String.contains id '/' || String.contains id '\\' then
    Error (Printf.sprintf "%s cannot contain path separators" field_name)
  else if String.contains id '\000' then
    Error (Printf.sprintf "%s cannot contain null bytes" field_name)
  else
    Ok id

(** Validate endpoint URL *)
let validate_endpoint (url : string) : (string, string) result =
  if String.length url = 0 then
    Error "Endpoint cannot be empty"
  else if not (String.sub url 0 (min 8 (String.length url)) = "https://" ||
               String.sub url 0 (min 7 (String.length url)) = "http://") then
    Error "Endpoint must be a valid URL (http:// or https://)"
  else
    Ok url

(* ============================================ *)
(* Safe File I/O with Result Types             *)
(* ============================================ *)

(** Safe file write with proper error handling *)
let safe_write_file (path : string) (content : string) : (unit, string) result =
  try
    let dir = Filename.dirname path in
    Fs_compat.mkdir_p dir;
    let tmp_path = path ^ ".tmp" in
    Fs_compat.save_file tmp_path content;
    (* Atomic rename for consistency *)
    Sys.rename tmp_path path;
    Ok ()
  with
  | Sys_error msg -> Error (Printf.sprintf "File write error: %s" msg)
  | Unix.Unix_error (err, _, _) -> Error (Printf.sprintf "Unix error: %s" (Unix.error_message err))

(** Safe file read with proper error handling *)
let safe_read_file (path : string) : (string, string) result =
  try
    if not (Fs_compat.file_exists path) then
      Error (Printf.sprintf "File not found: %s" path)
    else
      Ok (Fs_compat.load_file path)
  with
  | Sys_error msg -> Error (Printf.sprintf "File read error: %s" msg)

(** Safe file append with proper error handling *)
let safe_append_file (path : string) (content : string) : (unit, string) result =
  try
    let dir = Filename.dirname path in
    Fs_compat.mkdir_p dir;
    Fs_compat.append_file path content;
    Ok ()
  with
  | Sys_error msg -> Error (Printf.sprintf "File append error: %s" msg)
  | Unix.Unix_error (err, _, _) -> Error (Printf.sprintf "Unix error: %s" (Unix.error_message err))

(* ============================================ *)
(* Path Safety                                 *)
(* ============================================ *)

(** Validate path is within base directory (prevent path traversal) *)
let validate_path (base_path : string) (target_path : string) : (string, string) result =
  let normalized_base =
    try Unix.realpath base_path
    with Unix.Unix_error (err, _, _) ->
      Log.Misc.warn "federation: realpath failed for base %s: %s"
        base_path (Unix.error_message err);
      base_path
  in
  let normalized_target =
    try Unix.realpath (Filename.dirname target_path) ^ "/" ^ Filename.basename target_path
    with Unix.Unix_error (err, _, _) ->
      Log.Misc.warn "federation: realpath failed for target %s: %s"
        target_path (Unix.error_message err);
      target_path
  in
  if String.length normalized_target >= String.length normalized_base &&
     String.sub normalized_target 0 (String.length normalized_base) = normalized_base then
    Ok target_path
  else
    Error "Path traversal detected: target is outside base directory"

(** Federation state - stored in .masc/federation/ *)
type federation_state = {
  mutable fed_config: federation_config option;
  mutable pending_handshakes: handshake_challenge list;
  mutable pending_delegations: delegation_request list;
  mutable event_log: federation_event list;
}

(** Global federation state *)

open Ids
include Masc_error

type rate_limit_config = Masc_error.rate_limit_config = {
  per_minute: int;
  burst_allowed: int;
  priority_agents: string list;
  worker_multiplier: float;
  admin_multiplier: float;
  broadcast_per_minute: int;
  task_ops_per_minute: int;
}

type masc_error = t
let masc_error_to_string = to_string
let show_masc_error = show

(** Result type alias for MASC operations *)
type 'a masc_result = ('a, masc_error) result

(* ============================================ *)
(* Authentication & Authorization Types         *)
(* ============================================ *)

(** Agent role - enforced permission levels *)
type agent_role =
  | Worker    (* Can claim tasks, lock files, broadcast *)
  | Admin     (* Full access: init, reset, manage agents *)
[@@deriving show { with_path = false }]

let agent_role_to_string = function
  | Worker -> "worker"
  | Admin -> "admin"

let agent_role_of_string = function
  | "worker" -> Ok Worker
  | "admin" -> Ok Admin
  | s -> Error ("Unknown agent role: " ^ s)

let agent_role_to_yojson role = `String (agent_role_to_string role)

let all_agent_roles = [ Worker; Admin ]
let valid_agent_role_strings = List.map agent_role_to_string all_agent_roles

let agent_role_of_yojson = function
  | `String s -> agent_role_of_string s
  | other ->
    (* Bind the actual JSON kind we received so operators can tell a
       wrong-type bug ([`Int 1] / [`Bool true]) apart from a wrong-shape
       bug ([`Assoc] containing a [role] field by mistake).  The
       previous ["Expected string for agent_role"] message identified
       neither the contract nor the offender. *)
    Error
      (Printf.sprintf
         "agent_role_of_yojson: expected JSON string (one of %s), got %s"
         (String.concat " | "
            (List.map (Printf.sprintf "%S") valid_agent_role_strings))
         (Json_util.kind_name other))

(** Agent credential - used for token-based auth *)
type agent_credential = {
  id: Credential_id.t option; [@default None]
  agent_id: Agent_id.t option; [@default None]
  agent_name: string;
  token: string;        (* SHA256 hash of secret *)
  role: agent_role;
  created_at: string;
  expires_at: string option; [@default None]
}

let agent_credential_to_yojson (c : agent_credential) =
  `Assoc [
    ("id", match c.id with Some id -> `String (Credential_id.to_string id) | None -> `Null);
    ("agent_id", match c.agent_id with Some aid -> `String (Agent_id.to_string aid) | None -> `Null);
    ("agent_name", `String c.agent_name);
    ("token", `String c.token);
    ("role", `String (agent_role_to_string c.role));
    ("created_at", `String c.created_at);
    ("expires_at", Json_util.string_opt_to_json c.expires_at);
  ]

let agent_credential_field_names =
  [ "id"; "agent_id"; "agent_name"; "token"; "role"; "created_at"; "expires_at" ]

let validate_agent_credential_fields = function
  | `Assoc fields ->
    let rec loop seen = function
      | [] -> Ok fields
      | (name, _) :: rest ->
        if not (List.mem name agent_credential_field_names)
        then Error (Printf.sprintf "agent_credential_of_yojson: unknown field %S" name)
        else if List.mem name seen
        then Error (Printf.sprintf "agent_credential_of_yojson: duplicate field %S" name)
        else loop (name :: seen) rest
    in
    loop [] fields
  | other ->
    Error
      (Printf.sprintf
         "agent_credential_of_yojson: expected JSON object, got %s"
         (Json_util.kind_name other))

let require_credential_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some value ->
    Error
      (Printf.sprintf
         "agent_credential_of_yojson: field %S must be a string, got %s"
         name
         (Json_util.kind_name value))
  | None ->
    Error
      (Printf.sprintf "agent_credential_of_yojson: missing required field %S" name)

let require_credential_optional_string fields name =
  match List.assoc_opt name fields with
  | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some value ->
    Error
      (Printf.sprintf
         "agent_credential_of_yojson: field %S must be a string or null, got %s"
         name
         (Json_util.kind_name value))
  | None ->
    Error
      (Printf.sprintf "agent_credential_of_yojson: missing required field %S" name)

let agent_credential_of_yojson json =
  let ( let* ) = Result.bind in
  let* fields = validate_agent_credential_fields json in
  let* id = require_credential_optional_string fields "id" in
  let* agent_id = require_credential_optional_string fields "agent_id" in
  let* agent_name = require_credential_string fields "agent_name" in
  let* token = require_credential_string fields "token" in
  let* role_name = require_credential_string fields "role" in
  let* role = agent_role_of_string role_name in
  let* created_at = require_credential_string fields "created_at" in
  let* expires_at = require_credential_optional_string fields "expires_at" in
  Ok
    {
      id = Option.map Credential_id.of_string id;
      agent_id = Option.map Agent_id.of_string agent_id;
      agent_name;
      token;
      role;
      created_at;
      expires_at;
    }

(** Auth configuration *)
type auth_config = {
  enabled: bool;
  workspace_secret_hash: string option; [@default None]
  require_token: bool; [@default true]
  token_expiry_hours: int; [@default 24]
} [@@deriving show]

let default_auth_config = {
  enabled = true;
  workspace_secret_hash = None;
  require_token = true;
  token_expiry_hours = 24;
}

let auth_config_to_yojson c =
  `Assoc [
    ("enabled", `Bool c.enabled);
    ("workspace_secret_hash", Json_util.string_opt_to_json c.workspace_secret_hash);
    ("require_token", `Bool c.require_token);
    ("token_expiry_hours", `Int c.token_expiry_hours);
  ]

let auth_config_field_names =
  [ "enabled"; "workspace_secret_hash"; "require_token"; "token_expiry_hours" ]

let validate_auth_config_fields = function
  | `Assoc fields ->
    let rec loop seen = function
      | [] -> Ok fields
      | (name, _) :: rest ->
        if not (List.mem name auth_config_field_names)
        then Error (Printf.sprintf "auth_config_of_yojson: unknown field %S" name)
        else if List.mem name seen
        then Error (Printf.sprintf "auth_config_of_yojson: duplicate field %S" name)
        else loop (name :: seen) rest
    in
    loop [] fields
  | other ->
    Error
      (Printf.sprintf
         "auth_config_of_yojson: expected JSON object, got %s"
         (Json_util.kind_name other))

let auth_config_bool fields name ~default =
  match List.assoc_opt name fields with
  | None -> Ok default
  | Some (`Bool value) -> Ok value
  | Some value ->
    Error
      (Printf.sprintf
         "auth_config_of_yojson: field %S must be a boolean, got %s"
         name
         (Json_util.kind_name value))

let auth_config_optional_string fields name =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some value ->
    Error
      (Printf.sprintf
         "auth_config_of_yojson: field %S must be a string or null, got %s"
         name
         (Json_util.kind_name value))

let auth_config_int fields name ~default =
  match List.assoc_opt name fields with
  | None -> Ok default
  | Some (`Int value) -> Ok value
  | Some value ->
    Error
      (Printf.sprintf
         "auth_config_of_yojson: field %S must be an integer, got %s"
         name
         (Json_util.kind_name value))

(* One predicate for "is this a sha256 digest in lowercase hex", shared with
   the capability heads and the official-client session store. Four copies
   decided it before this line; a fix to any one of them reached none of the
   others, and this one guards a workspace secret hash. *)
let is_sha256_hex = String_util.is_lowercase_sha256_hex
;;

let validate_workspace_secret_hash = function
  | None -> Ok None
  | Some value when is_sha256_hex value -> Ok (Some value)
  | Some _ ->
    Error
      "auth_config_of_yojson: field \"workspace_secret_hash\" must be 64 lowercase hexadecimal characters"
;;

(* The window a bearer credential may be issued for. One owner for the pair: the
   config decoder below and every caller that names its own window instead of
   taking the config's read the same two numbers. *)
let min_token_expiry_hours = 1
let max_token_expiry_hours = 8_760

let validate_token_expiry_hours value =
  if value >= min_token_expiry_hours && value <= max_token_expiry_hours
  then Ok value
  else
    Error
      (Printf.sprintf
         "auth_config_of_yojson: field \"token_expiry_hours\" must be between %d and %d"
         min_token_expiry_hours
         max_token_expiry_hours)
;;

let auth_config_of_yojson json =
  let ( let* ) = Result.bind in
  let* fields = validate_auth_config_fields json in
  let* enabled = auth_config_bool fields "enabled" ~default:true in
  let* workspace_secret_hash = auth_config_optional_string fields "workspace_secret_hash" in
  let* workspace_secret_hash = validate_workspace_secret_hash workspace_secret_hash in
  let* require_token = auth_config_bool fields "require_token" ~default:true in
  let* token_expiry_hours = auth_config_int fields "token_expiry_hours" ~default:24 in
  let* token_expiry_hours = validate_token_expiry_hours token_expiry_hours in
  Ok { enabled; workspace_secret_hash; require_token; token_expiry_hours }

(** Permission matrix - what each role can do *)
type permission =
  | CanInit
  | CanReset
  | CanReadState
  | CanAddTask
  | CanClaimTask
  | CanCompleteTask
  | CanBroadcast
  | CanVote
  | CanAdmin
[@@deriving show { with_path = false }]

(** Stable wire format for [permission].  Returns the same string as
    [show_permission] does today (PascalCase constructor name), but
    locks the contract: future renames of the variant constructor will
    NOT change the wire string, because callers must update this
    explicit match at the same time.  Public API/SSE/error output
    (tool_catalog requiredPermission, Auth_error.Forbidden action)
    depends on these exact strings. *)
let permission_to_string = function
  | CanInit -> "CanInit"
  | CanReset -> "CanReset"
  | CanReadState -> "CanReadState"
  | CanAddTask -> "CanAddTask"
  | CanClaimTask -> "CanClaimTask"
  | CanCompleteTask -> "CanCompleteTask"
  | CanBroadcast -> "CanBroadcast"
  | CanVote -> "CanVote"
  | CanAdmin -> "CanAdmin"

(** Get permissions for a role *)
let permissions_for_role = function
  | Worker -> [
      CanReadState;
      CanAddTask; CanClaimTask; CanCompleteTask;
      CanBroadcast;
      CanVote;
    ]
  | Admin -> [
      CanInit; CanReset;
      CanReadState;
      CanAddTask; CanClaimTask; CanCompleteTask;
      CanBroadcast;
      CanVote; CanAdmin;
    ]

(* Direct (role, permission) variant match — O(1), no per-call list
   allocation.  Hot path: [Auth.check_permission] runs this on every
   protected operation; [auth diagnostics] runs it 10+ times per snapshot.
   The previous [List.mem permission (permissions_for_role role)] form
   built a fresh 12-element (Worker) / 15-element (Admin) list each
   call.

   Parallel to [permissions_for_role]: both forms are compiler-checked
   exhaustive against the [permission] variant, so adding a new
   constructor breaks both at compile time rather than letting one
   silently fall through to a default. *)
let has_permission role permission =
  match role, permission with
  | Admin, _ -> true
  | Worker, (CanInit | CanReset | CanAdmin) -> false
  | Worker, ( CanReadState | CanAddTask | CanClaimTask | CanCompleteTask | CanBroadcast
            | CanVote ) -> true

(* ============================================ *)
(* Rate limit role integration                  *)
(* ============================================ *)

(** Get role multiplier for rate limits *)
let multiplier_for_role config = function
  | Worker -> config.worker_multiplier
  | Admin -> config.admin_multiplier

(** Compute effective limit for role and category *)
let effective_limit config ~role ~category =
  let base = limit_for_category config category in
  let mult = multiplier_for_role config role in
  int_of_float (float_of_int base *. mult)

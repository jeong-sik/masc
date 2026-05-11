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

let agent_role_of_yojson = function
  | `String s -> agent_role_of_string s
  | _ -> Error "Expected string for agent_role"

let all_agent_roles = [ Worker; Admin ]
let valid_agent_role_strings = List.map agent_role_to_string all_agent_roles

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
    ("admin", `Bool (c.role = Admin));
    ("created_at", `String c.created_at);
    ("expires_at", match c.expires_at with Some s -> `String s | None -> `Null);
  ]

let agent_credential_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let agent_name = json |> member "agent_name" |> to_string in
    let token = json |> member "token" |> to_string in
    let role =
      match json |> member "role" |> to_string_option with
      | Some s -> agent_role_of_string s
      | None ->
        let is_admin = json |> member "admin" |> to_bool_option |> Option.value ~default:false in
        Ok (if is_admin then Admin else Worker)
    in
    (match role with
     | Error e -> Error e
     | Ok role ->
       let created_at = json |> member "created_at" |> to_string in
       let expires_at = json |> member "expires_at" |> to_string_option in
       let id = json |> member "id" |> to_string_option |> Option.map Credential_id.of_string in
       let agent_id = json |> member "agent_id" |> to_string_option |> Option.map Agent_id.of_string in
       Ok { id; agent_id; agent_name; token; role; created_at; expires_at })
  with e -> Error (Printexc.to_string e)

(** Auth configuration *)
type auth_config = {
  enabled: bool;
  room_secret_hash: string option; [@default None]
  require_token: bool; [@default false]
  token_expiry_hours: int; [@default 24]
} [@@deriving show]

let default_auth_config = {
  enabled = true;
  room_secret_hash = None;
  require_token = true;
  token_expiry_hours = 24;
}

let auth_config_to_yojson c =
  `Assoc [
    ("enabled", `Bool c.enabled);
    ("room_secret_hash", match c.room_secret_hash with Some s -> `String s | None -> `Null);
    ("require_token", `Bool c.require_token);
    ("token_expiry_hours", `Int c.token_expiry_hours);
  ]

let auth_config_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let enabled = json |> member "enabled" |> to_bool in
    let room_secret_hash = json |> member "room_secret_hash" |> to_string_option in
    let require_token = json |> member "require_token" |> to_bool in
    let token_expiry_hours = json |> member "token_expiry_hours" |> to_int in
    Ok { enabled; room_secret_hash; require_token; token_expiry_hours }
  with e -> Error (Printexc.to_string e)

(** Permission matrix - what each role can do *)
type permission =
  | CanInit
  | CanReset
  | CanJoin
  | CanLeave
  | CanReadState
  | CanAddTask
  | CanClaimTask
  | CanCompleteTask
  | CanBroadcast
  | CanOpenPortal
  | CanSendPortal
  | CanCreateWorktree
  | CanRemoveWorktree
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
  | CanJoin -> "CanJoin"
  | CanLeave -> "CanLeave"
  | CanReadState -> "CanReadState"
  | CanAddTask -> "CanAddTask"
  | CanClaimTask -> "CanClaimTask"
  | CanCompleteTask -> "CanCompleteTask"
  | CanBroadcast -> "CanBroadcast"
  | CanOpenPortal -> "CanOpenPortal"
  | CanSendPortal -> "CanSendPortal"
  | CanCreateWorktree -> "CanCreateWorktree"
  | CanRemoveWorktree -> "CanRemoveWorktree"
  | CanVote -> "CanVote"
  | CanAdmin -> "CanAdmin"

(** Get permissions for a role *)
let permissions_for_role = function
  | Worker -> [
      CanReadState; CanJoin; CanLeave;
      CanAddTask; CanClaimTask; CanCompleteTask;
      CanBroadcast;
      CanOpenPortal; CanSendPortal;
      CanCreateWorktree; CanRemoveWorktree;
      CanVote;
    ]
  | Admin -> [
      CanInit; CanReset;
      CanReadState; CanJoin; CanLeave;
      CanAddTask; CanClaimTask; CanCompleteTask;
      CanBroadcast;
      CanOpenPortal; CanSendPortal;
      CanCreateWorktree; CanRemoveWorktree;
      CanVote; CanAdmin;
    ]

(* Direct (role, permission) variant match — O(1), no per-call list
   allocation.  Hot path: [Auth.check_permission] runs this on every
   protected operation; [Auth_doctor] runs it 10+ times per snapshot.
   The previous [List.mem permission (permissions_for_role role)] form
   built a fresh 12-14 element list each call.

   Parallel to [permissions_for_role]: both forms are compiler-checked
   exhaustive against the [permission] variant, so adding a new
   constructor breaks both at compile time rather than letting one
   silently fall through to a default. *)
let has_permission role permission =
  match role, permission with
  | Admin, _ -> true
  | Worker, (CanInit | CanReset | CanAdmin) -> false
  | Worker, ( CanJoin | CanLeave | CanReadState | CanAddTask
            | CanClaimTask | CanCompleteTask | CanBroadcast
            | CanOpenPortal | CanSendPortal | CanCreateWorktree
            | CanRemoveWorktree | CanVote ) -> true

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

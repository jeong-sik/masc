(* See [authz_types.mli] for the contract. *)

module User_id = Authz_id.Make ()
module Service_id = Authz_id.Make ()
module Runtime_id = Authz_id.Make ()
module Provider_account_id = Authz_id.Make ()
module Grant_id = Authz_id.Make ()
module Keeper_id = Authz_id.Make ()
module Policy_id = Authz_id.Make ()
module Session_id = Authz_id.Make ()
module Pat_id = Authz_id.Make ()
module Service_credential_id = Authz_id.Make ()
module Workspace_id = Authz_id.Make ()
module Invite_id = Authz_id.Make ()
module Registration_id = Authz_id.Make ()
module Account_home_namespace = struct
  module Id = Authz_id.Make ()
  include Id

  let first_capital s =
    Seq.find_map
      (fun (index, byte) ->
        match byte with
        | 'A' .. 'Z' -> Some index
        | _ -> None)
      (String.to_seqi s)
  ;;

  (* The checks keep the order of [Authz_id]: emptiness and length first, then
     the first byte outside this alphabet, which is the earlier of the two
     scans. A path segment has no capital letter. *)
  let of_string s =
    match Id.of_string s, first_capital s with
    | Ok id, None -> Ok id
    | Ok (_ : Id.t), Some index -> Error (Authz_id.Invalid_byte { index })
    | Error (Authz_id.Invalid_byte { index }), Some capital ->
      Error (Authz_id.Invalid_byte { index = Int.min index capital })
    | ( Error ((Authz_id.Empty | Authz_id.Too_long | Authz_id.Path_segment | Authz_id.Invalid_byte _) as error)
      , (None | Some _) ) -> Error error
  ;;
end

module Conversation_id = Authz_id.Make ()

module Principal = struct
  type t =
    | Human of User_id.t
    | Service of Service_id.t

  let equal a b =
    match a, b with
    | Human x, Human y -> User_id.equal x y
    | Service x, Service y -> Service_id.equal x y
    | Human _, Service _ | Service _, Human _ -> false
  ;;

  let to_string = function
    | Human id -> "human:" ^ User_id.to_string id
    | Service id -> "service:" ^ Service_id.to_string id
  ;;
end

module Effect = struct
  type t =
    | Read_state
    | Invoke_model
    | Use_tool
    | Manage_own_provider
    | Manage_own_runtime
    | Manage_own_grant
    | Manage_own_keeper
    | Manage_machine_shared
    | Admin_disable_block
    | Read_audit_metadata

  let to_string = function
    | Read_state -> "read_state"
    | Invoke_model -> "invoke_model"
    | Use_tool -> "use_tool"
    | Manage_own_provider -> "manage_own_provider"
    | Manage_own_runtime -> "manage_own_runtime"
    | Manage_own_grant -> "manage_own_grant"
    | Manage_own_keeper -> "manage_own_keeper"
    | Manage_machine_shared -> "manage_machine_shared"
    | Admin_disable_block -> "admin_disable_block"
    | Read_audit_metadata -> "read_audit_metadata"
  ;;

  let of_string = function
    | "read_state" -> Some Read_state
    | "invoke_model" -> Some Invoke_model
    | "use_tool" -> Some Use_tool
    | "manage_own_provider" -> Some Manage_own_provider
    | "manage_own_runtime" -> Some Manage_own_runtime
    | "manage_own_grant" -> Some Manage_own_grant
    | "manage_own_keeper" -> Some Manage_own_keeper
    | "manage_machine_shared" -> Some Manage_machine_shared
    | "admin_disable_block" -> Some Admin_disable_block
    | "read_audit_metadata" -> Some Read_audit_metadata
    | _ -> None
  ;;

  (* By label. [to_string] is an exhaustive match, so a new effect, or a
     constructor that carries data, fails to compile here instead of changing
     the order silently. *)
  let compare a b = String.compare (to_string a) (to_string b)

  let is_management = function
    | Manage_own_provider
    | Manage_own_runtime
    | Manage_own_grant
    | Manage_own_keeper
    | Manage_machine_shared
    | Admin_disable_block -> true
    | Read_state | Invoke_model | Use_tool | Read_audit_metadata -> false
  ;;

  module Set = Set.Make (struct
      type nonrec t = t

      let compare = compare
    end)
end

module Channel = struct
  type t =
    | Direct
    | Delegate
    | Schedule
    | Board_trigger
    | Retry
    | Resume
    | Fusion
    | Vision
    | Verifier
    | Autonomous

  let to_string = function
    | Direct -> "direct"
    | Delegate -> "delegate"
    | Schedule -> "schedule"
    | Board_trigger -> "board_trigger"
    | Retry -> "retry"
    | Resume -> "resume"
    | Fusion -> "fusion"
    | Vision -> "vision"
    | Verifier -> "verifier"
    | Autonomous -> "autonomous"
  ;;

  let of_string = function
    | "direct" -> Some Direct
    | "delegate" -> Some Delegate
    | "schedule" -> Some Schedule
    | "board_trigger" -> Some Board_trigger
    | "retry" -> Some Retry
    | "resume" -> Some Resume
    | "fusion" -> Some Fusion
    | "vision" -> Some Vision
    | "verifier" -> Some Verifier
    | "autonomous" -> Some Autonomous
    | _ -> None
  ;;

  (* By label, for the same reason as [Effect.compare]. *)
  let compare a b = String.compare (to_string a) (to_string b)
  let equal a b = compare a b = 0

  module Set = Set.Make (struct
      type nonrec t = t

      let compare = compare
    end)
end

module Runtime_scope = Authz_scope.Make (Runtime_id)
module Channel_scope = Authz_scope.Make (Channel)
module Effect_scope = Authz_scope.Make (Effect)

module Authorization_scope = struct
  type t =
    { runtimes : Runtime_scope.t
    ; channels : Channel_scope.t
    ; allowed_effects : Effect_scope.t
    }

  let all =
    { runtimes = Runtime_scope.all
    ; channels = Channel_scope.all
    ; allowed_effects = Effect_scope.all
    }
  ;;

  let inter a b =
    { runtimes = Runtime_scope.inter a.runtimes b.runtimes
    ; channels = Channel_scope.inter a.channels b.channels
    ; allowed_effects = Effect_scope.inter a.allowed_effects b.allowed_effects
    }
  ;;

  let equal a b =
    Runtime_scope.equal a.runtimes b.runtimes
    && Channel_scope.equal a.channels b.channels
    && Effect_scope.equal a.allowed_effects b.allowed_effects
  ;;
end

module Pat_scope = struct
  type t =
    { scope : Authorization_scope.t
    ; expires_at : float option
    }
end

module Pat_binding = struct
  type t =
    | Not_pat
    | Pat of Pat_scope.t

  let scope = function
    | Not_pat -> Authorization_scope.all
    | Pat pat -> pat.Pat_scope.scope
  ;;
end

module Delegate_policy = struct
  type t =
    { id : Policy_id.t
    ; initiator : Principal.t
    ; executor : Principal.t
    ; scope : Authorization_scope.t
    }

  let neutral_direct =
    { Authorization_scope.runtimes = Runtime_scope.all
    ; channels = Channel_scope.only (Channel.Set.singleton Channel.Direct)
    ; allowed_effects = Effect_scope.all
    }
  ;;
end

module Effect_request = struct
  type t = Effect.Set.t

  let make first rest = Effect.Set.of_list (first :: rest)
  let to_set effects = effects
end

module Execution_context = struct
  type t =
    { initiator : Principal.t
    ; executor : Principal.t
    ; channel : Channel.t
    ; stored_scope : Authorization_scope.t
    ; pat_scope : Pat_binding.t
    }
end

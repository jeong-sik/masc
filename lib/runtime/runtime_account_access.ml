(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Ps = Authz_principal_state
module Layout = Runtime_account_home_layout

type 'client person_sealed =
  { person_client : 'client Runtime_official_account.client
  ; provider_account_id : Authz_types.Provider_account_id.t
  ; integration_id : Authz_types.Integration_id.t
  ; account_home : string
  }

type 'client sealed =
  | Captured of 'client Runtime_official_account.t
  | Person_account of 'client person_sealed

type 'client authorized = 'client Runtime_official_account.t

let seal account = Captured account

let seal_person ~client ~provider_account_id ~integration_id ~account_home =
  Person_account { person_client = client; provider_account_id; integration_id; account_home }
;;

let home = function
  | Captured sealed -> Runtime_official_account.home sealed
  | Person_account person -> person.account_home
;;

let same_client
    (type a b)
    (left : a Runtime_official_account.client)
    (right : b Runtime_official_account.client)
  =
  match left, right with
  | Runtime_official_account.Claude_code, Runtime_official_account.Claude_code
  | Runtime_official_account.Codex, Runtime_official_account.Codex -> true
  | ( Runtime_official_account.Claude_code, Runtime_official_account.Codex
    | Runtime_official_account.Codex, Runtime_official_account.Claude_code ) -> false
;;

let same left right =
  match left, right with
  | Captured a, Captured b -> Runtime_official_account.same a b
  | Person_account a, Person_account b ->
    same_client a.person_client b.person_client
    && Authz_types.Provider_account_id.equal a.provider_account_id b.provider_account_id
    && Authz_types.Integration_id.equal a.integration_id b.integration_id
    && String.equal a.account_home b.account_home
  | Captured _, Person_account _ | Person_account _, Captured _ -> false
;;

let account authorized = authorized

type host_client =
  | Antigravity
  | Acp_client of Runtime_acp_client.driver
  | Api_provider
  | Model_list
  | Files_api
  | Replacement_catalog
  | Web_search
  | Systemone_cloud
  | Voice_endpoint

(* The proof carries nothing: a single-user process shares every account of
   its host, so one start of a host client is as allowed as another. *)
type host_account = Shared_by_single_user

let host_client_name = function
  | Antigravity -> "Antigravity"
  | Acp_client driver -> "ACP (" ^ Runtime_acp_client.driver_to_string driver ^ ")"
  | Api_provider -> "An API provider of the runtime table"
  | Model_list -> "A model-list or serving-window request of a setup connection"
  | Files_api -> "The Files API of masc_file_*"
  | Replacement_catalog -> "A target of the replacement catalog AGENT_CORE_MODEL_CATALOG names"
  | Web_search -> "A web search provider that masc_web_search calls with its key"
  | Systemone_cloud -> "The cloud backend of SystemOne"
  | Voice_endpoint -> "A voice endpoint that names a key"
;;

type t =
  | Single_user of Authz_boot_mode_read.single_user
  | Multi_account of
      { zone : Authz_zone.t
      ; base_path : string
      ; now : unit -> float
      }

type publish_error = Already_published

let publish_error_to_string Already_published =
  "this process published whether a CLI may start on an account before, and publishes it once"
;;

type state =
  | Unpublished
  | Published of t

let state = Atomic.make Unpublished

type published = t

let publish access =
  let observed = Atomic.get state in
  match observed with
  | Published (_ : t) -> Error Already_published
  | Unpublished ->
    (* A failed exchange means another call published in between. *)
    if Atomic.compare_and_set state observed (Published access)
    then Ok access
    else Error Already_published
;;

let published_access (published : published) : t = published

let published_base_path = function
  | Single_user single_user -> Authz_boot_mode_read.single_user_base_path single_user
  | Multi_account { zone = _; base_path; now = _ } -> base_path
;;

let current () =
  match Atomic.get state with
  | Unpublished -> None
  | Published access -> Some access
;;

let is_multi_account () =
  match Atomic.get state with
  | Published (Multi_account _) -> true
  | Unpublished | Published (Single_user _) -> false
;;

let is_person_home path =
  match Atomic.get state with
  | Unpublished -> false
  | Published access -> Layout.under_persons ~base_path:(published_base_path access) path
;;

let is_person_sealed = function
  | Person_account _ -> true
  | Captured _ -> false
;;

let person_provider_account_id = function
  | Person_account person -> Some person.provider_account_id
  | Captured _ -> None
;;

let publish_host_tool ~base_path ~config_dir =
  match Authz_boot_mode_read.tool ~base_path ~config_dir with
  | Error _ as refused -> refused
  | Ok single_user ->
    publish (Single_user single_user)
    |> Result.map (fun (_ : published) -> ())
    |> Result.map_error (fun error -> publish_error_to_string error, [])
;;

type request =
  | Keeper_turn of
      { owner : Authz_types.User_id.t
      ; keeper_id : Authz_types.Keeper_id.t
      ; channel : Authz_types.Channel.t
      ; stored_scope : Authz_types.Authorization_scope.t
      ; pat : Authz_types.Pat_binding.t
      ; runtime_id : string
      }
  | Operator_keeper_turn of
      { keeper_name : string
      ; runtime_id : string
      }
  | Own_account of
      { user_id : Authz_types.User_id.t
      ; provider_account_id : Authz_types.Provider_account_id.t
      }
  | Operator_call

type refusal =
  | Not_published
  | No_operator
  | No_operator_keeper of string
  | Zone_uncertain of Authz_zone.uncertain
  | Turn_refused of Authz_keeper_turn.refusal
  | Not_the_assigned_runtime of
      { requested : string
      ; assigned : Authz_types.Runtime_id.t
      }
  | Not_active of Authz_types.User_id.t
  | No_membership of Authz_types.User_id.t
  | Home_unresolved of string
  | Not_a_declared_home
  | Not_the_account_home of Authz_types.Provider_account_id.t
  | Not_the_account_integration of
      { provider_account_id : Authz_types.Provider_account_id.t
      ; expected : Authz_types.Integration_id.t
      ; claimed : Authz_types.Integration_id.t
      }
  | Not_the_account_key of Authz_types.Provider_account_id.t
  | Account_key_unusable of
      { provider_account_id : Authz_types.Provider_account_id.t
      ; reason : Runtime_api_key_file.read_error
      }
  | Home_asks_for_environment of Authz_types.Provider_account_id.t
  | Account_unavailable of
      { provider_account_id : Authz_types.Provider_account_id.t
      ; reason : Authz_provider_account.unavailable
      }
  | Host_account of host_client
  | Off_keeper of Authz_types.Keeper_id.t
  | Off_runtime of Authz_types.Runtime_id.t
  | Off_person_home
  | Off_own_account of Authz_types.User_id.t

let refusal_to_string = function
  | Not_published -> "this process has not published whether a CLI may start on an account"
  | No_operator -> "in multi-account mode no operator owns the account of a person"
  | Zone_uncertain uncertain ->
    "the authorization log cannot be trusted now, so no client starts on an account: "
    ^ Authz_zone.uncertain_to_string uncertain
  | No_operator_keeper name ->
    Printf.sprintf
      "in multi-account mode a Keeper is a person's, and %S is a Keeper of the operator"
      name
  | Turn_refused refusal -> "the turn is refused: " ^ Authz_keeper_turn.refusal_to_string refusal
  | Not_the_assigned_runtime { requested; assigned } ->
    Printf.sprintf
      "the turn asks for the Runtime %s, and its owner gave the Keeper %s"
      requested
      (Authz_types.Runtime_id.to_string assigned)
  | Not_active user_id ->
    Printf.sprintf "%s is not an active person of the log" (Authz_types.User_id.to_string user_id)
  | No_membership user_id ->
    Printf.sprintf "%s has no membership" (Authz_types.User_id.to_string user_id)
  | Home_unresolved detail -> "the home of the account could not be spelled: " ^ detail
  | Not_a_declared_home ->
    "the account was captured from an inherited home"
  | Not_the_account_home provider_account_id ->
    Printf.sprintf
      "the account was captured from another home than the one of %s"
      (Authz_types.Provider_account_id.to_string provider_account_id)
  | Not_the_account_integration { provider_account_id; expected; claimed } ->
    Printf.sprintf
      "the sealed account of %s names integration %s, not %s"
      (Authz_types.Provider_account_id.to_string provider_account_id)
      (Authz_types.Integration_id.to_string claimed)
      (Authz_types.Integration_id.to_string expected)
  | Not_the_account_key provider_account_id ->
    Printf.sprintf
      "the account was not captured on the key the log gives %s"
      (Authz_types.Provider_account_id.to_string provider_account_id)
  | Account_key_unusable { provider_account_id; reason } ->
    Printf.sprintf
      "the key file of %s could not be read: %s"
      (Authz_types.Provider_account_id.to_string provider_account_id)
      (Runtime_api_key_file.read_error_to_string reason)
  | Home_asks_for_environment provider_account_id ->
    Printf.sprintf
      "the configuration of the home of %s names variables of the environment of the server, \
       and no client starts on the home of a person that does"
      (Authz_types.Provider_account_id.to_string provider_account_id)
  | Account_unavailable { provider_account_id; reason } ->
    Printf.sprintf
      "the account %s is not read: %s"
      (Authz_types.Provider_account_id.to_string provider_account_id)
      (Authz_provider_account.unavailable_to_string reason)
  | Host_account
      (( Api_provider
       | Model_list
       | Files_api
       | Replacement_catalog
       | Web_search
       | Systemone_cloud
       | Voice_endpoint ) as client) ->
    Printf.sprintf
      "%s sends with the credential its operator declared, which is an account of the \
       host, and a multi-account process shares no account of its host"
      (host_client_name client)
  | Host_account ((Antigravity | Acp_client _) as client) ->
    Printf.sprintf
      "%s starts on an account of the host, and a multi-account process shares no \
       account of its host"
      (host_client_name client)
  | Off_keeper keeper_id ->
    Printf.sprintf
      "the Keeper %s belongs to an account, and the accounts of this installation were \
       turned off: it stays read-only and runs no turn"
      (Authz_types.Keeper_id.to_string keeper_id)
  | Off_runtime runtime_id ->
    Printf.sprintf
      "the Runtime %s belongs to an account, and the accounts of this installation were \
       turned off: no turn runs on it"
      (Authz_types.Runtime_id.to_string runtime_id)
  | Off_person_home ->
    "the home is under the runtime roots of the persons (.masc/accounts), whose accounts were \
     turned off: no client starts on it"
  | Off_own_account user_id ->
    Printf.sprintf
      "the accounts of this installation were turned off, so no client starts on an account \
       of %s"
      (Authz_types.User_id.to_string user_id)
;;

let layout_client (type client) (client : client Runtime_official_account.client) =
  match client with
  | Runtime_official_account.Claude_code -> Layout.Claude_home
  | Runtime_official_account.Codex -> Layout.Codex_home
;;

(* What a start claims, whichever client it is for: the client whose login
   keeps the home, the home when a declaration chose it, and the file its API
   key was read from. [None] of the home is a home the environment of the
   process chose. [None] of the file is an account that carries no key of a
   file. *)
type claim =
  { client : Layout.client
  ; declared_home : string option
  ; key_file : string option
  ; asked_names : string list
  }

(* The runtime root of the namespace the admission of [user_id] fixed. *)
let person_root ~base_path (state : Authz_state.t) user_id =
  match Ps.find_membership state.Authz_state.principals user_id with
  | None -> Error (No_membership user_id)
  | Some membership ->
    Ok (Layout.person_runtime_root ~base_path ~namespace:membership.Ps.account_home_namespace)
;;

(* The home of [provider_account_id] under the runtime root of the person is
   the one home a CLI for that person starts on. *)
let own_home ~runtime_root provider_account_id claim =
  match
    Layout.home
      ~runtime_root
      claim.client
      ~account_id:(Authz_types.Provider_account_id.to_string provider_account_id)
  with
  | Error detail -> Error (Home_unresolved detail)
  | Ok expected ->
    (match claim.declared_home with
     | None -> Error Not_a_declared_home
     | Some home ->
       if String.equal expected home
       then Ok ()
       else Error (Not_the_account_home provider_account_id))
;;

(* HIGH-RISK-UNREVIEWED: the environment of the process is the operator's.
   The configuration of a Codex home names variables its client takes from
   it ([Runtime_official_account.names_asked_by_the_home]), and the home of a
   person is written by the client that person drives. So the judgment
   authorizes a client on the home of a person only when the home asks for
   none. The client of a login does not pass here. *)
let asks_for_nothing provider_account_id claim =
  match claim.asked_names with
  | [] -> Ok ()
  | (_ : string) :: (_ : string list) -> Error (Home_asks_for_environment provider_account_id)
;;

(* HIGH-RISK-UNREVIEWED: the key a child is handed is the one the log gives
   the account, and no other. A key account carries the key of the file of
   the generation its records say, spelled under the runtime root of the
   person the request is for, so no request reaches a file of another
   person. An account that is not a key account, a login account or one no
   record links yet, carries no key of a file. The runtime root is the one
   [own_home] spelled the home from. The layout resolves it once more for
   the file, so a root that changed between the two is refused as a home
   that could not be spelled. The file is compared by its spelling: what the
   name leads to is read by [Runtime_api_key_file.read], which takes a
   private regular file of this user and refuses a link in its place. A link
   in the place of one of its folders is followed: only a writer with the
   uid of the server makes one. *)
let own_key ~runtime_root (state : Authz_state.t) provider_account_id claim =
  let expected =
    match Authz_provider_account_state.find state.Authz_state.provider_accounts provider_account_id with
    | None
    | Some
        { Authz_provider_account_state.kind = Authz_provider_account_state.Login { integration_id = _ }
        ; owner = _
        } -> Ok None
    | Some
        { Authz_provider_account_state.kind =
            Authz_provider_account_state.Key { integration_id = _; generation }
        ; owner = _
        } ->
      Layout.key_file ~runtime_root ~account_id:provider_account_id ~generation
      |> Result.map Option.some
  in
  match expected with
  | Error detail -> Error (Home_unresolved detail)
  | Ok expected ->
    if Option.equal String.equal expected claim.key_file
    then Ok ()
    else Error (Not_the_account_key provider_account_id)
;;

(* One request is judged on one snapshot, and only on one the zone could be
   trusted for. *)
let on_trusted zone judge =
  match Authz_zone.read zone with
  | Error uncertain -> Error (Zone_uncertain uncertain)
  | Ok trusted -> judge trusted (trusted :> Authz_zone.snapshot).Authz_zone.state
;;

(* The turn the log gives a request of a person's Keeper. It reads nothing
   of the account the request was captured on. *)
let decided_turn trusted ~owner ~keeper_id ~channel ~stored_scope ~pat ~runtime_id ~now =
  match
    Authz_keeper_turn.decide
      trusted
      ~owner
      ~keeper_id
      ~channel
      ~stored_scope
      ~pat
      ~now:(now ())
  with
  | Error refusal -> Error (Turn_refused refusal)
  | Ok turn ->
    if String.equal (Authz_types.Runtime_id.to_string turn.Authz_keeper_turn.runtime_id) runtime_id
    then Ok turn
    else
      Error
        (Not_the_assigned_runtime
           { requested = runtime_id; assigned = turn.Authz_keeper_turn.runtime_id })
;;

let admit_by_engine_name ~engine_name ~owner ~channel ~pat =
  match Atomic.get state with
  | Unpublished -> Error Not_published
  | Published (Single_user (_ : Authz_boot_mode_read.single_user)) -> Error No_operator
  | Published (Multi_account { zone; base_path = _; now }) ->
    on_trusted zone (fun trusted authz_state ->
      match Authz_keeper_state.find_by_engine_name authz_state.Authz_state.keepers engine_name with
      | None -> Error (No_operator_keeper engine_name)
      | Some (resolved_owner, keeper_id, (_ : Authz_keeper_state.keeper)) ->
        if not (Authz_types.User_id.equal resolved_owner owner)
        then Error (No_operator_keeper engine_name)
        else (
          let stored_scope = Authz_types.Authorization_scope.all in
          Authz_keeper_turn.decide
            trusted
            ~owner
            ~keeper_id
            ~channel
            ~stored_scope
            ~pat
            ~now:(now ())
          |> Result.map (fun (_ : Authz_keeper_turn.turn) -> Authz_types.Pat_binding.scope pat)
          |> Result.map_error (fun refusal -> Turn_refused refusal)))
;;

let person_keeper_of_engine_name engine_name =
  match Atomic.get state with
  | Unpublished -> Error Not_published
  | Published (Single_user (_ : Authz_boot_mode_read.single_user)) -> Error No_operator
  | Published (Multi_account { zone; base_path = _; now = _ }) ->
    on_trusted zone (fun (_ : Authz_zone.trusted) authz_state ->
      match Authz_keeper_state.find_by_engine_name authz_state.Authz_state.keepers engine_name with
      | None -> Error (No_operator_keeper engine_name)
      | Some (owner, keeper_id, (_ : Authz_keeper_state.keeper)) -> Ok (owner, keeper_id))
;;

type engine_keeper_admission =
  | Operator_mode
  | Active_person_keeper of
      { owner : Authz_types.User_id.t
      ; keeper_id : Authz_types.Keeper_id.t
      ; runtime_assigned : Authz_types.Runtime_id.t option
      }
  | Owner_disabled of
      { owner : Authz_types.User_id.t
      ; keeper_id : Authz_types.Keeper_id.t
      }
  | Unknown_person_keeper
  | Authz_uncertain

let engine_keeper_admission engine_name =
  match Atomic.get state with
  | Unpublished | Published (Single_user (_ : Authz_boot_mode_read.single_user)) ->
    Operator_mode
  | Published (Multi_account { zone; base_path = _; now = _ }) ->
    (match Authz_zone.read zone with
     | Error (_ : Authz_zone.uncertain) -> Authz_uncertain
     | Ok trusted ->
       let authz_state = (trusted :> Authz_zone.snapshot).Authz_zone.state in
       (match Authz_keeper_state.find_by_engine_name authz_state.Authz_state.keepers engine_name with
        | None -> Unknown_person_keeper
        | Some (owner, keeper_id, keeper) ->
          if Ps.is_active authz_state.Authz_state.principals owner
          then
            Active_person_keeper
              { owner
              ; keeper_id
              ; runtime_assigned = keeper.Authz_keeper_state.runtime
              }
          else Owner_disabled { owner; keeper_id }))
;;

let active_authz_keeper_names () =
  match Atomic.get state with
  | Unpublished | Published (Single_user (_ : Authz_boot_mode_read.single_user)) -> []
  | Published (Multi_account { zone; base_path = _; now = _ }) ->
    (match Authz_zone.read zone with
     | Error (_ : Authz_zone.uncertain) -> []
     | Ok trusted ->
       let authz_state = (trusted :> Authz_zone.snapshot).Authz_zone.state in
       Authz_keeper_state.all authz_state.Authz_state.keepers
       |> List.filter_map (fun (owner, (_ : Authz_types.Keeper_id.t), (keeper : Authz_keeper_state.keeper)) ->
            if Ps.is_active authz_state.Authz_state.principals owner
            then Some (Authz_types.Engine_name.to_string keeper.engine_name)
            else None)
       |> List.sort_uniq String.compare)
;;

(* The person, the turn and the home are read in the same state. *)
let multi_account ~zone ~base_path ~now request claim =
  let on_trusted judge = on_trusted zone judge in
  match request with
  | Operator_call -> Error No_operator
  | Own_account { user_id; provider_account_id } ->
    on_trusted (fun (_ : Authz_zone.trusted) state ->
      match Ps.find state.Authz_state.principals user_id with
      | Some { Ps.status = Ps.Active; _ } ->
        let ( let* ) = Result.bind in
        let* runtime_root = person_root ~base_path state user_id in
        let* () = own_home ~runtime_root provider_account_id claim in
        let* () = asks_for_nothing provider_account_id claim in
        (* What the log says of the account, as a turn reads it. The home
           is checked first, so the answer says nothing of an account
           captured from another home. *)
        let* () =
          Result.map_error
            (fun reason -> Account_unavailable { provider_account_id; reason })
            (Authz_provider_account.availability state ~user_id provider_account_id)
        in
        (* The key is checked once the account is known to be theirs. *)
        own_key ~runtime_root state provider_account_id claim
      | Some { Ps.status = Ps.Disabled; _ } | None -> Error (Not_active user_id))
  | Operator_keeper_turn { keeper_name; runtime_id = _ } -> Error (No_operator_keeper keeper_name)
  | Keeper_turn { owner; keeper_id; channel; stored_scope; pat; runtime_id } ->
    on_trusted (fun trusted state ->
      let ( let* ) = Result.bind in
      let* turn =
        decided_turn trusted ~owner ~keeper_id ~channel ~stored_scope ~pat ~runtime_id ~now
      in
      let owner = turn.Authz_keeper_turn.owner in
      let provider_account_id = turn.Authz_keeper_turn.provider_account_id in
      let* runtime_root = person_root ~base_path state owner in
      let* () = own_home ~runtime_root provider_account_id claim in
      let* () = asks_for_nothing provider_account_id claim in
      own_key ~runtime_root state provider_account_id claim)
;;

(* The Runtime of the log that [name] spells, if the log made one. A name
   that is no id names no record. *)
let off_runtime (records : Authz_state.t) name =
  match Authz_types.Runtime_id.of_string name with
  | Error (_ : Authz_id.error) -> None
  | Ok runtime_id ->
    Option.map
      (fun (_ : Authz_runtime_state.runtime) -> Off_runtime runtime_id)
      (Authz_runtime_state.find records.Authz_state.runtimes runtime_id)
;;

(* HIGH-RISK-UNREVIEWED: a single user after Off keeps the records of the
   accounts read-only and runs nothing of theirs on the authority of the
   operator (design 5.1 row 4, 10.5): no turn of their Keepers, no turn on
   their Runtimes, and no client on the homes of the persons, whichever request
   it is for. A home the environment of the process chose is the operator's. *)
let after_off ~base_path (records : Authz_state.t) request claim =
  let by_request =
    match request with
    | Operator_call -> None
    | Own_account { user_id; provider_account_id = _ } -> Some (Off_own_account user_id)
    | Keeper_turn
        { owner = _; keeper_id; channel = _; stored_scope = _; pat = _; runtime_id = _ } ->
      (* A Keeper of a person, whichever record the log holds of it. *)
      Some (Off_keeper keeper_id)
    | Operator_keeper_turn { keeper_name = _; runtime_id } ->
      (* A Keeper of the operator is no Keeper of the log, whatever its
         name: a person who made a Keeper of that name took nothing of it
         (issue #51073). What stays off is the Runtimes and the homes of the
         persons. *)
      off_runtime records runtime_id
  in
  match by_request, claim.declared_home with
  | Some refusal, (None | Some (_ : string)) -> Error refusal
  | None, None -> Ok ()
  | None, Some home ->
    if Layout.under_persons ~base_path home then Error Off_person_home else Ok ()
;;

let judge request claim =
  match Atomic.get state with
  | Unpublished -> Error Not_published
  | Published (Single_user single_user) ->
    (match Authz_boot_mode_read.turned_off single_user with
     | None -> Ok ()
     | Some records ->
       after_off
         ~base_path:(Authz_boot_mode_read.single_user_base_path single_user)
         records
         request
         claim)
  | Published (Multi_account { zone; base_path; now }) ->
    multi_account ~zone ~base_path ~now request claim
;;

(* HIGH-RISK-UNREVIEWED: the judgment of a turn that reads no account, for a
   server to refuse on before it takes the call of the account. It gives
   nothing: a client starts only on what [authorize] gives. *)
let admit request =
  match Atomic.get state, request with
  | Unpublished, (Keeper_turn _ | Operator_keeper_turn _ | Own_account _ | Operator_call) ->
    Error Not_published
  | ( Published (Multi_account { zone; base_path = _; now })
    , Keeper_turn { owner; keeper_id; channel; stored_scope; pat; runtime_id } ) ->
    on_trusted zone (fun trusted (_ : Authz_state.t) ->
      decided_turn trusted ~owner ~keeper_id ~channel ~stored_scope ~pat ~runtime_id ~now
      |> Result.map (fun (_ : Authz_keeper_turn.turn) -> ()))
  | ( Published (Multi_account { zone = _; base_path = _; now = _ })
    , (Operator_keeper_turn _ | Own_account _ | Operator_call) )
  | ( Published (Single_user (_ : Authz_boot_mode_read.single_user))
    , (Keeper_turn _ | Operator_keeper_turn _ | Own_account _ | Operator_call) ) -> Ok ()
;;

let official_claim sealed =
  { client = layout_client (Runtime_official_account.client sealed)
  ; declared_home =
      (match Runtime_official_account.source sealed with
       | Runtime_official_account.Declared_directory -> Some (Runtime_official_account.home sealed)
       | Runtime_official_account.Inherited_directory
       | Runtime_official_account.Inherited_user_home -> None)
  ; key_file = Runtime_official_account.key_file sealed
  ; asked_names = Runtime_official_account.names_asked_by_the_home sealed
  }
;;

let person_expected_home ~runtime_root provider_account_id (person : _ person_sealed) =
  match
    Layout.home
      ~runtime_root
      (layout_client person.person_client)
      ~account_id:(Authz_types.Provider_account_id.to_string provider_account_id)
  with
  | Error detail -> Error (Home_unresolved detail)
  | Ok expected ->
    if
      Authz_types.Provider_account_id.equal provider_account_id person.provider_account_id
      && String.equal expected person.account_home
    then Ok expected
    else Error (Not_the_account_home provider_account_id)
;;

let capture_person_account
    (type client)
    ~runtime_root
    ~expected_home
    ~provider_account_id
    ~(kind : Authz_provider_account_state.kind)
    (person : client person_sealed)
  : (client Runtime_official_account.t, refusal) result
  =
  let check_integration integration_id =
    if Authz_types.Integration_id.equal integration_id person.integration_id
    then Ok ()
    else
      Error
        (Not_the_account_integration
           { provider_account_id; expected = integration_id; claimed = person.integration_id })
  in
  let capture_login () =
    let ( let* ) = Result.bind in
    let* () =
      match person.person_client with
      | Runtime_official_account.Claude_code -> Ok ()
      | Runtime_official_account.Codex ->
        (match Runtime_official_account.codex_asked_names ~home:expected_home with
         | Error detail -> Error (Home_unresolved detail)
         | Ok [] -> Ok ()
         | Ok ((_ : string) :: (_ : string list)) ->
           Error (Home_asks_for_environment provider_account_id))
    in
    match
      Runtime_official_account.capture
        ~client:person.person_client
        ~declaration:(Some expected_home)
    with
    | Error detail -> Error (Home_unresolved detail)
    | Ok captured ->
      (match Runtime_official_account.names_asked_by_the_home captured with
       | [] -> Ok captured
       | (_ : string) :: (_ : string list) ->
         Error (Home_asks_for_environment provider_account_id))
  in
  let ( let* ) = Result.bind in
  match person.person_client, kind with
  | ( (Runtime_official_account.Claude_code | Runtime_official_account.Codex)
    , Authz_provider_account_state.Login { integration_id } ) ->
    let* () = check_integration integration_id in
    capture_login ()
  | ( Runtime_official_account.Codex
    , Authz_provider_account_state.Key { integration_id; generation = _ } ) ->
    let* () = check_integration integration_id in
    Error (Not_the_account_key provider_account_id)
  | ( Runtime_official_account.Claude_code
    , Authz_provider_account_state.Key { integration_id; generation } ) ->
    let* () = check_integration integration_id in
    (match Layout.key_file ~runtime_root ~account_id:provider_account_id ~generation with
     | Error detail -> Error (Home_unresolved detail)
     | Ok key_file ->
       (match
          Runtime_official_account.capture_on_key
            ~declaration:(Some expected_home)
            ~key_file
        with
        | Ok captured -> Ok captured
        | Error (Runtime_official_account.Key_not_read reason) ->
          Error (Account_key_unusable { provider_account_id; reason })
        | Error (Runtime_official_account.Key_not_captured detail) ->
          Error (Home_unresolved detail)))
;;

let authorize_person request (person : _ person_sealed) =
  match Atomic.get state with
  | Unpublished -> Error Not_published
  | Published (Single_user single_user) ->
    (match Authz_boot_mode_read.turned_off single_user with
     | Some records ->
       let claim =
         { client = layout_client person.person_client
         ; declared_home = Some person.account_home
         ; key_file = None
         ; asked_names = []
         }
       in
       (match
          after_off
            ~base_path:(Authz_boot_mode_read.single_user_base_path single_user)
            records
            request
            claim
        with
        | Error refusal -> Error refusal
        | Ok () -> Error No_operator)
     | None ->
       (match request with
        | Operator_call -> Error No_operator
        | Operator_keeper_turn { keeper_name; runtime_id = _ } ->
          Error (No_operator_keeper keeper_name)
        | Own_account { user_id; provider_account_id = _ }
        | Keeper_turn
            { owner = user_id
            ; keeper_id = _
            ; channel = _
            ; stored_scope = _
            ; pat = _
            ; runtime_id = _
            } -> Error (No_membership user_id)))
  | Published (Multi_account { zone; base_path; now }) ->
    (match request with
     | Operator_call -> Error No_operator
     | Operator_keeper_turn { keeper_name; runtime_id = _ } ->
       Error (No_operator_keeper keeper_name)
     | Own_account { user_id; provider_account_id } ->
       on_trusted zone (fun (_ : Authz_zone.trusted) state ->
         match Ps.find state.Authz_state.principals user_id with
         | Some { Ps.status = Ps.Active; _ } ->
           let ( let* ) = Result.bind in
           let* runtime_root = person_root ~base_path state user_id in
           let* expected_home = person_expected_home ~runtime_root provider_account_id person in
           let* () =
             Result.map_error
               (fun reason -> Account_unavailable { provider_account_id; reason })
               (Authz_provider_account.availability state ~user_id provider_account_id)
           in
           (match
              Authz_provider_account_state.find
                state.Authz_state.provider_accounts
                provider_account_id
            with
            | None -> Error (Not_the_account_home provider_account_id)
            | Some { Authz_provider_account_state.kind; owner = _ } ->
              capture_person_account
                ~runtime_root
                ~expected_home
                ~provider_account_id
                ~kind
                person)
         | Some { Ps.status = Ps.Disabled; _ } | None -> Error (Not_active user_id))
     | Keeper_turn { owner; keeper_id; channel; stored_scope; pat; runtime_id } ->
       on_trusted zone (fun trusted state ->
         let ( let* ) = Result.bind in
         let* turn =
           decided_turn trusted ~owner ~keeper_id ~channel ~stored_scope ~pat ~runtime_id ~now
         in
         let owner = turn.Authz_keeper_turn.owner in
         let provider_account_id = turn.Authz_keeper_turn.provider_account_id in
         let* runtime_root = person_root ~base_path state owner in
         let* expected_home = person_expected_home ~runtime_root provider_account_id person in
         match
           Authz_provider_account_state.find
             state.Authz_state.provider_accounts
             provider_account_id
         with
         | None -> Error (Not_the_account_home provider_account_id)
         | Some { Authz_provider_account_state.kind; owner = _ } ->
           capture_person_account
             ~runtime_root
             ~expected_home
             ~provider_account_id
             ~kind
             person))
;;

let authorize request = function
  | Captured sealed -> judge request (official_claim sealed) |> Result.map (fun () -> sealed)
  | Person_account person -> authorize_person request person
;;

type host_refusal =
  | Host_unpublished
  | Host_not_shared

(* HIGH-RISK-UNREVIEWED: the one decision on the accounts of the host. Phase 1
   shares them with nobody in a multi-account process, whoever asks and for
   whichever client (plans D3b and D4). *)
let host_access () =
  match Atomic.get state with
  | Unpublished -> Error Host_unpublished
  | Published (Single_user (_ : Authz_boot_mode_read.single_user)) -> Ok Shared_by_single_user
  | Published (Multi_account { zone = _; base_path = _; now = _ }) -> Error Host_not_shared
;;

let authorize_host client =
  host_access ()
  |> Result.map_error (function
    | Host_unpublished -> Not_published
    | Host_not_shared -> Host_account client)
;;

(* HIGH-RISK-UNREVIEWED: an API provider of the runtime table sends with the
   credential its operator declared, an account of the host (plan D4). A person
   API key provider sends only with that person's key file on authorized
   [Keeper_turn] or [Own_account] requests, never carrying operator
   credentials or headers from the template. *)
type api_sealed =
  | Host_api of Llm_provider.Provider_config.t
  | Person_api of
      { provider_account_id : Authz_types.Provider_account_id.t
      ; template_config : Llm_provider.Provider_config.t
      }

let seal_api config = Host_api config

let strip_api_credentials (config : Llm_provider.Provider_config.t) =
  { config with
    Llm_provider.Provider_config.api_key = Llm_provider.Secret.empty
  ; headers = []
  ; credential_source = Llm_provider.Provider_config.Static_credential
  }
;;

let seal_person_api ~provider_account_id config =
  Person_api { provider_account_id; template_config = strip_api_credentials config }
;;

let is_person_api = function
  | Host_api _ -> false
  | Person_api _ -> true
;;

let raw_api_config = function
  | Host_api config -> config
  | Person_api { provider_account_id = _; template_config } -> template_config
;;

let api_declaration (sealed : api_sealed) =
  let config = raw_api_config sealed in
  { config with Llm_provider.Provider_config.api_key = Llm_provider.Secret.empty; headers = [] }
;;

let inject_person_api_key (template_config : Llm_provider.Provider_config.t) key =
  { template_config with
    Llm_provider.Provider_config.api_key =
      Llm_provider.Secret.of_string (Runtime_api_key_file.value key)
  ; headers = Runtime_provider_binding.default_headers_for_kind template_config.kind
  ; credential_source = Llm_provider.Provider_config.Static_credential
  }
;;

(* Resolves the key path from the owner's runtime root and the current generation
   recorded in the log, and reads it via [Runtime_api_key_file.read]. Never
   exposes filesystem paths in any refusal. *)
let read_person_api_key ~base_path (state : Authz_state.t) ~owner provider_account_id =
  let ( let* ) = Result.bind in
  let* runtime_root = person_root ~base_path state owner in
  match Authz_provider_account_state.find state.Authz_state.provider_accounts provider_account_id with
  | Some
      { Authz_provider_account_state.kind =
          Authz_provider_account_state.Key { integration_id = _; generation }
      ; owner = account_owner
      }
    when Authz_types.User_id.equal account_owner owner ->
    (match Layout.key_file ~runtime_root ~account_id:provider_account_id ~generation with
     | Error detail -> Error (Home_unresolved detail)
     | Ok key_path ->
       (match Runtime_api_key_file.read key_path with
        | Ok key -> Ok key
        | Error reason -> Error (Account_key_unusable { provider_account_id; reason })))
  | None
  | Some { Authz_provider_account_state.kind = Authz_provider_account_state.Login { integration_id = _ }; owner = _ }
  | Some { Authz_provider_account_state.kind = Authz_provider_account_state.Key _; owner = _ } ->
    Error (Not_the_account_key provider_account_id)
;;

let authorize_person_api_multi ~zone ~base_path ~now ~provider_account_id request =
  let ( let* ) = Result.bind in
  match request with
  | Operator_call -> Error No_operator
  | Operator_keeper_turn { keeper_name; runtime_id = _ } -> Error (No_operator_keeper keeper_name)
  | Own_account { user_id; provider_account_id = requested_id } ->
    if not (Authz_types.Provider_account_id.equal requested_id provider_account_id)
    then Error (Not_the_account_key requested_id)
    else
      on_trusted zone (fun (_ : Authz_zone.trusted) state ->
        match Ps.find state.Authz_state.principals user_id with
        | Some { Ps.status = Ps.Active; _ } ->
          let* () =
            Result.map_error
              (fun reason -> Account_unavailable { provider_account_id; reason })
              (Authz_provider_account.availability state ~user_id provider_account_id)
          in
          read_person_api_key ~base_path state ~owner:user_id provider_account_id
        | Some { Ps.status = Ps.Disabled; _ } | None -> Error (Not_active user_id))
  | Keeper_turn { owner; keeper_id; channel; stored_scope; pat; runtime_id } ->
    on_trusted zone (fun trusted state ->
      let* turn = decided_turn trusted ~owner ~keeper_id ~channel ~stored_scope ~pat ~runtime_id ~now in
      if not (Authz_types.Provider_account_id.equal turn.Authz_keeper_turn.provider_account_id provider_account_id)
      then Error (Not_the_account_key turn.Authz_keeper_turn.provider_account_id)
      else read_person_api_key ~base_path state ~owner:turn.Authz_keeper_turn.owner provider_account_id)
;;

let authorize_person_api ~provider_account_id request =
  match Atomic.get state with
  | Unpublished -> Error Not_published
  | Published (Multi_account { zone; base_path; now }) ->
    authorize_person_api_multi ~zone ~base_path ~now ~provider_account_id request
  | Published (Single_user single_user) ->
    (match Authz_boot_mode_read.turned_off single_user with
     | Some records ->
       (match request with
        | Own_account { user_id; provider_account_id = _ } -> Error (Off_own_account user_id)
        | Keeper_turn { owner = _; keeper_id; channel = _; stored_scope = _; pat = _; runtime_id = _ } ->
          Error (Off_keeper keeper_id)
        | Operator_keeper_turn { keeper_name = _; runtime_id } ->
          (match off_runtime records runtime_id with
           | Some refusal -> Error refusal
           | None ->
             (match
                Authz_provider_account_state.find
                  records.Authz_state.provider_accounts
                  provider_account_id
              with
              | Some { owner; kind = _ } -> Error (Off_own_account owner)
              | None -> Error (Not_the_account_key provider_account_id)))
        | Operator_call ->
          (match
             Authz_provider_account_state.find
               records.Authz_state.provider_accounts
               provider_account_id
           with
           | Some { owner; kind = _ } -> Error (Off_own_account owner)
           | None -> Error No_operator))
     | None ->
       (match request with
        | Operator_call -> Error No_operator
        | Operator_keeper_turn { keeper_name; runtime_id = _ } -> Error (No_operator_keeper keeper_name)
        | Own_account { user_id; provider_account_id = _ } -> Error (Not_active user_id)
        | Keeper_turn _ -> Error (Turn_refused Authz_keeper_turn.Not_bootstrapped)))
;;

let authorize_api_for request = function
  | Host_api config ->
    authorize_host Api_provider |> Result.map (fun Shared_by_single_user -> config)
  | Person_api { provider_account_id; template_config } ->
    authorize_person_api ~provider_account_id request
    |> Result.map (inject_person_api_key template_config)
;;

let authorize_api sealed = authorize_api_for Operator_call sealed

let api_binding_identity sealed =
  Agent_core.Binding_identity.of_provider_config
    ~transport:Agent_core.Binding_identity.Http
    (raw_api_config sealed)
;;

let api_admission_allowances entries =
  Llm_provider.Provider_admission.allowances_of_configs
    (List.map (fun (id, sealed) -> id, raw_api_config sealed) entries)
;;

let api_admission_snapshot sealed =
  Llm_provider.Provider_admission.snapshot_for ~config:(raw_api_config sealed)
;;

type native_refusal =
  | Native_unpublished
  | Native_tools_reach_other_homes of Runtime_native_tools.posture
  | Native_tools_reach_person_homes of Runtime_native_tools.posture
  | Person_homes_unread of
      { posture : Runtime_native_tools.posture
      ; unread : Unix.error
      }

let native_refusal_to_string = function
  | Native_unpublished ->
    "this process has not published whether a model turn may use the native tools of its CLI"
  | Native_tools_reach_other_homes posture ->
    Printf.sprintf
      "a multi-account process runs a model turn only without native tools, and this turn \
       asks for the native posture %S: the CLI runs as the user of the server process, so \
       its own tools could read the account homes of other people. A Keeper whose client \
       supports the posture none runs here with keeper.tools.native = \"none\" in its \
       profile; a client without it runs no model turn here"
      (Runtime_native_tools.to_string posture)
  | Native_tools_reach_person_homes posture ->
    Printf.sprintf
      "this workspace keeps .masc/accounts, where the runtime roots of persons are, and a \
       model turn runs beside it only without native tools. This turn asks for the native \
       posture %S: the CLI runs as the user of the server process, so its own tools could \
       read the logins kept there. A Keeper whose client supports the posture none runs \
       with keeper.tools.native = \"none\" in its profile; the other turns run once \
       .masc/accounts is removed, which deletes the CLI logins that those persons made there"
      (Runtime_native_tools.to_string posture)
  | Person_homes_unread { posture; unread } ->
    Printf.sprintf
      "whether .masc/accounts, where the runtime roots of persons are, remains could not \
       be read (%s), so no model turn with native tools starts, and this turn asks for the \
       native posture %S"
      (Unix.error_message unread)
      (Runtime_native_tools.to_string posture)
;;

(* HIGH-RISK-UNREVIEWED: the one decision on the native tools of a model turn.
   Without them a turn reads through MASC tools only, in either mode. With them
   it reads what the user of the server process can read: in a multi-account
   process the homes of the other persons (plan D3c), and in a single-user one
   the homes that persons left under the workspace, after Off or after their
   log was removed (plan F3a-3). Whether they remain is read from the
   workspace at each start, so a removal or a first login counts at the next one. *)
let authorize_native posture =
  match Atomic.get state, posture with
  | Unpublished, (Runtime_native_tools.Native_none | Native_read | Native_full) ->
    Error Native_unpublished
  | Published (Single_user (_ : Authz_boot_mode_read.single_user)), Runtime_native_tools.Native_none
    -> Ok ()
  | Published (Single_user single_user), (Runtime_native_tools.Native_read | Native_full) ->
    (match
       Layout.persons_remain
         ~base_path:(Authz_boot_mode_read.single_user_base_path single_user)
     with
     | Ok false -> Ok ()
     | Ok true -> Error (Native_tools_reach_person_homes posture)
     | Error unread -> Error (Person_homes_unread { posture; unread }))
  | Published (Multi_account { zone = _; base_path = _; now = _ }), Runtime_native_tools.Native_none
    -> Ok ()
  | ( Published (Multi_account { zone = _; base_path = _; now = _ })
    , (Runtime_native_tools.Native_read | Native_full) ) ->
    Error (Native_tools_reach_other_homes posture)
;;

let person_homes_notice = function
  | Ok false -> None
  | Ok true ->
    Some
      "this workspace keeps .masc/accounts, where the runtime roots of persons are. A model \
       turn that uses the native tools of its CLI is refused while it is there: the CLI runs \
       as the user of the server process, so its own tools could read the logins kept there. \
       A Keeper whose client supports the posture none runs with keeper.tools.native = \
       \"none\" in its profile; the other turns run once .masc/accounts is removed, which \
       deletes the CLI logins that those persons made there"
  | Error unread ->
    Some
      (Printf.sprintf
         "whether .masc/accounts, where the runtime roots of persons are, remains could not be \
          read (%s), so no model turn that uses the native tools of its CLI starts"
         (Unix.error_message unread))
;;

(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Ps = Authz_principal_state
module Layout = Runtime_account_home_layout

type 'client sealed = 'client Runtime_official_account.t
type 'client authorized = 'client Runtime_official_account.t

let seal account = account
let home sealed = Runtime_official_account.home sealed
let same left right = Runtime_official_account.same left right
let account authorized = authorized

type muse_home = string

let declare_muse_home home = Runtime_account_home.of_string home
let muse_home_path home = home

(* A constructor for each kind: with these, OCaml 5.5.1 refutes the other kind
   in a match on a declared account, and with empty types it did not. *)
type declared = Declared_kind
type process_environment = Process_environment_kind

type _ muse_account =
  | Declared_home : muse_home -> declared muse_account
  | Process_environment : process_environment muse_account

type 'where muse_authorized = 'where muse_account

let muse_account_home (type where) (authorized : where muse_authorized) =
  match authorized with
  | Declared_home home -> Some home
  | Process_environment -> None
;;

let declared_muse_home (authorized : declared muse_authorized) =
  match authorized with
  | Declared_home home -> home
;;

type host_client =
  | Antigravity
  | Vibe
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
  | Vibe -> "Vibe"
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

let publish access =
  let observed = Atomic.get state in
  match observed with
  | Published (_ : t) -> Error Already_published
  | Unpublished ->
    (* A failed exchange means another call published in between. *)
    if Atomic.compare_and_set state observed (Published access)
    then Ok ()
    else Error Already_published
;;

let publish_host_tool ~base_path ~config_dir =
  match Authz_boot_mode_read.tool ~base_path ~config_dir with
  | Error _ as refused -> refused
  | Ok single_user ->
    publish (Single_user single_user)
    |> Result.map_error (fun error -> publish_error_to_string error, [])
;;

type request =
  | Keeper_turn of
      { owner : Authz_types.User_id.t
      ; keeper_id : Authz_types.Keeper_id.t
      ; channel : Authz_types.Channel.t
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
    "the account was captured from an inherited home, or a Muse process would start on \
     the environment of the process"
  | Not_the_account_home provider_account_id ->
    Printf.sprintf
      "the account was captured from another home than the one of %s"
      (Authz_types.Provider_account_id.to_string provider_account_id)
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
  | Host_account ((Antigravity | Vibe) as client) ->
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
   keeps the home, and the home when a declaration chose it. [None] is a home
   the environment of the process chose. *)
type claim =
  { client : Layout.client
  ; declared_home : string option
  }

(* The home of [provider_account_id] under the namespace of [user_id] is the
   one home a CLI for that person starts on. *)
let own_home ~base_path (state : Authz_state.t) user_id provider_account_id claim =
  match Ps.find_membership state.Authz_state.principals user_id with
  | None -> Error (No_membership user_id)
  | Some membership ->
    let runtime_root =
      Layout.person_runtime_root ~base_path ~namespace:membership.Ps.account_home_namespace
    in
    (match
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
          else Error (Not_the_account_home provider_account_id)))
;;

(* One request is judged on one snapshot, and only on one the zone could be
   trusted for: the person, the turn and the home are read in the same state. *)
let multi_account ~zone ~base_path ~now request claim =
  let on_trusted judge =
    match Authz_zone.read zone with
    | Error uncertain -> Error (Zone_uncertain uncertain)
    | Ok trusted -> judge trusted (trusted :> Authz_zone.snapshot).Authz_zone.state
  in
  match request with
  | Operator_call -> Error No_operator
  | Own_account { user_id; provider_account_id } ->
    on_trusted (fun (_ : Authz_zone.trusted) state ->
      match Ps.find state.Authz_state.principals user_id with
      | Some { Ps.status = Ps.Active; _ } -> own_home ~base_path state user_id provider_account_id claim
      | Some { Ps.status = Ps.Disabled; _ } | None -> Error (Not_active user_id))
  | Operator_keeper_turn { keeper_name; runtime_id = _ } -> Error (No_operator_keeper keeper_name)
  | Keeper_turn { owner; keeper_id; channel; pat; runtime_id } ->
    on_trusted (fun trusted state ->
      match Authz_keeper_turn.decide trusted ~owner ~keeper_id ~channel ~pat ~now:(now ()) with
      | Error refusal -> Error (Turn_refused refusal)
      | Ok turn ->
        if String.equal (Authz_types.Runtime_id.to_string turn.Authz_keeper_turn.runtime_id) runtime_id
        then
          own_home
            ~base_path
            state
            turn.Authz_keeper_turn.owner
            turn.Authz_keeper_turn.provider_account_id
            claim
        else
          Error
            (Not_the_assigned_runtime
               { requested = runtime_id; assigned = turn.Authz_keeper_turn.runtime_id }))
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
    | Keeper_turn { owner = _; keeper_id; channel = _; pat = _; runtime_id = _ } ->
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

let official_claim sealed =
  { client = layout_client (Runtime_official_account.client sealed)
  ; declared_home =
      (match Runtime_official_account.source sealed with
       | Runtime_official_account.Declared_directory -> Some (Runtime_official_account.home sealed)
       | Runtime_official_account.Inherited_directory
       | Runtime_official_account.Inherited_user_home -> None)
  }
;;

let authorize request sealed =
  judge request (official_claim sealed) |> Result.map (fun () -> sealed)
;;

let authorize_muse request account =
  judge request { client = Layout.Muse_home; declared_home = muse_account_home account }
  |> Result.map (fun () -> account)
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
   credential its operator declared, an account of the host (plan D4). The
   whole config leaves the seal only through [authorize_api]; a reader gets
   [api_declaration], without the key and the headers. *)
type api_sealed = Llm_provider.Provider_config.t

let seal_api config = config

let api_declaration (config : api_sealed) =
  { config with Llm_provider.Provider_config.api_key = Llm_provider.Secret.empty; headers = [] }
;;

let authorize_api config =
  authorize_host Api_provider |> Result.map (fun Shared_by_single_user -> config)
;;

let api_binding_identity config =
  Agent_core.Binding_identity.of_provider_config ~transport:Agent_core.Binding_identity.Http config
;;

let api_admission_allowances entries = Llm_provider.Provider_admission.allowances_of_configs entries
let api_admission_snapshot config = Llm_provider.Provider_admission.snapshot_for ~config

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

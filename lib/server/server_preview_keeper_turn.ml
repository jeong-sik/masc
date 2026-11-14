(* HIGH-RISK-UNREVIEWED: see the interface. *)

module R = Login_routes
module Ks = Authz_keeper_state
module Login = Server_setup_account_login
module Conversation = Server_keeper_conversation
module E = Server_preview_keeper_error

let ( let* ) = Result.bind
let max_message_bytes = 4096
let turn_timeout_s = 120.0
let ms_per_second = 1000.
let shape = {|The body is {"keeper_id": "<name>", "message": "<text>"}.|}
let unexpected_refusal = "The turn was refused for a reason this preview does not expect."

let request_of body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error (_ : string) -> Error (E.Invalid_request shape)
  | `Assoc ([ _; _ ] as fields) ->
    (* Exactly these two named fields: duplicates cannot replace a missing
       field, and additional fields are refused before starting a turn. *)
    (match List.assoc_opt "keeper_id" fields, List.assoc_opt "message" fields with
     | Some (`String name), Some (`String message) ->
       if String.length message > max_message_bytes
       then Error (E.Message_too_long { max_bytes = max_message_bytes })
       else if String.equal (String.trim message) ""
       then Error E.Message_blank
       else Ok (name, message)
     | _ -> Error (E.Invalid_request shape))
  | _ -> Error (E.Invalid_request shape)
;;

let keeper_id_of name =
  Auth_preview_keeper.keeper_id_of name |> Result.map_error (fun sentence -> E.Invalid_request sentence)
;;

(* The Keeper of the person and the Runtime they gave it, with the state it
   was read in, which the zone can be trusted for. A Keeper of another person
   is answered as one that is not there, as the other Keeper routes answer
   it. *)
let owned_in (person : Login.person) keeper_id =
  match Authz_zone.read person.zone with
  | Error uncertain -> Error (E.Server_unavailable (R.zone_uncertain_message uncertain))
  | Ok trusted ->
    let state = (trusted :> Authz_zone.snapshot).Authz_zone.state in
    (match Ks.find state.Authz_state.keepers ~owner:person.user_id keeper_id with
     | Some { Ks.runtime; owner = _; policy_id = _; turn_scope = _ } -> Ok (state, runtime)
     | None -> Error E.Unknown_keeper)
;;

let owned person keeper_id =
  Result.map (fun ((_ : Authz_state.t), runtime) -> runtime) (owned_in person keeper_id)
;;

(* The Runtime the person gave the Keeper, and the account that Runtime
   spends. *)
let assigned person keeper_id =
  let* state, runtime = owned_in person keeper_id in
  match runtime with
  | None -> Error E.Keeper_has_no_runtime
  | Some runtime_id ->
    (match Authz_runtime_state.find state.Authz_state.runtimes runtime_id with
     | Some { Authz_runtime_state.provider_account_id; owner = _; self_grant = _; self_effects = _ }
       -> Ok (runtime_id, provider_account_id)
     | None ->
       (* The log gives a Keeper only a Runtime it made, and a Runtime it made
          stays. *)
       Log.Server.warn
         "Keeper %s has the Runtime %s, which the log does not have"
         (Authz_types.Keeper_id.to_string keeper_id)
         (Authz_types.Runtime_id.to_string runtime_id);
       Error (E.Internal "The Runtime of this Keeper is not in the log."))
;;

let login_error (status, sentence) =
  match status with
  | `Bad_request -> E.Account_runtime_invalid sentence
  | `Not_found -> E.Unknown_account sentence
  | `Service_unavailable -> E.Server_unavailable sentence
;;

let refusal_error (refusal : Runtime_account_access.refusal) =
  let text = Runtime_account_access.refusal_to_string refusal in
  match refusal with
  | Runtime_account_access.Turn_refused (Authz_keeper_turn.Denied _)
  | Runtime_account_access.Not_active _
  | Runtime_account_access.Not_the_account_home _ -> E.Turn_refused text
  | Runtime_account_access.Not_the_assigned_runtime _
  | Runtime_account_access.Turn_refused (Authz_keeper_turn.No_authorized_runtime _) ->
    (* The owner gave the Keeper another Runtime after the route read it. *)
    E.Runtime_reassigned text
  | Runtime_account_access.Turn_refused (Authz_keeper_turn.Keeper_not_made _) -> E.Unknown_keeper
  | Runtime_account_access.Zone_uncertain uncertain ->
    (* The zone stopped, or its files came to disagree, after the route read
       the Keeper. *)
    E.Server_unavailable (R.zone_uncertain_message uncertain)
  | Runtime_account_access.Home_unresolved _ ->
    (* The reason can name a path of the server (issue #50018). *)
    Log.Server.warn "A Keeper turn was refused: %s" text;
    E.Server_unavailable "The home of the account could not be spelled."
  | Runtime_account_access.Not_published
  | Runtime_account_access.No_operator
  | Runtime_account_access.No_operator_keeper _
  | Runtime_account_access.No_membership _
  | Runtime_account_access.Not_a_declared_home
  | Runtime_account_access.Host_account _
  | Runtime_account_access.Off_keeper _
  | Runtime_account_access.Off_runtime _
  | Runtime_account_access.Off_person_home
  | Runtime_account_access.Off_own_account _
  | Runtime_account_access.Turn_refused Authz_keeper_turn.Not_bootstrapped ->
    (* The preview publishes its access before it listens, a turn is no
       operator call and no turn of an operator Keeper, an admission
       makes the membership, the runtime declares its home, the preview
       starts no host client, its access is multi-account and not a single
       user after Off, and the zone opened on a bootstrapped log. *)
    Log.Server.warn "A Keeper turn was refused: %s" text;
    E.Internal unexpected_refusal
;;

(* The detail of a failure can name a path of the server (issue #50018), so
   it goes to the log and the answer is one of the fixed sentences. *)
let logged ~keeper_id detail =
  Log.Server.warn "Keeper %s turn failed: %s" (Authz_types.Keeper_id.to_string keeper_id) detail
;;

let claude_failure : Runtime_claude_code.error -> Conversation.failure = function
  | Runtime_claude_code.Subscription_required _ -> Conversation.Not_signed_in
  | Runtime_claude_code.Quota_blocked _ -> Conversation.No_quota
  | Runtime_claude_code.Timeout _ -> Conversation.Silent
  | Runtime_claude_code.Spawn_failed _ -> Conversation.Not_started
  | Runtime_claude_code.Invalid_config _ -> Conversation.Configuration_refused
  | Runtime_claude_code.Turn_failed_with_observation _
  | Runtime_claude_code.Protocol_error _
  | Runtime_claude_code.Unsupported_control_request _
  | Runtime_claude_code.Turn_transport_interrupted _
  | Runtime_claude_code.Context_window_exceeded _
  | Runtime_claude_code.Turn_failed _
  | Runtime_claude_code.Stopped_by_host _
  | Runtime_claude_code.Process_exited _
  | Runtime_claude_code.Unhandled_exception _ -> Conversation.No_answer
;;

(* The detail of a record failure can name a path of the server, so it goes
   to the log as the detail of a client failure does. *)
let record_error ~keeper_id (failure : Conversation.error) =
  logged ~keeper_id (Conversation.error_to_string failure);
  E.of_record_error failure
;;

(* A spent subscription reaches Codex as a refused turn that names
   usageLimitExceeded or sessionBudgetExceeded, so it is read before the
   kind of the failure. *)
let codex_failure (failure : Runtime_codex_app_server.error) : Conversation.failure =
  if Runtime_codex_app_server.refused_for_spent_usage failure
  then Conversation.No_quota
  else (
    match failure with
    | Runtime_codex_app_server.Subscription_required _ -> Conversation.Not_signed_in
    | Runtime_codex_app_server.Timeout _ -> Conversation.Silent
    | Runtime_codex_app_server.Spawn_failed _ -> Conversation.Not_started
    | Runtime_codex_app_server.Invalid_config _ -> Conversation.Configuration_refused
    | Runtime_codex_app_server.Reasoning_effort_admission_failed _
    | Runtime_codex_app_server.Turn_input_write_failed _
    | Runtime_codex_app_server.Protocol_error _
    | Runtime_codex_app_server.Rpc_error _
    | Runtime_codex_app_server.Account_read_failed _
    | Runtime_codex_app_server.Unsupported_server_request _
    | Runtime_codex_app_server.Context_window_exceeded _
    | Runtime_codex_app_server.Turn_failed _
    | Runtime_codex_app_server.Stopped_by_host _
    | Runtime_codex_app_server.Turn_interrupted
    | Runtime_codex_app_server.Runtime_shutting_down
    | Runtime_codex_app_server.Process_exited _ -> Conversation.No_answer)
;;

let client_mgr clock =
  Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds:Process_eio.child_exit_grace_seconds
;;

(* macOS TMPDIR sits under the /var -> /private/var symlink, and the client
   gets the real path as its directory, as a verification does. The
   directory is removed after the turn. *)
let in_private_dir ~env turn =
  match Filename.temp_dir "masc-keeper-turn-" "" |> Unix.realpath with
  | exception (Unix.Unix_error _ | Sys_error _) ->
    Error (E.Server_unavailable "The private turn directory could not be made.")
  | private_dir ->
    Eio.Switch.run (fun sw ->
      Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree private_dir);
      let clock = Eio.Stdenv.clock env in
      turn ~mgr:(client_mgr clock) ~clock ~cwd:Eio.Path.(Eio.Stdenv.fs env / private_dir))
;;

(* A multi-account process runs a model turn only without native tools (plan
   D3c), so the posture is judged before the client starts. The refusal names
   no path, so the answer carries it. *)
let native_error posture =
  match Runtime_account_access.authorize_native posture with
  | Ok () -> Ok ()
  | Error (Runtime_account_access.Native_tools_reach_other_homes _ as refusal) ->
    Error (E.Native_tools_refused (Runtime_account_access.native_refusal_to_string refusal))
  | Error
      (( Runtime_account_access.Native_unpublished
       | Runtime_account_access.Native_tools_reach_person_homes _
       | Runtime_account_access.Person_homes_unread _ ) as refusal) ->
    (* The preview publishes its access before it listens, and it is a
       multi-account process: the two refusals of a single user do not occur. *)
    Log.Server.warn
      "A Keeper turn was refused: %s"
      (Runtime_account_access.native_refusal_to_string refusal);
    Error (E.Internal unexpected_refusal)
;;

type answered =
  { model : string
  ; text : string
  ; conversation : (Conversation.Conversation_id.t * bool) option
      (** The conversation of the turn, and whether the turn resumed the
          vendor session of it. A Codex turn has none. *)
  }

(* The turn of a conversation (plan S1b-3). The conversation of the Keeper is
   found or started, and it stays on the account it began on: the vendor
   session lies in the home of that account. The client starts in the
   directory of the conversation and resumes the session of its last answered
   turn. The [asked] row is written before the client starts, and the turn
   ends in an [answered] or a [failed] row.

   A conversation the person began to delete is not the current one, so the
   turn starts another (plan S1b-3c). The turn runs inside the call of its
   account, and so does a deletion of a conversation that began on it, so a
   deletion does not begin between this judgment and the end of the turn. *)
let call_claude
      ~env
      ~keeper_id
      ~(execution : Runtime_execution.claude_code)
      ~account
      ~records
      ~deleted
      ~provider_account_id
      ~message
  =
  let clock = Eio.Stdenv.clock env in
  let now_ms () = Int.of_float (Eio.Time.now clock *. ms_per_second) in
  let draw = Auth.generate_token in
  let recorded result = Result.map_error (record_error ~keeper_id) result in
  let* conversation =
    Conversation.current_or_start records keeper_id provider_account_id ~deleted ~draw ~now_ms
    |> recorded
  in
  let* () =
    if
      Authz_types.Provider_account_id.equal
        conversation.Conversation.provider_account_id
        provider_account_id
    then Ok ()
    else Error E.Conversation_on_other_subscription
  in
  let* turn = Conversation.open_turn records conversation |> recorded in
  let cwd = Conversation.cwd turn in
  let config =
    { (Runtime_claude_code.default_config ~cwd) with
      cli_path = execution.cli_path
    ; model = execution.model
    ; admission_timeout_s = Float.min turn_timeout_s execution.timeout_s
    ; timeout_s = Some turn_timeout_s
    }
  in
  let* () = native_error config.native in
  let session_mode =
    match Conversation.session_id turn with
    | None -> Runtime_claude_code.Start
    | Some session_id -> Runtime_claude_code.Resume { session_id }
  in
  let* asked = Conversation.ask turn ~message ~draw ~now_ms |> recorded in
  match
    Runtime_claude_code.run_turn
      ~mgr:(client_mgr clock)
      ~clock
      ~cwd:Eio.Path.(Eio.Stdenv.fs env / cwd)
      ~account
      ~session_mode
      config
      ~prompt:message
      ~images:[]
  with
  | Ok (answer : Runtime_claude_code.turn_result) ->
    (* The next turn resumes the session this row names, so an answer that is
       not recorded is not given as the answer of the conversation. *)
    (match
       Conversation.answered
         asked
         ~text:answer.text
         ~model:answer.model
         ~session_id:answer.session_id
         ~now_ms
     with
     | Ok () ->
       Ok
         { model = answer.model
         ; text = answer.text
         ; conversation = Some (conversation.Conversation.conversation_id, answer.resumed)
         }
     | Error failure ->
       logged ~keeper_id (Conversation.error_to_string failure);
       Error E.Answer_unrecorded)
  | Error failure ->
    logged ~keeper_id (Runtime_claude_code.error_to_string failure);
    let kind = claude_failure failure in
    (* A [failed] row that is not written leaves the turn with its [asked]
       row alone, which reads as a turn with no recorded answer. *)
    (match Conversation.failed asked kind ~now_ms with
     | Ok () -> ()
     | Error failure -> logged ~keeper_id (Conversation.error_to_string failure));
    Error (E.of_failure kind ~silent_after_s:turn_timeout_s ~in_conversation:true)
;;

(* An ephemeral thread: Codex writes no rollout and no history for it, as
   the turn writes nothing to the log. The posture is the default of the
   client, its least one (Native_read): Codex has no Native_none, so the
   multi-account preview refuses the turn before Codex starts (plan D3c). *)
let call_codex
      ~env
      ~keeper_id
      ~runtime
      ~(execution : Runtime_execution.codex_app_server)
      ~account
      ~message
  =
  in_private_dir ~env (fun ~mgr ~clock ~cwd ->
    let config =
      { (Runtime_codex_app_server.default_config ()) with
        cli_path = execution.cli_path
      ; model = execution.model
      ; context_window = Some (Runtime_instance.max_context_of_runtime runtime)
      ; admission_timeout_s = Float.min turn_timeout_s execution.timeout_s
      ; timeout_s = Some turn_timeout_s
      }
    in
    let* () = native_error config.native in
    Runtime_codex_app_server.run_turn
      ~thread:Runtime_codex_app_server.Ephemeral
      ~mgr
      ~clock
      ~cwd
      ~account
      config
      ~prompt:message
      ~images:[]
    |> Result.map (fun (turn : Runtime_codex_app_server.turn_result) ->
      { model = turn.model; text = turn.text; conversation = None })
    |> Result.map_error (fun failure ->
      logged ~keeper_id (Runtime_codex_app_server.error_to_string failure);
      E.of_failure (codex_failure failure) ~silent_after_s:turn_timeout_s ~in_conversation:false))
;;

let run ~env ~(person : Login.person) ~pat ~base_path ~body =
  let answer =
    let* name, message = request_of body in
    let* keeper_id = keeper_id_of name in
    let* runtime_id, provider_account_id = assigned person keeper_id in
    (* The binding is chosen by the Runtime id, so [prepared.runtime_id] is
       [runtime_id]. *)
    let* prepared =
      Login.person_runtime
        person
        ~base_path
        ~provider_account_id
        ~binding:(Runtime_account_runtime.Runtime (Authz_types.Runtime_id.to_string runtime_id))
      |> Result.map_error login_error
    in
    let request =
      Runtime_account_access.Keeper_turn
        { owner = person.user_id
        ; keeper_id
        ; channel = Authz_types.Channel.Direct
        ; pat
        ; runtime_id = Authz_types.Runtime_id.to_string prepared.Login.runtime_id
        }
    in
    let authorize account =
      Runtime_account_access.authorize request account |> Result.map_error refusal_error
    in
    let one_call turn =
      Login.one_call_of provider_account_id ~busy:(E.Account_call_running E.Runtime_account) turn
    in
    let* { model; text; conversation } =
      match prepared.Login.runtime.Runtime_instance.execution with
      | Runtime_execution.Claude_code execution ->
        let* account = authorize execution.account_home in
        one_call (fun () ->
          call_claude
            ~env
            ~keeper_id
            ~execution
            ~account
            ~records:(Conversation.root ~base_path ~namespace:person.namespace)
            ~deleted:(Server_keeper_conversation_purge.deletion_began person)
            ~provider_account_id
            ~message)
      | Runtime_execution.Codex_app_server execution ->
        let* account = authorize execution.account_home in
        one_call (fun () ->
          call_codex ~env ~keeper_id ~runtime:prepared.Login.runtime ~execution ~account ~message)
      | Runtime_execution.Antigravity_cli _
      | Runtime_execution.Muse_serve _
      | Runtime_execution.Vibe_cli _
      | Runtime_execution.Agent_core _ -> Error E.Runtime_not_supported
    in
    Ok
      (R.json
         R.Ok_200
         ([ "keeper_id", `String (Authz_types.Keeper_id.to_string keeper_id)
          ; "runtime_id", `String (Authz_types.Runtime_id.to_string prepared.Login.runtime_id)
          ; "model", `String model
          ; "text", `String text
          ]
          @
          match conversation with
          | Some (conversation_id, continued) ->
            [ ( "conversation_id"
              , `String (Conversation.Conversation_id.to_string conversation_id) )
            ; "continued", `Bool continued
            ]
          | None -> []))
  in
  Result.fold ~ok:Fun.id ~error:E.answer answer
;;

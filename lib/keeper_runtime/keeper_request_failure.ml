module Failure_kind = struct
  type t =
    | Not_signed_in
    | Key_refused
    | Key_unusable
    | No_quota
    | Silent
    | Not_started
    | Configuration_refused
    | Turn_refused
    | Runtime_reassigned
    | Server_unavailable
    | Cancelled
    | No_visible_reply
    | No_answer

  let all =
    [ Not_signed_in
    ; Key_refused
    ; Key_unusable
    ; No_quota
    ; Silent
    ; Not_started
    ; Configuration_refused
    ; Turn_refused
    ; Runtime_reassigned
    ; Server_unavailable
    ; Cancelled
    ; No_visible_reply
    ; No_answer
    ]
  ;;

  let equal left right = left = right

  let to_wire = function
    | Not_signed_in -> "not_signed_in"
    | Key_refused -> "key_refused"
    | Key_unusable -> "key_unusable"
    | No_quota -> "no_quota"
    | Silent -> "silent"
    | Not_started -> "not_started"
    | Configuration_refused -> "configuration_refused"
    | Turn_refused -> "turn_refused"
    | Runtime_reassigned -> "runtime_reassigned"
    | Server_unavailable -> "server_unavailable"
    | Cancelled -> "cancelled"
    | No_visible_reply -> "no_visible_reply"
    | No_answer -> "no_answer"
  ;;

  let of_wire raw =
    List.find_opt (fun item -> String.equal (to_wire item) raw) all
  ;;
end

type turn_resource =
  | Registry_entry_missing
  | Registry_entry_unhealthy

type continuation_stage =
  | Continuation_load
  | Gate_suspend
  | Runtime_continuation_defer
  | Checkpoint_retain

type reply_contract_field =
  | Reply_payload
  | Turn_outcome
  | Turn_ref
  | External_effect_target

type visible_reply_stage =
  | Terminal_projection
  | Queued_delivery

type failure_site =
  | Stream_dispatch
  | Stream_streaming_call
  | Stream_turn_body
  | Stream_submit

type cause =
  | Core of Keeper_request_failure_core.t
  | Masc of Keeper_internal_error.masc_internal_error
  | Account_refused of Keeper_account_refusal.t
  | Provider_auth_required of
      { provider : string option
      ; detail : string
      }
  | Provider_key_refused of
      { provider : string
      ; detail : string
      }
  | Provider_quota_exhausted of
      { provider : string option
      ; retry_after : float option
      ; detail : string
      }
  | Provider_spawn_refused of
      { provider : string
      ; detail : string
      }
  | Provider_timeout of
      { provider : string option
      ; phase : string option
      ; detail : string
      }
  | Configuration_refused of
      { field : string
      ; detail : string
      }
  | Provider_network of
      { provider : string option
      ; kind : Llm_provider.Http_client.network_error_kind
      ; detail : string
      }
  | Provider_connect_failed of
      { provider : string option
      ; kind : Llm_provider.Http_client.network_error_kind
      ; detail : string
      }
  | Provider_rate_limited of
      { provider : string option
      ; retry_after : float option
      ; detail : string
      }
  | Context_overflow of { limit : int option }
  | Input_capacity
  | Operator_cancelled
  | Server_not_initialized
  | Server_restarted
  | Dispatch_unavailable
  | Keeper_meta_unresolved of
      { keeper : string
      ; detail : string
      }
  | Keeper_not_registered of { keeper : string }
  | Invocation_rejected of { detail : string }
  | Chat_identity_mismatch
  | Turn_resources_unavailable of
      { resource : turn_resource
      ; detail : string
      }
  | Runtime_selection_failed of { detail : string }
  | Turn_continuation_unpersisted of
      { stage : continuation_stage
      ; detail : string
      }
  | User_row_unpersisted of { detail : string }
  | Gate_session_full of
      { approval_id : string
      ; runtime_id : string
      ; session_id : string
      ; recovery_id : string
      ; activity : Keeper_internal_error.vendor_session_activity
      }
  | Reply_contract_rejected of
      { field : reply_contract_field
      ; detail : string
      }
  | No_visible_reply of
      { stage : visible_reply_stage
      ; had_blocks : bool
      }
  | Raised of
      { site : failure_site
      ; exn : string
      }

type t = { cause : cause }

(* ------------------------------------------------------------------ *)
(* Projection from agent-core                                          *)
(* ------------------------------------------------------------------ *)

(* Everything RFC-0454 §2.2's table has not named yet. A MASC error travels
   agent-core's carrier, so it is lifted back to the value it is before the
   residual projection sees it. *)
let unnamed_core_cause error =
  match Keeper_account_refusal.of_core_error error with
  | Some refusal -> Account_refused refusal
  | None ->
    (match Keeper_provider_refusal.of_core_error error with
     | Some (Keeper_provider_refusal.Key_refused { provider; detail }) ->
       Provider_key_refused { provider; detail }
     | Some (Keeper_provider_refusal.Spawn_refused { provider; detail }) ->
       Provider_spawn_refused { provider; detail }
     | None ->
       (match Keeper_internal_error.classify_masc_internal_error error with
        | Some masc_error -> Masc masc_error
        | None -> Core (Keeper_request_failure_core.of_core_error error)))
;;

let cause_of_core_error (error : Agent_core.Error.t) =
  match error with
  | Agent_core.Error.Api (Agent_core.Retry.NetworkError { message; kind }) ->
    Provider_network { provider = None; kind; detail = message }
  | Agent_core.Error.Api (Agent_core.Retry.Connect_failed { message; kind }) ->
    Provider_connect_failed { provider = None; kind; detail = message }
  | Agent_core.Error.Api (Agent_core.Retry.RateLimited { message; retry_after }) ->
    Provider_rate_limited { provider = None; retry_after; detail = message }
  | Agent_core.Error.Api (Agent_core.Retry.PaymentRequired { message }) ->
    Provider_quota_exhausted { provider = None; retry_after = None; detail = message }
  | Agent_core.Error.Api (Agent_core.Retry.AuthError { message })
  | Agent_core.Error.Api (Agent_core.Retry.AuthorizationError { message }) ->
    Provider_auth_required { provider = None; detail = message }
  | Agent_core.Error.Api (Agent_core.Retry.Timeout { message; phase }) ->
    Provider_timeout
      { provider = None
      ; phase = Option.map Llm_provider.Http_client.timeout_phase_to_label phase
      ; detail = message
      }
  | Agent_core.Error.Api (Agent_core.Retry.ContextOverflow { limit; _ }) ->
    Context_overflow { limit }
  | Agent_core.Error.Api (Agent_core.Retry.InputCapacity _) -> Input_capacity
  | Agent_core.Error.Api (Agent_core.Retry.Overloaded _)
  | Agent_core.Error.Api (Agent_core.Retry.ServerError _)
  | Agent_core.Error.Api (Agent_core.Retry.InvalidRequest _)
  | Agent_core.Error.Api (Agent_core.Retry.NotFound _) -> unnamed_core_cause error
  | Agent_core.Error.Provider
      (Llm_provider.Error.NetworkError { provider; kind = _; timeout_phase = Some phase; detail })
    ->
    Provider_timeout
      { provider = Some provider
      ; phase = Some (Llm_provider.Http_client.timeout_phase_to_label phase)
      ; detail
      }
  | Agent_core.Error.Provider
      (Llm_provider.Error.NetworkError { provider; kind; timeout_phase = None; detail }) ->
    Provider_network { provider = Some provider; kind; detail }
  | Agent_core.Error.Provider (Llm_provider.Error.Connect_failed { provider; kind; detail })
    -> Provider_connect_failed { provider = Some provider; kind; detail }
  | Agent_core.Error.Provider
      (Llm_provider.Error.RateLimit { provider; retry_after; detail }) ->
    Provider_rate_limited { provider = Some provider; retry_after; detail }
  | Agent_core.Error.Provider
      (Llm_provider.Error.HardQuota { provider; retry_after; detail }) ->
    Provider_quota_exhausted { provider = Some provider; retry_after; detail }
  | Agent_core.Error.Provider (Llm_provider.Error.AuthError { provider; detail })
  | Agent_core.Error.Provider (Llm_provider.Error.AuthorizationError { provider; detail }) ->
    Provider_auth_required { provider = Some provider; detail }
  | Agent_core.Error.Provider (Llm_provider.Error.Timeout { provider; timeout_phase; detail }) ->
    Provider_timeout
      { provider = Some provider
      ; phase = Option.map Llm_provider.Http_client.timeout_phase_to_label timeout_phase
      ; detail
      }
  | Agent_core.Error.Provider (Llm_provider.Error.InvalidConfig { field; detail }) ->
    Configuration_refused { field; detail }
  | Agent_core.Error.Provider
      ( Llm_provider.Error.ParseError _
      | Llm_provider.Error.ProviderWireError _
      | Llm_provider.Error.ProviderReportedError _
      | Llm_provider.Error.UnknownVariant _
      | Llm_provider.Error.ProviderUnavailable _
      | Llm_provider.Error.EmptyCompletion _
      | Llm_provider.Error.CapacityExhausted _
      | Llm_provider.Error.ServerError _
      | Llm_provider.Error.InvalidRequest _
      | Llm_provider.Error.NotFound _
      | Llm_provider.Error.ProviderTerminal _ ) -> unnamed_core_cause error
  | Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; detail }) ->
    Configuration_refused { field; detail }
  | Agent_core.Error.Config (Agent_core.Error.MissingEnvVar { var_name }) ->
    Configuration_refused
      { field = "env"; detail = "missing required environment variable " ^ var_name }
  | Agent_core.Error.Config (Agent_core.Error.UnsupportedProvider { detail }) ->
    Configuration_refused { field = "provider"; detail }
  | Agent_core.Error.Config (Agent_core.Error.CredentialUnavailable { provider_id; carrier = _ }) ->
    Configuration_refused
      { field = "credentials"; detail = "credentials unavailable for provider " ^ provider_id }
  | Agent_core.Error.Config (Agent_core.Error.SensitiveValueInConfig { detail }) ->
    Configuration_refused { field = "config"; detail }
  | Agent_core.Error.Agent _
  | Agent_core.Error.Mcp _
  | Agent_core.Error.Serialization _
  | Agent_core.Error.Io _
  | Agent_core.Error.Orchestration _ | Agent_core.Error.Media _
  | Agent_core.Error.Internal _
  | Agent_core.Error.Internal_carried _ -> unnamed_core_cause error
;;

let of_core_error error = { cause = cause_of_core_error error }

(* ------------------------------------------------------------------ *)
(* Summary                                                             *)
(* ------------------------------------------------------------------ *)

(* A leaf message is its producer's own text and may span lines; the summary
   is one line. *)
let one_line text = String.map (function '\n' | '\r' -> ' ' | c -> c) text

let server_path_prefixes =
  [ "/Users/"
  ; "/home/"
  ; "/tmp/"
  ; "/private/"
  ; "/var/"
  ; "/etc/"
  ; "/opt/"
  ; "/srv/"
  ; "/mnt/"
  ; "/root/"
  ; "/usr/"
  ; "/System/"
  ; "/Library/"
  ; "/Volumes/"
  ]
;;

let is_path_delimiter = function
  | ' ' | '\t' | '\n' | '\r' | '"' | '\'' | '`' | '(' | ')' | '[' | ']'
  | '{' | '}' | '<' | '>' | ',' | ';' -> true
  | _ -> false
;;

let is_ascii_alpha = function
  | 'a' .. 'z' | 'A' .. 'Z' -> true
  | _ -> false
;;

let matches_at text idx prefix =
  let plen = String.length prefix in
  idx + plen <= String.length text
  && String.sub text idx plen = prefix
;;

let is_token_boundary text idx =
  if idx = 0
  then true
  else (
    match text.[idx - 1] with
    | ch when is_path_delimiter ch -> true
    | ':' | '=' -> true
    | _ -> false)
;;

let scan_path_end text start =
  let len = String.length text in
  let rec loop j =
    if j >= len || is_path_delimiter text.[j]
    then j
    else if text.[j] = ':' && (j + 1 >= len || is_path_delimiter text.[j + 1])
    then j
    else loop (j + 1)
  in
  loop start
;;

let has_masc_segment text start stop =
  let len = stop - start in
  len >= 5
  && (matches_at text start ".masc/"
      || String_util.contains_substring (String.sub text start len) "/.masc")
;;

let redact_server_paths text =
  let len = String.length text in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len
    then Buffer.contents buf
    else if is_token_boundary text i && matches_at text i "file://"
    then (
      let stop = scan_path_end text (i + 7) in
      Buffer.add_string buf "[REDACTED_PATH]";
      loop stop)
    else if
      is_token_boundary text i
      && i + 2 < len
      && is_ascii_alpha text.[i]
      && text.[i + 1] = ':'
      && (text.[i + 2] = '\\' || text.[i + 2] = '/')
    then (
      let stop = scan_path_end text (i + 2) in
      Buffer.add_string buf "[REDACTED_PATH]";
      loop stop)
    else if
      is_token_boundary text i
      && List.exists (matches_at text i) server_path_prefixes
    then (
      let stop = scan_path_end text i in
      Buffer.add_string buf "[REDACTED_PATH]";
      loop stop)
    else if is_token_boundary text i && (text.[i] = '/' || text.[i] = '.')
    then (
      let stop = scan_path_end text i in
      if has_masc_segment text i stop
      then (
        Buffer.add_string buf "[REDACTED_PATH]";
        loop stop)
      else (
        Buffer.add_char buf text.[i];
        loop (i + 1)))
    else (
      Buffer.add_char buf text.[i];
      loop (i + 1))
  in
  loop 0
;;

let sanitize_person_text text =
  text |> redact_server_paths |> Secret_patterns.redact_text |> one_line
;;

let runtime_provider_label provider =
  match Option.map String.trim provider with
  | Some provider when provider <> "" -> Printf.sprintf "Runtime provider '%s'" provider
  | _ -> "Runtime provider"
;;

(* One sentence, naming the failure once.

   The stacked form read "Runtime provider unavailable: connection closed.
   Check provider health or select another runtime. Detail: End_of_file" --
   the same failure named four times at decreasing abstraction, ending in
   OCaml's vocabulary rather than the operator's. Each layer prepended its own
   framing without reading what the layer below had already said.

   Two kinds let the detail speak instead of a condition phrase: a name
   resolution failure is about one host, and [Unknown] has no label worth the
   name. Writing both would repeat the fact -- "could not be resolved: failed
   to resolve hostname" -- which is the shape being removed. Every other kind
   states the condition and drops the exception, which restates it in OCaml's
   words ([End_of_file] renders exactly the constructor the kind already is)
   and stays in the typed value for logs regardless.

   Guidance stays only where the action is specific and not implied by the
   condition. A refused connection means nothing is listening; exhausted local
   resources mean too many requests at once. "Check provider health" after a
   dropped connection is not an instruction. *)
let provider_network_summary ~provider ~kind ~detail =
  let who = runtime_provider_label provider in
  let detail_speaks fallback =
    match String.trim detail with
    | "" -> who ^ " " ^ fallback
    | detail -> who ^ ": " ^ detail
  in
  match kind with
  | Llm_provider.Http_client.Connection_refused ->
    who ^ " refused the connection; nothing is listening on the runtime endpoint"
  | Llm_provider.Http_client.Dns_failure -> detail_speaks "could not be resolved"
  | Llm_provider.Http_client.Unreachable -> detail_speaks "has no network route from this host"
  | Llm_provider.Http_client.Tls_error -> who ^ " failed the TLS handshake"
  | Llm_provider.Http_client.Timeout -> who ^ " did not respond in time"
  | Llm_provider.Http_client.Local_resource_exhaustion ->
    "Local network resources are exhausted; fewer requests at once are needed"
  | Llm_provider.Http_client.Connection_reset -> who ^ " reset the connection"
  | Llm_provider.Http_client.End_of_file -> who ^ " closed the connection"
  | Llm_provider.Http_client.Unknown -> detail_speaks "could not be reached"
;;

(* A connection that did not open reads like any other network failure, so the
   summary adds what only this cause knows: the request never left. *)
let provider_connect_failed_summary ~provider ~kind ~detail =
  provider_network_summary ~provider ~kind ~detail ^ "; the request was not sent"
;;

(* The wait is shown when the provider stated one and omitted when it did not;
   it is never worked out from the provider's text. *)
let provider_rate_limited_summary ~provider ~retry_after ~detail =
  let who = runtime_provider_label provider in
  let wait =
    match retry_after with
    | Some seconds -> Printf.sprintf " (retry after %.1fs)" seconds
    | None -> ""
  in
  match String.trim detail with
  | "" -> who ^ " rate-limited the request" ^ wait
  | detail -> who ^ " rate-limited the request" ^ wait ^ ": " ^ one_line detail
;;

(* The raw provider diagnostic ("Context overflow: empty completion
   (stop_reason=model_context_window_exceeded): provider returned an empty
   assistant turn ...") reached dashboard chat verbatim, repeatedly, on
   2026-07-21. State the condition in the user's terms instead. Only the
   typed [Api ContextOverflow] arm exists: the [Provider] path collapses the
   overflow into [InvalidRequest] with a string reason (the module-boundary
   classification loss RFC-0353 tracks), and matching that string here would
   be a classifier -- the fix for that path is upstream type preservation. *)
let context_overflow_summary ~limit =
  let limit_part =
    match limit with
    | Some tokens -> Printf.sprintf " (model window ~%d tokens)" tokens
    | None -> ""
  in
  "This conversation no longer fits the model's context window"
  ^ limit_part
  ^ ". The message was not processed; a shorter message may fit."
;;

let turn_resource_clause = function
  | Registry_entry_missing -> "this keeper has no live registry entry"
  | Registry_entry_unhealthy -> "this keeper's registry entry is not usable"
;;

let continuation_stage_clause = function
  | Continuation_load -> "Loading this turn's continuation failed"
  | Gate_suspend -> "Suspending this turn for approval failed"
  | Runtime_continuation_defer -> "Saving this turn's runtime continuation failed"
  | Checkpoint_retain -> "Saving this turn's checkpoint failed"
;;

let failure_site_clause = function
  | Stream_dispatch -> "The keeper message dispatch"
  | Stream_streaming_call -> "The streaming turn dispatch"
  | Stream_turn_body -> "The queued turn"
  | Stream_submit -> "Submitting the queued turn"
;;

let summary_of_cause = function
  | Core core -> one_line core.Keeper_request_failure_core.message
  | Masc masc_error ->
    (match Keeper_internal_error.summary_of_masc_internal_error masc_error with
     | Some summary -> one_line summary
     (* No summary yet means the chat row's only carrier for the cause is its
        text, so the envelope has to survive: the pane reads it back to draw
        the lifecycle badge until the row carries the value.
        Regenerating it from the value keeps this the same string the carrier
        was built from. *)
     | None ->
       one_line
         (Agent_core.Error.to_string
            (Keeper_internal_error.core_error_of_masc_internal_error masc_error)))
  | Account_refused refusal -> Keeper_account_refusal.to_string refusal
  | Provider_auth_required { provider; detail } ->
    let who = runtime_provider_label provider in
    (match String.trim detail with
     | "" -> who ^ " requires authentication"
     | trimmed -> who ^ " authentication required: " ^ one_line trimmed)
  | Provider_key_refused { provider; detail = _ } ->
    Printf.sprintf "Provider '%s' refused the account's API key." provider
  | Provider_quota_exhausted { provider; retry_after; detail } ->
    let who = runtime_provider_label provider in
    let wait =
      match retry_after with
      | Some seconds -> Printf.sprintf " (retry after %.1fs)" seconds
      | None -> ""
    in
    (match String.trim detail with
     | "" -> who ^ " quota is exhausted" ^ wait
     | trimmed -> who ^ " quota is exhausted" ^ wait ^ ": " ^ one_line trimmed)
  | Provider_spawn_refused { provider; detail } ->
    Printf.sprintf "Client '%s' could not start: %s" provider (one_line detail)
  | Provider_timeout { provider; phase; detail } ->
    let who = runtime_provider_label provider in
    let phase_note =
      match Option.map String.trim phase with
      | Some value when value <> "" -> Printf.sprintf " during %s" value
      | Some _ | None -> ""
    in
    (match String.trim detail with
     | "" -> who ^ " timed out" ^ phase_note
     | trimmed -> who ^ " timed out" ^ phase_note ^ ": " ^ one_line trimmed)
  | Configuration_refused { field; detail } ->
    Printf.sprintf "Configuration error (%s): %s" (one_line field) (one_line detail)
  | Provider_network { provider; kind; detail } ->
    provider_network_summary ~provider ~kind ~detail
  | Provider_connect_failed { provider; kind; detail } ->
    provider_connect_failed_summary ~provider ~kind ~detail
  | Provider_rate_limited { provider; retry_after; detail } ->
    provider_rate_limited_summary ~provider ~retry_after ~detail
  | Context_overflow { limit } -> context_overflow_summary ~limit
  | Input_capacity ->
    "The runtime flow reported a typed input-capacity failure. MASC did not \
     select another runtime; the failure is escalated as a deterministic \
     judgment."
  | Operator_cancelled -> "operator interrupted the turn"
  | Server_not_initialized ->
    Masc_domain.masc_error_to_string
      (Masc_domain.System Masc_domain.System_error.NotInitialized)
  | Server_restarted -> "the server restarted before this request finished."
  | Dispatch_unavailable -> "masc_keeper_msg stream dispatch unavailable"
  | Keeper_meta_unresolved { keeper = _; detail } -> one_line detail
  | Keeper_not_registered { keeper } ->
    Printf.sprintf
      "keeper %s is not registered in this server process; retry shortly or start \
       it before sending a message"
      keeper
  | Invocation_rejected { detail } -> one_line detail
  | Chat_identity_mismatch ->
    "Keeper chat payload identity does not match its direct message"
  | Turn_resources_unavailable { resource; detail } ->
    Printf.sprintf
      "Keeper turn resources are unavailable: %s (%s)"
      (turn_resource_clause resource)
      (one_line detail)
  | Runtime_selection_failed { detail } -> one_line detail
  | Turn_continuation_unpersisted { stage; detail } ->
    Printf.sprintf "%s: %s" (continuation_stage_clause stage) (one_line detail)
  | User_row_unpersisted { detail } ->
    Printf.sprintf "Storing the message failed: %s" (one_line detail)
  | Gate_session_full { approval_id; runtime_id; session_id; recovery_id; activity } ->
    Printf.sprintf
      "Gate %s cannot continue: the %s session %s is full, so this continuation \
       ended for good (recovery %s).%s The next message starts a new session."
      (one_line approval_id)
      (one_line runtime_id)
      (one_line session_id)
      (one_line recovery_id)
      (match activity with
       | Keeper_internal_error.No_activity_observed -> ""
       | Keeper_internal_error.Activity_observed ->
         " A response or tool effect was observed before the refusal.")
  | Reply_contract_rejected { field = _; detail } -> one_line detail
  | No_visible_reply { stage; had_blocks = _ } ->
    (match stage with
     | Terminal_projection ->
       "Keeper completed without a visible reply; the runtime returned only \
        thinking or internal state."
     | Queued_delivery -> "no visible reply was produced for this queued message")
  | Raised { site; exn } ->
    Printf.sprintf "%s raised an exception: %s" (failure_site_clause site) (one_line exn)
;;

let summary { cause } = sanitize_person_text (summary_of_cause cause)

let failure_kind_of_account_refusal = function
  | Keeper_account_refusal.Key_unusable _ -> Failure_kind.Key_unusable
  | Keeper_account_refusal.Runtime_reassigned -> Failure_kind.Runtime_reassigned
  | Keeper_account_refusal.Authorization_zone_uncertain -> Failure_kind.Server_unavailable
  | Keeper_account_refusal.Account_home_unresolved
  | Keeper_account_refusal.Account_home_invalid -> Failure_kind.Configuration_refused
  | Keeper_account_refusal.Unknown_keeper
  | Keeper_account_refusal.Access_not_published
  | Keeper_account_refusal.Operator_turn_refused
  | Keeper_account_refusal.Channel_not_allowed
  | Keeper_account_refusal.Caller_not_authorized
  | Keeper_account_refusal.Pat_expired
  | Keeper_account_refusal.Pat_scope_not_explicit
  | Keeper_account_refusal.Scope_or_grant_refused
  | Keeper_account_refusal.Owner_inactive
  | Keeper_account_refusal.Provider_account_unavailable
  | Keeper_account_refusal.Authorization_not_bootstrapped
  | Keeper_account_refusal.Host_account_refused
  | Keeper_account_refusal.Accounts_disabled -> Failure_kind.Turn_refused
;;

let failure_kind_of_cause = function
  | Account_refused refusal -> failure_kind_of_account_refusal refusal
  | Provider_auth_required _ -> Failure_kind.Not_signed_in
  | Provider_key_refused _ -> Failure_kind.Key_refused
  | Provider_rate_limited _ | Provider_quota_exhausted _ | Input_capacity ->
    Failure_kind.No_quota
  | Provider_timeout _ -> Failure_kind.Silent
  | Provider_spawn_refused _ -> Failure_kind.Not_started
  | Provider_connect_failed { kind = Llm_provider.Http_client.Timeout; _ }
  | Provider_network { kind = Llm_provider.Http_client.Timeout; _ } ->
    Failure_kind.Silent
  | Provider_connect_failed
      { kind =
          ( Connection_refused
          | Dns_failure
          | Unreachable
          | Tls_error
          | Local_resource_exhaustion
          | Connection_reset
          | End_of_file
          | Unknown )
      ; _
      } -> Failure_kind.Not_started
  | Provider_network
      { kind =
          ( Connection_refused
          | Dns_failure
          | Unreachable
          | Tls_error
          | Local_resource_exhaustion
          | Connection_reset
          | End_of_file
          | Unknown )
      ; _
      } -> Failure_kind.No_answer
  | Configuration_refused _ -> Failure_kind.Configuration_refused
  | Operator_cancelled -> Failure_kind.Cancelled
  | No_visible_reply _ -> Failure_kind.No_visible_reply
  | Server_not_initialized
  | Server_restarted
  | Dispatch_unavailable
  | Turn_resources_unavailable _
  | Runtime_selection_failed _
  | Turn_continuation_unpersisted _
  | User_row_unpersisted _ -> Failure_kind.Server_unavailable
  | Masc (Keeper_internal_error.Accept_rejected _) -> Failure_kind.No_visible_reply
  | Masc
      ( Keeper_internal_error.Official_client_recovery_required _
      | Keeper_internal_error.Runtime_exhausted _
      | Keeper_internal_error.Resumable_cli_session _
      | Keeper_internal_error.Internal_unhandled_exception _
      | Keeper_internal_error.Internal_bridge_exception _
      | Keeper_internal_error.Internal_contract_rejected _
      | Keeper_internal_error.Incomplete_tool_transcript _
      | Keeper_internal_error.Terminal_effect_failed _
      | Keeper_internal_error.Provider_attempt_effect_fenced _
      | Keeper_internal_error.Tool_correction_lost _
      | Keeper_internal_error.Host_stopped_turn _
      | Keeper_internal_error.Runtime_connection_closed _
      | Keeper_internal_error.Receipt_persistence_failed _
      | Keeper_internal_error.Gate_replay_repair_required _ ) ->
    Failure_kind.No_answer
  | Core { Keeper_request_failure_core.category = Agent_core.Error.Config_category; _ } ->
    Failure_kind.Configuration_refused
  | Core
      { Keeper_request_failure_core.category =
          ( Agent_core.Error.Api_category
          | Agent_core.Error.Provider_category
          | Agent_core.Error.Agent_category
          | Agent_core.Error.Mcp_category
          | Agent_core.Error.Serialization_category
          | Agent_core.Error.Io_category
          | Agent_core.Error.Orchestration_category
          | Agent_core.Error.Media_category
          | Agent_core.Error.Internal_category )
      ; _
      }
  | Context_overflow _
  | Keeper_meta_unresolved _
  | Keeper_not_registered _
  | Invocation_rejected _
  | Chat_identity_mismatch
  | Gate_session_full _
  | Reply_contract_rejected _
  | Raised _ -> Failure_kind.No_answer
;;

let failure_kind { cause } = failure_kind_of_cause cause

(* ------------------------------------------------------------------ *)
(* Wire                                                                *)
(* ------------------------------------------------------------------ *)

let turn_resource_to_string = function
  | Registry_entry_missing -> "registry_entry_missing"
  | Registry_entry_unhealthy -> "registry_entry_unhealthy"
;;

let turn_resource_of_string = function
  | "registry_entry_missing" -> Some Registry_entry_missing
  | "registry_entry_unhealthy" -> Some Registry_entry_unhealthy
  | _ -> None
;;

let continuation_stage_to_string = function
  | Continuation_load -> "continuation_load"
  | Gate_suspend -> "gate_suspend"
  | Runtime_continuation_defer -> "runtime_continuation_defer"
  | Checkpoint_retain -> "checkpoint_retain"
;;

let continuation_stage_of_string = function
  | "continuation_load" -> Some Continuation_load
  | "gate_suspend" -> Some Gate_suspend
  | "runtime_continuation_defer" -> Some Runtime_continuation_defer
  | "checkpoint_retain" -> Some Checkpoint_retain
  | _ -> None
;;

let reply_contract_field_to_string = function
  | Reply_payload -> "reply_payload"
  | Turn_outcome -> "turn_outcome"
  | Turn_ref -> "turn_ref"
  | External_effect_target -> "external_effect_target"
;;

let reply_contract_field_of_string = function
  | "reply_payload" -> Some Reply_payload
  | "turn_outcome" -> Some Turn_outcome
  | "turn_ref" -> Some Turn_ref
  | "external_effect_target" -> Some External_effect_target
  | _ -> None
;;

let visible_reply_stage_to_string = function
  | Terminal_projection -> "terminal_projection"
  | Queued_delivery -> "queued_delivery"
;;

let visible_reply_stage_of_string = function
  | "terminal_projection" -> Some Terminal_projection
  | "queued_delivery" -> Some Queued_delivery
  | _ -> None
;;

let failure_site_to_string = function
  | Stream_dispatch -> "stream_dispatch"
  | Stream_streaming_call -> "stream_streaming_call"
  | Stream_turn_body -> "stream_turn_body"
  | Stream_submit -> "stream_submit"
;;

let failure_site_of_string = function
  | "stream_dispatch" -> Some Stream_dispatch
  | "stream_streaming_call" -> Some Stream_streaming_call
  | "stream_turn_body" -> Some Stream_turn_body
  | "stream_submit" -> Some Stream_submit
  | _ -> None
;;

let network_cause_to_yojson ~label ~provider ~kind ~detail =
  `Assoc
    [ "kind", `String label
    ; ( "provider"
      , match provider with
        | Some provider -> `String provider
        | None -> `Null )
    ; "network_kind", `String (Llm_provider.Http_client.network_error_kind_to_string kind)
    ; "detail", `String detail
    ]
;;

let cause_to_yojson = function
  | Core core ->
    `Assoc
      [ "kind", `String "core"; "core", Keeper_request_failure_core.to_yojson core ]
  | Masc masc_error ->
    `Assoc
      [ "kind", `String "masc"
      ; "error", Keeper_internal_error.masc_internal_error_to_json masc_error
      ]
  | Account_refused refusal ->
    `Assoc
      [ "kind", `String "account_refused"
      ; "refusal", `String (Keeper_account_refusal.to_wire refusal)
      ]
  | Provider_auth_required { provider; detail } ->
    `Assoc
      [ "kind", `String "provider_auth_required"
      ; "provider", (match provider with Some value -> `String value | None -> `Null)
      ; "detail", `String detail
      ]
  | Provider_key_refused { provider; detail } ->
    `Assoc
      [ "kind", `String "provider_key_refused"
      ; "provider", `String provider
      ; "detail", `String detail
      ]
  | Provider_quota_exhausted { provider; retry_after; detail } ->
    `Assoc
      [ "kind", `String "provider_quota_exhausted"
      ; "provider", (match provider with Some value -> `String value | None -> `Null)
      ; "retry_after", (match retry_after with Some value -> `Float value | None -> `Null)
      ; "detail", `String detail
      ]
  | Provider_spawn_refused { provider; detail } ->
    `Assoc
      [ "kind", `String "provider_spawn_refused"
      ; "provider", `String provider
      ; "detail", `String detail
      ]
  | Provider_timeout { provider; phase; detail } ->
    `Assoc
      [ "kind", `String "provider_timeout"
      ; "provider", (match provider with Some value -> `String value | None -> `Null)
      ; "phase", (match phase with Some value -> `String value | None -> `Null)
      ; "detail", `String detail
      ]
  | Configuration_refused { field; detail } ->
    `Assoc
      [ "kind", `String "configuration_refused"
      ; "field", `String field
      ; "detail", `String detail
      ]
  | Provider_network { provider; kind; detail } ->
    network_cause_to_yojson ~label:"provider_network" ~provider ~kind ~detail
  | Provider_connect_failed { provider; kind; detail } ->
    network_cause_to_yojson ~label:"provider_connect_failed" ~provider ~kind ~detail
  | Provider_rate_limited { provider; retry_after; detail } ->
    `Assoc
      [ "kind", `String "provider_rate_limited"
      ; "provider", (match provider with Some value -> `String value | None -> `Null)
      ; "retry_after", (match retry_after with Some value -> `Float value | None -> `Null)
      ; "detail", `String detail
      ]
  | Context_overflow { limit } ->
    `Assoc
      [ "kind", `String "context_overflow"
      ; ( "limit"
        , match limit with
          | Some limit -> `Int limit
          | None -> `Null )
      ]
  | Input_capacity -> `Assoc [ "kind", `String "input_capacity" ]
  | Operator_cancelled -> `Assoc [ "kind", `String "operator_cancelled" ]
  | Server_not_initialized -> `Assoc [ "kind", `String "server_not_initialized" ]
  | Server_restarted -> `Assoc [ "kind", `String "server_restarted" ]
  | Dispatch_unavailable -> `Assoc [ "kind", `String "dispatch_unavailable" ]
  | Keeper_meta_unresolved { keeper; detail } ->
    `Assoc
      [ "kind", `String "keeper_meta_unresolved"
      ; "keeper", `String keeper
      ; "detail", `String detail
      ]
  | Keeper_not_registered { keeper } ->
    `Assoc [ "kind", `String "keeper_not_registered"; "keeper", `String keeper ]
  | Invocation_rejected { detail } ->
    `Assoc [ "kind", `String "invocation_rejected"; "detail", `String detail ]
  | Chat_identity_mismatch -> `Assoc [ "kind", `String "chat_identity_mismatch" ]
  | Turn_resources_unavailable { resource; detail } ->
    `Assoc
      [ "kind", `String "turn_resources_unavailable"
      ; "resource", `String (turn_resource_to_string resource)
      ; "detail", `String detail
      ]
  | Runtime_selection_failed { detail } ->
    `Assoc [ "kind", `String "runtime_selection_failed"; "detail", `String detail ]
  | Turn_continuation_unpersisted { stage; detail } ->
    `Assoc
      [ "kind", `String "turn_continuation_unpersisted"
      ; "stage", `String (continuation_stage_to_string stage)
      ; "detail", `String detail
      ]
  | User_row_unpersisted { detail } ->
    `Assoc [ "kind", `String "user_row_unpersisted"; "detail", `String detail ]
  | Gate_session_full { approval_id; runtime_id; session_id; recovery_id; activity } ->
    `Assoc
      [ "kind", `String "gate_session_full"
      ; "approval_id", `String approval_id
      ; "runtime_id", `String runtime_id
      ; "session_id", `String session_id
      ; "recovery_id", `String recovery_id
      ; "activity", `String (Keeper_internal_error.vendor_session_activity_to_string activity)
      ]
  | Reply_contract_rejected { field; detail } ->
    `Assoc
      [ "kind", `String "reply_contract_rejected"
      ; "field", `String (reply_contract_field_to_string field)
      ; "detail", `String detail
      ]
  | No_visible_reply { stage; had_blocks } ->
    `Assoc
      [ "kind", `String "no_visible_reply"
      ; "stage", `String (visible_reply_stage_to_string stage)
      ; "had_blocks", `Bool had_blocks
      ]
  | Raised { site; exn } ->
    `Assoc
      [ "kind", `String "raised"
      ; "site", `String (failure_site_to_string site)
      ; "exn", `String exn
      ]
;;

let to_yojson { cause } = `Assoc [ "cause", cause_to_yojson cause ]

let exact_fields expected fields =
  let sort = List.sort String.compare in
  List.equal String.equal (sort expected) (sort (List.map fst fields))
;;

let field_error kind name = Error (Printf.sprintf "%s field %S has the wrong shape" kind name)

let string_field kind fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ | None -> field_error kind name
;;

let bool_field kind fields name =
  match List.assoc_opt name fields with
  | Some (`Bool value) -> Ok value
  | Some _ | None -> field_error kind name
;;

let labelled kind name to_value fields =
  Result.bind (string_field kind fields name) (fun raw ->
    match to_value raw with
    | Some value -> Ok value
    | None -> Error (Printf.sprintf "%s field %S has unknown value %S" kind name raw))
;;

let require kind expected fields body =
  if exact_fields ("kind" :: expected) fields
  then body ()
  else
    Error
      (Printf.sprintf
         "%s fields must be exactly [%s], got [%s]"
         kind
         (String.concat "," (List.sort String.compare ("kind" :: expected)))
         (String.concat "," (List.sort String.compare (List.map fst fields))))
;;

let detail_only kind fields build =
  require kind [ "detail" ] fields (fun () ->
    Result.map build (string_field kind fields "detail"))
;;

let nullary kind fields value =
  require kind [] fields (fun () -> Ok value)
;;

let network_cause kind fields build =
  require kind [ "provider"; "network_kind"; "detail" ] fields (fun () ->
    let provider =
      match List.assoc_opt "provider" fields with
      | Some (`String provider) -> Ok (Some provider)
      | Some `Null -> Ok None
      | Some _ | None -> field_error kind "provider"
    in
    Result.bind provider (fun provider ->
      Result.bind
        (labelled
           kind
           "network_kind"
           Llm_provider.Http_client.network_error_kind_of_string
           fields)
        (fun network_kind ->
           Result.map
             (fun detail -> build ~provider ~network_kind ~detail)
             (string_field kind fields "detail"))))
;;

let opt_string_field kind fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok (Some value)
  | Some `Null -> Ok None
  | Some _ | None -> field_error kind name
;;

let opt_float_field kind fields name =
  match List.assoc_opt name fields with
  | Some (`Float value) when Float.is_finite value -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (float_of_int value))
  | Some `Null -> Ok None
  | Some _ | None -> field_error kind name
;;

let cause_of_yojson (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String kind) ->
       (match kind with
        | "core" ->
          require kind [ "core" ] fields (fun () ->
            match List.assoc_opt "core" fields with
            | Some core ->
              Result.map (fun core -> Core core) (Keeper_request_failure_core.of_yojson core)
            | None -> field_error kind "core")
        | "masc" ->
          require kind [ "error" ] fields (fun () ->
            match
              Option.bind
                (List.assoc_opt "error" fields)
                Keeper_internal_error.parse_masc_internal_error_json
            with
            | Some masc_error -> Ok (Masc masc_error)
            | None -> field_error kind "error")
        | "account_refused" ->
          require kind [ "refusal" ] fields (fun () ->
            Result.bind
              (labelled kind "refusal"
                 (fun raw -> Result.to_option (Keeper_account_refusal.of_wire raw))
                 fields)
              (fun refusal -> Ok (Account_refused refusal)))
        | "provider_auth_required" ->
          require kind [ "provider"; "detail" ] fields (fun () ->
            Result.bind (opt_string_field kind fields "provider") (fun provider ->
              Result.map
                (fun detail -> Provider_auth_required { provider; detail })
                (string_field kind fields "detail")))
        | "provider_key_refused" ->
          require kind [ "provider"; "detail" ] fields (fun () ->
            Result.bind (string_field kind fields "provider") (fun provider ->
              Result.map
                (fun detail -> Provider_key_refused { provider; detail })
                (string_field kind fields "detail")))
        | "provider_quota_exhausted" ->
          require kind [ "provider"; "retry_after"; "detail" ] fields (fun () ->
            Result.bind (opt_string_field kind fields "provider") (fun provider ->
              Result.bind (opt_float_field kind fields "retry_after") (fun retry_after ->
                Result.map
                  (fun detail -> Provider_quota_exhausted { provider; retry_after; detail })
                  (string_field kind fields "detail"))))
        | "provider_spawn_refused" ->
          require kind [ "provider"; "detail" ] fields (fun () ->
            Result.bind (string_field kind fields "provider") (fun provider ->
              Result.map
                (fun detail -> Provider_spawn_refused { provider; detail })
                (string_field kind fields "detail")))
        | "provider_timeout" ->
          require kind [ "provider"; "phase"; "detail" ] fields (fun () ->
            Result.bind (opt_string_field kind fields "provider") (fun provider ->
              Result.bind (opt_string_field kind fields "phase") (fun phase ->
                Result.map
                  (fun detail -> Provider_timeout { provider; phase; detail })
                  (string_field kind fields "detail"))))
        | "configuration_refused" ->
          require kind [ "field"; "detail" ] fields (fun () ->
            Result.bind (string_field kind fields "field") (fun field ->
              Result.map
                (fun detail -> Configuration_refused { field; detail })
                (string_field kind fields "detail")))
        | "provider_network" ->
          network_cause kind fields (fun ~provider ~network_kind ~detail ->
            Provider_network { provider; kind = network_kind; detail })
        | "provider_connect_failed" ->
          network_cause kind fields (fun ~provider ~network_kind ~detail ->
            Provider_connect_failed { provider; kind = network_kind; detail })
        | "provider_rate_limited" ->
          require kind [ "provider"; "retry_after"; "detail" ] fields (fun () ->
            let provider =
              match List.assoc_opt "provider" fields with
              | Some (`String value) -> Ok (Some value)
              | Some `Null -> Ok None
              | Some _ | None -> field_error kind "provider"
            in
            let retry_after =
              match List.assoc_opt "retry_after" fields with
              | Some (`Float value) when Float.is_finite value -> Ok (Some value)
              | Some (`Int value) -> Ok (Some (float_of_int value))
              | Some `Null -> Ok None
              | Some _ | None -> field_error kind "retry_after"
            in
            Result.bind provider (fun provider ->
              Result.bind retry_after (fun retry_after ->
                Result.map
                  (fun detail -> Provider_rate_limited { provider; retry_after; detail })
                  (string_field kind fields "detail"))))
        | "context_overflow" ->
          require kind [ "limit" ] fields (fun () ->
            match List.assoc_opt "limit" fields with
            | Some (`Int limit) -> Ok (Context_overflow { limit = Some limit })
            | Some `Null -> Ok (Context_overflow { limit = None })
            | Some _ | None -> field_error kind "limit")
        | "input_capacity" -> nullary kind fields Input_capacity
        | "operator_cancelled" -> nullary kind fields Operator_cancelled
        | "server_not_initialized" -> nullary kind fields Server_not_initialized
        | "server_restarted" -> nullary kind fields Server_restarted
        | "dispatch_unavailable" -> nullary kind fields Dispatch_unavailable
        | "keeper_meta_unresolved" ->
          require kind [ "keeper"; "detail" ] fields (fun () ->
            Result.bind (string_field kind fields "keeper") (fun keeper ->
              Result.map
                (fun detail -> Keeper_meta_unresolved { keeper; detail })
                (string_field kind fields "detail")))
        | "keeper_not_registered" ->
          require kind [ "keeper" ] fields (fun () ->
            Result.map
              (fun keeper -> Keeper_not_registered { keeper })
              (string_field kind fields "keeper"))
        | "invocation_rejected" ->
          detail_only kind fields (fun detail -> Invocation_rejected { detail })
        | "chat_identity_mismatch" -> nullary kind fields Chat_identity_mismatch
        | "turn_resources_unavailable" ->
          require kind [ "resource"; "detail" ] fields (fun () ->
            Result.bind
              (labelled kind "resource" turn_resource_of_string fields)
              (fun resource ->
                 Result.map
                   (fun detail -> Turn_resources_unavailable { resource; detail })
                   (string_field kind fields "detail")))
        | "runtime_selection_failed" ->
          detail_only kind fields (fun detail -> Runtime_selection_failed { detail })
        | "turn_continuation_unpersisted" ->
          require kind [ "stage"; "detail" ] fields (fun () ->
            Result.bind
              (labelled kind "stage" continuation_stage_of_string fields)
              (fun stage ->
                 Result.map
                   (fun detail -> Turn_continuation_unpersisted { stage; detail })
                   (string_field kind fields "detail")))
        | "user_row_unpersisted" ->
          detail_only kind fields (fun detail -> User_row_unpersisted { detail })
        | "gate_session_full" ->
          require kind
            [ "approval_id"; "runtime_id"; "session_id"; "recovery_id"; "activity" ] fields
            (fun () ->
               Result.bind (string_field kind fields "approval_id") (fun approval_id ->
                 Result.bind (string_field kind fields "runtime_id") (fun runtime_id ->
                   Result.bind (string_field kind fields "session_id") (fun session_id ->
                     Result.bind (string_field kind fields "recovery_id") (fun recovery_id ->
                       Result.map
                         (fun activity ->
                            Gate_session_full
                              { approval_id; runtime_id; session_id; recovery_id; activity })
                         (labelled kind "activity"
                            Keeper_internal_error.vendor_session_activity_of_string fields))))))
        | "reply_contract_rejected" ->
          require kind [ "field"; "detail" ] fields (fun () ->
            Result.bind
              (labelled kind "field" reply_contract_field_of_string fields)
              (fun field ->
                 Result.map
                   (fun detail -> Reply_contract_rejected { field; detail })
                   (string_field kind fields "detail")))
        | "no_visible_reply" ->
          require kind [ "stage"; "had_blocks" ] fields (fun () ->
            Result.bind
              (labelled kind "stage" visible_reply_stage_of_string fields)
              (fun stage ->
                 Result.map
                   (fun had_blocks -> No_visible_reply { stage; had_blocks })
                   (bool_field kind fields "had_blocks")))
        | "raised" ->
          require kind [ "site"; "exn" ] fields (fun () ->
            Result.bind
              (labelled kind "site" failure_site_of_string fields)
              (fun site ->
                 Result.map
                   (fun exn -> Raised { site; exn })
                   (string_field kind fields "exn")))
        | unknown ->
          Error (Printf.sprintf "request failure has unknown kind %S" unknown))
     | Some _ | None -> Error "request failure cause has no string \"kind\"")
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error "request failure cause is not an object"
;;

let of_yojson (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    if not (exact_fields [ "cause" ] fields)
    then
      Error
        (Printf.sprintf
           "request failure fields must be exactly [cause], got [%s]"
           (String.concat "," (List.sort String.compare (List.map fst fields))))
    else (
      match List.assoc_opt "cause" fields with
      | Some cause -> Result.map (fun cause -> { cause }) (cause_of_yojson cause)
      | None -> Error "request failure has no \"cause\"")
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error "request failure is not an object"
;;

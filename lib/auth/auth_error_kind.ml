(** Closed-enum classification of [Masc_domain.t] for auth-related logging
    and otel_metric_store metric labels.

    Replaces inline string-label matching at:
    - [lib/server/server_auth.ml] dashboard_actor_fallback warn/counter
    - [lib/mcp_server_eio_execute.ml] silent_auth_token_error_kind

    The string labels are stable contract for otel_metric_store dashboards and
    must round-trip through [to_string] / [of_string]. The variant is
    closed so that any new auth-relevant [Masc_domain.t] constructor that
    needs its own label requires an explicit code change here, not a
    silent fall-through to ["other"]. *)

type t =
  | Token_mismatch
  | Token_expired
  | Unauthorized
  | Forbidden
  | Agent_not_found
  | Io_error
  | Invalid_json
  | Other

let to_string = function
  | Token_mismatch -> "token_mismatch"
  | Token_expired -> "token_expired"
  | Unauthorized -> "unauthorized"
  | Forbidden -> "forbidden"
  | Agent_not_found -> "agent_not_found"
  | Io_error -> "io_error"
  | Invalid_json -> "invalid_json"
  | Other -> "other"

let of_string = function
  | "token_mismatch" -> Some Token_mismatch
  | "token_expired" -> Some Token_expired
  | "unauthorized" -> Some Unauthorized
  | "forbidden" -> Some Forbidden
  | "agent_not_found" -> Some Agent_not_found
  | "io_error" -> Some Io_error
  | "invalid_json" -> Some Invalid_json
  | "other" -> Some Other
  | _ -> None

let classify : Masc_domain.t -> t = function
  | Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken _) -> Token_mismatch
  | Masc_domain.Auth (Masc_domain.Auth_error.TokenExpired _) -> Token_expired
  | Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized _) -> Unauthorized
  | Masc_domain.Auth (Masc_domain.Auth_error.Forbidden _) -> Forbidden
  | Masc_domain.Agent (Masc_domain.Agent_error.NotFound _) -> Agent_not_found
  | Masc_domain.System (Masc_domain.System_error.IoError _) -> Io_error
  | Masc_domain.System (Masc_domain.System_error.InvalidJson _) -> Invalid_json
  | _ -> Other

let all =
  [ Token_mismatch
  ; Token_expired
  ; Unauthorized
  ; Forbidden
  ; Agent_not_found
  ; Io_error
  ; Invalid_json
  ; Other
  ]

(* ----- Dashboard actor fallback typed surface ------------------------ *)
(* See .mli for rationale. The historical event key remains stable for
   operational continuity, while the message now states that the actor hint
   was rejected. The token_mismatch remediation tail is reproduced verbatim because
   operators key alerts on the literal "Remediation:" substring
   (server_auth.ml:332-339 inline rationale). *)

type dashboard_actor_fallback_outcome =
  | Outcome_none
  | Outcome_error of
      { err : Masc_domain.t
      ; err_kind : t
      ; actor_hint : string option
      }

type dashboard_actor_fallback =
  { outcome : dashboard_actor_fallback_outcome
  ; token_hash_prefix : string
  }

let dashboard_actor_fallback_log_message fb =
  match fb.outcome with
  | Outcome_none ->
      (* Keep the historical event prefix while stating the fail-closed
         disposition explicitly. *)
      Printf.sprintf
        "[silent:dashboard_actor_fallback] outcome=none token_hash_prefix=%s \
         \xe2\x80\x94 bearer token resolved to no agent; request actor hint \
         ignored"
        fb.token_hash_prefix
  | Outcome_error { err; err_kind; actor_hint } ->
      let err_str = Masc_domain.masc_error_to_string err in
      let hint =
        match actor_hint with
        | Some s -> s
        | None -> "<none>"
      in
      let err_kind_label = to_string err_kind in
      let extra_hint =
        match err_kind with
        | Token_mismatch ->
            " Remediation: clear the browser's stored dashboard token \
             (localStorage masc_dashboard_token) or delete \
             .masc/auth/dashboard.token so a fresh token is minted on \
             the next dashboard load."
        | Token_expired
        | Unauthorized
        | Forbidden
        | Agent_not_found
        | Io_error
        | Invalid_json
        | Other -> ""
      in
      Printf.sprintf
        "[silent:dashboard_actor_fallback] outcome=error \
         token_hash_prefix=%s err_kind=%s actor_hint=%s err=%s \xe2\x80\x94 \
         request actor hint ignored.%s"
        fb.token_hash_prefix err_kind_label hint err_str extra_hint

let dashboard_actor_fallback_metric_labels fb =
  match fb.outcome with
  | Outcome_none ->
      [ ( "outcome"
        , Silent_dashboard_actor_outcome.to_label
            Silent_dashboard_actor_outcome.None_resolved )
      ]
  | Outcome_error { err_kind; _ } ->
      [ ( "outcome"
        , Silent_dashboard_actor_outcome.to_label
            Silent_dashboard_actor_outcome.Error_classified )
      ; ("err_kind", to_string err_kind)
      ]

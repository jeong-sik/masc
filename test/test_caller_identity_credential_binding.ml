(** Regression guard: a bearer credential decides the caller identity, and
    the workspace display alias must not overrule it.

    Observed on the live fleet (2026-08-12): every dashboard MCP tool call
    failed with [AuthError] Invalid token: Token mismatch while presenting the
    dashboard's own freshly minted credential. 860 failures in 3.5 hours, all
    with agent_name="dashboard".

    Chain, measured against the live workspace:

      .masc/agents/dashboard.json                    absent
      .masc/agents/dashboard-admin-deft-cobra.json   present
      Workspace.resolve_agent_name "dashboard"    -> "dashboard-admin-deft-cobra"
      Auth.verify_token ~agent_name:"dashboard"                  -> Ok
      Auth.verify_token ~agent_name:"dashboard-admin-deft-cobra" -> Error
                                        (InvalidToken "Token mismatch")

    The alias is a display-layer prefix scan over a directory listing; it was
    feeding the authorization subject. No token rotation could clear this,
    because the presented token was never the failing input. *)

open Alcotest

module Caller = Masc.Mcp_server_eio_caller_identity

let may_rewrite ~credential_owner ~agent_name =
  Caller.alias_may_rewrite_identity ~credential_owner ~agent_name

(* The exact live shape: the request names the credential it holds. *)
let test_credential_owned_name_is_not_rewritable () =
  check
    bool
    "an alias cannot rewrite the name owned by the presented credential"
    false
    (may_rewrite ~credential_owner:(Some "dashboard") ~agent_name:"dashboard")

(* Keeper transport aliases keep working: the caller names "beta" while the
   credential belongs to "keeper-beta-agent", so the alias is still the only
   thing that can connect the two. *)
let test_unowned_name_stays_rewritable () =
  check
    bool
    "an alias may still rewrite a name the credential does not own"
    true
    (may_rewrite
       ~credential_owner:(Some "keeper-beta-agent")
       ~agent_name:"beta")

let test_unauthenticated_request_stays_rewritable () =
  check
    bool
    "without a resolvable credential the alias keeps its previous authority"
    true
    (may_rewrite ~credential_owner:None ~agent_name:"dashboard")

(* Prefix-sharing is what the workspace scan matches on, and it is exactly
   what must not reach the authorization subject when the name is owned. *)
let test_prefix_sharing_owner_is_not_rewritable () =
  List.iter
    (fun name ->
      check
        bool
        (Printf.sprintf "%S is credential-bound, so no alias rewrite" name)
        false
        (may_rewrite ~credential_owner:(Some name) ~agent_name:name))
    [ "dashboard"; "dashboard-admin"; "keeper-beta-agent"; "delta" ]

(* The live workspace lookup, as a stub: no [dashboard.json] record exists,
   so the prefix scan returns the first record sharing the "dashboard-"
   prefix. Injecting it pins the ordering between the guard and the lookup,
   which is the part that decides what reaches [Auth.authorize_tool_v2]. *)
let live_alias_scan = function
  | "dashboard" | "dashboard-admin" -> "dashboard-admin-deft-cobra"
  | "beta" -> "keeper-beta-agent"
  | name -> name

let subject_for ~credential_owner agent_name =
  Caller.resolve_identity_alias
    ~credential_owner
    ~resolve_alias:live_alias_scan
    agent_name

let test_authorization_subject_is_the_presented_credential () =
  check
    string
    "the dashboard's own credential authorizes as the dashboard"
    "dashboard"
    (subject_for ~credential_owner:(Some "dashboard") "dashboard")

let test_authorization_subject_keeps_transport_alias () =
  check
    string
    "a keeper transport alias still resolves to its bound record"
    "keeper-beta-agent"
    (subject_for ~credential_owner:(Some "keeper-beta-agent") "beta")

let test_authorization_subject_without_credential () =
  check
    string
    "an unauthenticated caller keeps the previous alias behaviour"
    "dashboard-admin-deft-cobra"
    (subject_for ~credential_owner:None "dashboard")

let () =
  run
    "caller_identity_credential_binding"
    [ ( "authorization subject"
      , [ test_case
            "presented credential is the subject"
            `Quick
            test_authorization_subject_is_the_presented_credential
        ; test_case
            "transport alias still resolves"
            `Quick
            test_authorization_subject_keeps_transport_alias
        ; test_case
            "no credential keeps alias behaviour"
            `Quick
            test_authorization_subject_without_credential
        ] )
    ; ( "alias vs credential"
      , [ test_case
            "credential-owned name is not rewritable"
            `Quick
            test_credential_owned_name_is_not_rewritable
        ; test_case
            "unowned name stays rewritable"
            `Quick
            test_unowned_name_stays_rewritable
        ; test_case
            "unauthenticated request stays rewritable"
            `Quick
            test_unauthenticated_request_stays_rewritable
        ; test_case
            "prefix-sharing owners are not rewritable"
            `Quick
            test_prefix_sharing_owner_is_not_rewritable
        ] )
    ]

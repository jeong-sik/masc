(* Table checks for [Authz_decision.allowed], one row per conjunct of design
   6.2. Each row starts from a world where the request is allowed, changes one
   fact or one request field, and names the reason that must come back. Pure:
   the facts are closures over in-memory tables. *)

open Authz_types
open Authz_records
module D = Authz_decision

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let alice = Principal.Human (get (User_id.of_string "alice"))
let bob = Principal.Human (get (User_id.of_string "bob"))
let carol = Principal.Human (get (User_id.of_string "carol"))
let keeper = Principal.Service (get (Service_id.of_string "keeper-1"))
let rt = get (Runtime_id.of_string "rt-1")
let other_rt = get (Runtime_id.of_string "rt-2")
let account = get (Provider_account_id.of_string "pa-1")
let ws = get (Workspace_id.of_string "ws-1")
let other_ws = get (Workspace_id.of_string "ws-2")
let policy_id = get (Policy_id.of_string "p-1")
let now = 1000.
let found value = D.Found value

let table_lookup table key =
  match List.find_opt (fun (candidate, _) -> Principal.equal candidate key) table with
  | Some (_, value) -> value
  | None -> D.Absent
;;

let effects list = Effect.Set.of_list list
let effects_only list = Effect_scope.only (effects list)
let channels_only list = Channel_scope.only (Channel.Set.of_list list)
let runtimes_only list = Runtime_scope.only (Runtime_id.Set.of_list list)

let scope
      ?(runtimes = Runtime_scope.all)
      ?(channels = Channel_scope.all)
      ?(allowed_effects = Effect_scope.all)
      ()
  =
  { Authorization_scope.runtimes; channels; allowed_effects }
;;

let grant
      ?(status = Grant_status.Active)
      ?(kind = Runtime_grant.Self)
      ?(runtime = rt)
      ~id
      ~grantee
      list
  =
  { Runtime_grant.id = get (Grant_id.of_string id)
  ; runtime_id = runtime
  ; grantee
  ; allowed_effects = effects list
  ; status
  ; kind
  }
;;

let delegated = Runtime_grant.Delegated { expires_at = None }
let base_effects = Effect.[ Invoke_model; Use_tool ]
let alice_grant = grant ~id:"g-alice" ~grantee:alice base_effects

let bob_grant =
  grant ~id:"g-bob" ~grantee:bob ~kind:delegated Effect.[ Invoke_model; Use_tool; Read_state ]
;;

let keeper_grant = grant ~id:"g-keeper" ~grantee:keeper ~kind:delegated base_effects

let bob_to_keeper =
  { Delegate_policy.id = policy_id
  ; initiator = bob
  ; executor = keeper
  ; scope =
      scope
        ~channels:(channels_only [ Channel.Delegate ])
        ~allowed_effects:(effects_only base_effects)
        ()
  }
;;

let runtime_row status =
  { Runtime_row.id = rt; owner = alice; provider_account = account; status }
;;

(* Alice owns rt-1 on pa-1 and holds a Self grant. Bob holds a Delegated grant
   and may act through the keeper under policy p-1. Carol is a member with no
   grant. *)
let base_facts : D.facts =
  { D.now
  ; principal =
      table_lookup
        [ alice, found Principal_status.Active
        ; bob, found Principal_status.Active
        ; carol, found Principal_status.Active
        ; keeper, found Principal_status.Active
        ]
  ; auth_binding = (fun _ -> found Auth_binding_status.Active)
  ; membership =
      (fun principal workspace ->
        if Workspace_id.equal workspace ws
        then
          table_lookup
            [ alice, found Membership_status.Active
            ; bob, found Membership_status.Active
            ; carol, found Membership_status.Active
            ; keeper, found Membership_status.Active
            ]
            principal
        else D.Absent)
  ; delegate_policy =
      (fun ~initiator ~executor ->
        if Principal.equal initiator bob && Principal.equal executor keeper
        then found bob_to_keeper
        else D.Absent)
  ; runtime =
      (fun id ->
        if Runtime_id.equal id rt
        then found (runtime_row Resource_status.Active)
        else D.Absent)
  ; provider_account =
      (fun id ->
        if Provider_account_id.equal id account
        then found Resource_status.Active
        else D.Absent)
  ; grant =
      (fun principal runtime ->
        if Runtime_id.equal runtime rt
        then
          table_lookup
            [ alice, found alice_grant; bob, found bob_grant; keeper, found keeper_grant ]
            principal
        else D.Absent)
  ; revocation = (fun _ -> found Revocation_state.Not_pending)
  ; dependencies = (fun _ -> found Dependency_state.Cleared)
  }
;;

let request ~initiator ~executor ~channel : D.request =
  { D.context =
      { Execution_context.initiator
      ; executor
      ; channel
      ; stored_scope = Authorization_scope.all
      ; pat_scope = Pat_binding.Not_pat
      }
  ; workspace_id = ws
  ; runtime_id = rt
  ; requested = Effect_request.make Effect.Invoke_model []
  }
;;

(* Alice runs her own Runtime directly. *)
let self_request = request ~initiator:alice ~executor:alice ~channel:Channel.Direct

(* Bob asks, the keeper runs, on Alice's Runtime. *)
let delegated_request = request ~initiator:bob ~executor:keeper ~channel:Channel.Delegate

(* Carol has no grant on anything. *)
let stranger_request = request ~initiator:carol ~executor:carol ~channel:Channel.Direct

(* Request changes. *)
let map_context change (r : D.request) = { r with D.context = change r.D.context }

let with_stored_scope stored =
  map_context (fun c -> { c with Execution_context.stored_scope = stored })
;;

let with_pat pat = map_context (fun c -> { c with Execution_context.pat_scope = pat })
let with_channel channel = map_context (fun c -> { c with Execution_context.channel })

let with_requested list (r : D.request) =
  match list with
  | [] -> Alcotest.fail "a request names at least one effect"
  | first :: rest -> { r with D.requested = Effect_request.make first rest }
;;

let with_workspace workspace_id (r : D.request) = { r with D.workspace_id }
let pat ?expires_at pat_scope = Pat_binding.Pat { Pat_scope.scope = pat_scope; expires_at }

(* Fact changes. *)
let set_principal who value (f : D.facts) =
  { f with
    D.principal = (fun p -> if Principal.equal p who then value else f.D.principal p)
  }
;;

let set_membership who value (f : D.facts) =
  { f with
    D.membership =
      (fun p w -> if Principal.equal p who then value else f.D.membership p w)
  }
;;

let set_grant who value (f : D.facts) =
  { f with D.grant = (fun p r -> if Principal.equal p who then value else f.D.grant p r) }
;;

(* Replace the effects of [who]'s stored grant. *)
let narrow_grant who base list =
  set_grant who (found { base with Runtime_grant.allowed_effects = effects list })
;;

let set_policy value (f : D.facts) =
  { f with D.delegate_policy = (fun ~initiator:_ ~executor:_ -> value) }
;;

let set_runtime value (f : D.facts) = { f with D.runtime = (fun _ -> value) }
let set_account value (f : D.facts) = { f with D.provider_account = (fun _ -> value) }
let set_binding value (f : D.facts) = { f with D.auth_binding = value }
let set_dependencies value (f : D.facts) = { f with D.dependencies = value }

let set_revocation subject value (f : D.facts) =
  { f with
    D.revocation =
      (fun s -> if Subject.equal s subject then value else f.D.revocation s)
  }
;;

let set_all_revocations value (f : D.facts) = { f with D.revocation = (fun _ -> value) }

let show = function
  | D.Allow { D.initiator_grant; executor_grant; policy } ->
    Printf.sprintf
      "allow(%s,%s,%s)"
      (Grant_id.to_string initiator_grant)
      (Grant_id.to_string executor_grant)
      (match policy with
       | Some id -> Policy_id.to_string id
       | None -> "-")
  | D.Deny reason -> "deny:" ^ D.deny_reason_to_string reason
;;

let deny label = "deny:" ^ label
let uncertain = deny "authorization_uncertain"
let allow_self = "allow(g-alice,g-alice,-)"
let allow_delegated = "allow(g-bob,g-keeper,p-1)"

type row =
  { name : string
  ; facts : D.facts
  ; request : D.request
  ; expected : string
  }

let self ?(f = Fun.id) ?(r = Fun.id) name expected =
  { name; facts = f base_facts; request = r self_request; expected }
;;

let via_keeper ?(f = Fun.id) ?(r = Fun.id) name expected =
  { name; facts = f base_facts; request = r delegated_request; expected }
;;

let stranger ?(f = Fun.id) name expected =
  { name; facts = f base_facts; request = stranger_request; expected }
;;

let run_row row =
  Alcotest.test_case row.name `Quick (fun () ->
    Alcotest.(check string) row.name row.expected (show (D.allowed row.facts row.request)))
;;

let group name rows = name, List.map run_row rows

let baseline =
  group
    "baseline"
    [ self "own Runtime, Direct, no PAT" allow_self
    ; via_keeper "initiator through executor under a stored policy" allow_delegated
    ; self
        "PAT with room for the request"
        ~r:(with_pat (pat ~expires_at:(Float.succ now) (scope ())))
        allow_self
    ]
;;

let principals =
  group
    "principal active"
    [ self
        "initiator disabled"
        ~f:(set_principal alice (found Principal_status.Disabled))
        (deny "principal_inactive:initiator")
    ; self
        "initiator deleted"
        ~f:(set_principal alice D.Absent)
        (deny "principal_inactive:initiator")
    ; via_keeper
        "initiator disabled, executor fine"
        ~f:(set_principal bob (found Principal_status.Disabled))
        (deny "principal_inactive:initiator")
    ; via_keeper
        "initiator deleted, executor fine"
        ~f:(set_principal bob D.Absent)
        (deny "principal_inactive:initiator")
    ; via_keeper
        "executor disabled"
        ~f:(set_principal keeper (found Principal_status.Disabled))
        (deny "principal_inactive:executor")
    ; via_keeper
        "executor deleted"
        ~f:(set_principal keeper D.Absent)
        (deny "principal_inactive:executor")
    ]
;;

let bindings =
  group
    "auth binding"
    [ self
        "revoked"
        ~f:(set_binding (fun _ -> found Auth_binding_status.Revoked))
        (deny "auth_binding_inactive")
    ; self "absent" ~f:(set_binding (fun _ -> D.Absent)) (deny "auth_binding_inactive")
    ; self
        "the request's credential belongs to someone else"
        ~f:
          (set_binding (fun who ->
             if Principal.equal who carol then found Auth_binding_status.Active else D.Absent))
        (deny "auth_binding_inactive")
    ; via_keeper
        "the initiator's binding is the one that counts"
        ~f:
          (set_binding (fun who ->
             if Principal.equal who keeper then found Auth_binding_status.Active else D.Absent))
        (deny "auth_binding_inactive")
    ]
;;

let memberships =
  group
    "membership"
    [ self
        "initiator disabled"
        ~f:(set_membership alice (found Membership_status.Disabled))
        (deny "membership_inactive:initiator")
    ; self
        "initiator has none"
        ~f:(set_membership alice D.Absent)
        (deny "membership_inactive:initiator")
    ; self
        "member of another workspace only"
        ~r:(with_workspace other_ws)
        (deny "membership_inactive:initiator")
    ; via_keeper
        "initiator disabled, executor fine"
        ~f:(set_membership bob (found Membership_status.Disabled))
        (deny "membership_inactive:initiator")
    ; via_keeper
        "initiator has none, executor fine"
        ~f:(set_membership bob D.Absent)
        (deny "membership_inactive:initiator")
    ; via_keeper
        "executor disabled"
        ~f:(set_membership keeper (found Membership_status.Disabled))
        (deny "membership_inactive:executor")
    ]
;;

let pat_expiry =
  group
    "PAT expiry"
    [ self "deadline is now" ~r:(with_pat (pat ~expires_at:now (scope ()))) (deny "pat_expired")
    ; self
        "deadline passed"
        ~r:(with_pat (pat ~expires_at:(Float.pred now) (scope ())))
        (deny "pat_expired")
    ; self
        "deadline not a number"
        ~r:(with_pat (pat ~expires_at:Float.nan (scope ())))
        (deny "pat_expired")
    ; self "no deadline" ~r:(with_pat (pat (scope ()))) allow_self
    ]
;;

(* Design 4.4: a PAT that asks for a management effect must name the channel
   and the effects. Alice's grant allows the management effects below, so only
   the PAT can stop them. *)
let pat_naming =
  let manage = Effect.[ Invoke_model; Manage_own_provider; Admin_disable_block ] in
  let alice_manages = narrow_grant alice alice_grant manage in
  let request_effect kind = with_requested [ kind ] in
  let direct_only = channels_only [ Channel.Direct ] in
  group
    "PAT naming"
    [ self
        "effects are All"
        ~f:alice_manages
        ~r:(fun r ->
          request_effect Effect.Manage_own_provider r
          |> with_pat (pat (scope ~channels:direct_only ())))
        (deny "pat_scope_not_explicit")
    ; self
        "channels are All"
        ~f:alice_manages
        ~r:(fun r ->
          request_effect Effect.Manage_own_provider r
          |> with_pat (pat (scope ~allowed_effects:(effects_only [ Effect.Manage_own_provider ]) ())))
        (deny "pat_scope_not_explicit")
    ; self
        "both named"
        ~f:alice_manages
        ~r:(fun r ->
          request_effect Effect.Manage_own_provider r
          |> with_pat
               (pat
                  (scope
                     ~channels:direct_only
                     ~allowed_effects:(effects_only [ Effect.Manage_own_provider ])
                     ())))
        allow_self
    ; self
        "Admin_disable_block is held to the same rule"
        ~f:alice_manages
        ~r:(fun r ->
          request_effect Effect.Admin_disable_block r
          |> with_pat (pat (scope ~channels:direct_only ())))
        (deny "pat_scope_not_explicit")
    ; self
        "an empty channel set is named, and then denied as a channel"
        ~f:alice_manages
        ~r:(fun r ->
          request_effect Effect.Manage_own_provider r
          |> with_pat
               (pat
                  (scope
                     ~channels:Channel_scope.empty
                     ~allowed_effects:(effects_only [ Effect.Manage_own_provider ])
                     ())))
        (deny "channel_out_of_scope")
    ; self
        "no PAT"
        ~f:alice_manages
        ~r:(request_effect Effect.Manage_own_provider)
        allow_self
    ; self
        "a wildcard PAT may still invoke the model"
        ~r:(with_pat (pat (scope ())))
        allow_self
    ]
;;

let invocation =
  let own_channels =
    Channel.
      [ "Delegate", Delegate
      ; "Schedule", Schedule
      ; "Board_trigger", Board_trigger
      ; "Retry", Retry
      ; "Resume", Resume
      ; "Fusion", Fusion
      ; "Vision", Vision
      ; "Verifier", Verifier
      ; "Autonomous", Autonomous
      ]
  in
  let policy_with scope = set_policy (found { bob_to_keeper with Delegate_policy.scope }) in
  let delegate_only = channels_only [ Channel.Delegate ] in
  group
    "invocation"
    (List.map
       (fun (label, channel) ->
         self
           ("own request on " ^ label ^ " needs a policy")
           ~r:(with_channel channel)
           (deny "invocation_not_allowed"))
       own_channels
     @ [ via_keeper
           "another principal needs a policy"
           ~f:(set_policy D.Absent)
           (deny "invocation_not_allowed")
       ; via_keeper
           "a policy stored for the reverse pair does not apply"
           ~r:
             (map_context (fun c ->
                { c with Execution_context.initiator = keeper; executor = bob }))
           (deny "invocation_not_allowed")
       ; via_keeper
           "store answers with a policy for another initiator"
           ~f:(set_policy (found { bob_to_keeper with Delegate_policy.initiator = alice }))
           uncertain
       ; via_keeper
           "store answers with a policy for another executor"
           ~f:(set_policy (found { bob_to_keeper with Delegate_policy.executor = alice }))
           uncertain
       ; via_keeper
           "policy does not cover the channel"
           ~r:(with_channel Channel.Direct)
           (deny "channel_out_of_scope")
       ; via_keeper
           "policy allows no runtime"
           ~f:(policy_with (scope ~runtimes:Runtime_scope.empty ~channels:delegate_only ()))
           (deny "runtime_out_of_scope")
       ; via_keeper
           "policy names another runtime"
           ~f:
             (policy_with
                (scope ~runtimes:(runtimes_only [ other_rt ]) ~channels:delegate_only ()))
           (deny "runtime_out_of_scope")
       ; via_keeper
           "policy allows no channel"
           ~f:(policy_with (scope ~channels:Channel_scope.empty ()))
           (deny "channel_out_of_scope")
       ; via_keeper
           "policy allows no effect"
           ~f:(policy_with (scope ~channels:delegate_only ~allowed_effects:Effect_scope.empty ()))
           (deny "effects_out_of_scope:invoke_model")
       ])
;;

let resources =
  let blocking =
    Resource_status.
      [ Disabled, "disabled"
      ; Blocked, "blocked"
      ; Quarantined, "quarantined"
      ; Purged, "purged"
      ]
  in
  group
    "runtime and provider account"
    (List.map
       (fun (status, label) ->
         self
           ("runtime " ^ label)
           ~f:(set_runtime (found (runtime_row status)))
           (deny ("runtime_unavailable:" ^ label)))
       blocking
     @ List.map
         (fun (status, label) ->
           self
             ("provider account " ^ label)
             ~f:(set_account (found status))
             (deny ("provider_account_unavailable:" ^ label)))
         blocking
     @ [ self
           "provider account unknown to a store that knows the Runtime"
           ~f:(set_account D.Absent)
           uncertain
       ; self
           "the store answers with another Runtime"
           ~f:(set_runtime (found { (runtime_row Resource_status.Active) with Runtime_row.id = other_rt }))
           uncertain
       ])
;;

(* A requester without a grant must not learn anything about a Runtime it has
   no right to see (design 4.2). *)
let no_grant_reveals_nothing =
  group
    "requester without a grant"
    [ stranger "Runtime in good standing" (deny "grant_not_current:initiator:no_grant")
    ; stranger
        "Runtime does not exist"
        ~f:(set_runtime D.Absent)
        (deny "grant_not_current:initiator:no_grant")
    ; stranger
        "Runtime disabled"
        ~f:(set_runtime (found (runtime_row Resource_status.Disabled)))
        (deny "grant_not_current:initiator:no_grant")
    ; stranger
        "provider account quarantined"
        ~f:(set_account (found Resource_status.Quarantined))
        (deny "grant_not_current:initiator:no_grant")
    ; self
        "an unknown Runtime reads the same for its owner"
        ~f:(set_runtime D.Absent)
        (deny "grant_not_current:initiator:no_grant")
    ]
;;

let owner_standing =
  group
    "owner standing"
    [ via_keeper
        "owner disabled"
        ~f:(set_principal alice (found Principal_status.Disabled))
        (deny "principal_inactive:owner")
    ; via_keeper
        "owner deleted"
        ~f:(set_principal alice D.Absent)
        (deny "principal_inactive:owner")
    ; via_keeper
        "owner membership disabled"
        ~f:(set_membership alice (found Membership_status.Disabled))
        (deny "membership_inactive:owner")
    ; via_keeper
        "owner has no membership"
        ~f:(set_membership alice D.Absent)
        (deny "membership_inactive:owner")
    ; self
        "the owner running its own Runtime is checked once, as the initiator"
        ~f:(set_principal alice (found Principal_status.Disabled))
        (deny "principal_inactive:initiator")
    ]
;;

let grants =
  let expiring deadline =
    set_grant
      keeper
      (found
         { keeper_grant with
           Runtime_grant.kind = Runtime_grant.Delegated { expires_at = Some deadline }
         })
  in
  group
    "current grant"
    [ self
        "initiator has none"
        ~f:(set_grant alice D.Absent)
        (deny "grant_not_current:initiator:no_grant")
    ; via_keeper
        "initiator has none, executor holds one"
        ~f:(set_grant bob D.Absent)
        (deny "grant_not_current:initiator:no_grant")
    ; via_keeper
        "executor has none, initiator holds one"
        ~f:(set_grant keeper D.Absent)
        (deny "grant_not_current:executor:no_grant")
    ; self
        "revoked"
        ~f:
          (set_grant
             alice
             (found { alice_grant with Runtime_grant.status = Grant_status.Revoked }))
        (deny "grant_not_current:initiator:grant_revoked")
    ; via_keeper
        "initiator's grant revoked, executor's current"
        ~f:
          (set_grant
             bob
             (found { bob_grant with Runtime_grant.status = Grant_status.Revoked }))
        (deny "grant_not_current:initiator:grant_revoked")
    ; self
        "purged"
        ~f:
          (set_grant
             alice
             (found { alice_grant with Runtime_grant.status = Grant_status.Purged }))
        (deny "grant_not_current:initiator:grant_purged")
    ; via_keeper
        "Delegated grant expires at now"
        ~f:(expiring now)
        (deny "grant_not_current:executor:grant_expired")
    ; via_keeper "Delegated grant expires later" ~f:(expiring (Float.succ now)) allow_delegated
    ; self
        "Self grant of someone who is not the owner"
        ~f:
          (set_runtime
             (found { (runtime_row Resource_status.Active) with Runtime_row.owner = bob }))
        (deny "grant_not_current:initiator:grantee_not_owner")
    ; self
        "store answers with a grant for another runtime"
        ~f:(set_grant alice (found { alice_grant with Runtime_grant.runtime_id = other_rt }))
        uncertain
    ; self
        "store answers with a grant for another grantee"
        ~f:(set_grant alice (found { alice_grant with Runtime_grant.grantee = bob }))
        uncertain
    ]
;;

let runtime_scope =
  group
    "runtime scope"
    [ self
        "stored scope allows no runtime"
        ~r:(with_stored_scope (scope ~runtimes:Runtime_scope.empty ()))
        (deny "runtime_out_of_scope")
    ; self
        "stored scope names another runtime"
        ~r:(with_stored_scope (scope ~runtimes:(runtimes_only [ other_rt ]) ()))
        (deny "runtime_out_of_scope")
    ; self
        "stored scope names this runtime"
        ~r:(with_stored_scope (scope ~runtimes:(runtimes_only [ other_rt; rt ]) ()))
        allow_self
    ; self
        "PAT allows no runtime"
        ~r:(with_pat (pat (scope ~runtimes:Runtime_scope.empty ())))
        (deny "runtime_out_of_scope")
    ; self
        "PAT names another runtime"
        ~r:(with_pat (pat (scope ~runtimes:(runtimes_only [ other_rt ]) ())))
        (deny "runtime_out_of_scope")
    ]
;;

let channel_scope =
  group
    "channel scope"
    [ self
        "stored scope allows no channel"
        ~r:(with_stored_scope (scope ~channels:Channel_scope.empty ()))
        (deny "channel_out_of_scope")
    ; self
        "stored scope names another channel"
        ~r:(with_stored_scope (scope ~channels:(channels_only [ Channel.Retry ]) ()))
        (deny "channel_out_of_scope")
    ; self
        "PAT allows no channel"
        ~r:(with_pat (pat (scope ~channels:Channel_scope.empty ())))
        (deny "channel_out_of_scope")
    ; self
        "PAT names another channel"
        ~r:(with_pat (pat (scope ~channels:(channels_only [ Channel.Schedule ]) ())))
        (deny "channel_out_of_scope")
    ; self
        "PAT names the channel"
        ~r:(with_pat (pat (scope ~channels:(channels_only [ Channel.Direct ]) ())))
        allow_self
    ]
;;

(* Each row removes the requested effect from exactly one source. *)
let effect_scope =
  group
    "effects"
    [ self
        "stored scope allows no effect"
        ~r:(with_stored_scope (scope ~allowed_effects:Effect_scope.empty ()))
        (deny "effects_out_of_scope:invoke_model")
    ; self
        "stored scope lacks the effect"
        ~r:(with_stored_scope (scope ~allowed_effects:(effects_only [ Effect.Use_tool ]) ()))
        (deny "effects_out_of_scope:invoke_model")
    ; self
        "grant lacks the effect"
        ~f:(narrow_grant alice alice_grant [ Effect.Use_tool ])
        (deny "effects_out_of_scope:invoke_model")
    ; self
        "grant allows no effect"
        ~f:(narrow_grant alice alice_grant [])
        (deny "effects_out_of_scope:invoke_model")
    ; via_keeper
        "initiator grant lacks the effect"
        ~f:(narrow_grant bob bob_grant [ Effect.Read_state ])
        (deny "effects_out_of_scope:invoke_model")
    ; via_keeper
        "executor grant lacks the effect"
        ~f:(narrow_grant keeper keeper_grant [ Effect.Use_tool ])
        (deny "effects_out_of_scope:invoke_model")
    ; via_keeper
        "policy lacks the effect"
        ~f:(narrow_grant keeper keeper_grant Effect.[ Invoke_model; Read_state ])
        ~r:(with_requested [ Effect.Read_state ])
        (deny "effects_out_of_scope:read_state")
    ; self
        "PAT lacks the effect"
        ~r:(with_pat (pat (scope ~allowed_effects:(effects_only [ Effect.Use_tool ]) ())))
        (deny "effects_out_of_scope:invoke_model")
    ; self
        "PAT allows no effect"
        ~r:(with_pat (pat (scope ~allowed_effects:Effect_scope.empty ())))
        (deny "effects_out_of_scope:invoke_model")
    ; self
        "only the uncovered effects are named"
        ~r:(with_requested Effect.[ Invoke_model; Use_tool; Read_state; Manage_own_grant ])
        (deny "effects_out_of_scope:manage_own_grant,read_state")
    ; self
        "every requested effect is covered"
        ~r:(with_requested Effect.[ Invoke_model; Use_tool ])
        allow_self
    ; self
        "All filters stay inside the grant"
        ~r:(with_requested [ Effect.Read_audit_metadata ])
        (deny "effects_out_of_scope:read_audit_metadata")
    ]
;;

let pending_revocation =
  let subjects =
    [ Subject.Principal bob
    ; Subject.Principal keeper
    ; Subject.Principal alice
    ; Subject.Grant bob_grant.Runtime_grant.id
    ; Subject.Grant keeper_grant.Runtime_grant.id
    ; Subject.Runtime rt
    ; Subject.Credential account
    ]
  in
  group
    "revocation pending"
    (List.map
       (fun subject ->
         via_keeper
           ("pending on " ^ Subject.to_string subject)
           ~f:(set_revocation subject (found Revocation_state.Pending))
           (deny ("revocation_pending:" ^ Subject.to_string subject)))
       subjects
     @ [ self "no answer for the subject" ~f:(set_all_revocations D.Absent) uncertain ])
;;

(* Design 3-9 and 10.1: a chain that is not cleared stops only the requests
   that stand on it. *)
let dependencies =
  let uncleared_when_standing_on grant_id (chain : D.Chain.t) =
    if List.exists (Grant_id.equal grant_id) chain.D.Chain.grants
    then found Dependency_state.Not_cleared
    else found Dependency_state.Cleared
  in
  let keeper_chain = uncleared_when_standing_on keeper_grant.Runtime_grant.id in
  group
    "dependencies"
    [ self
        "not cleared"
        ~f:(set_dependencies (fun _ -> found Dependency_state.Not_cleared))
        (deny "dependencies_not_cleared")
    ; self "no answer" ~f:(set_dependencies (fun _ -> D.Absent)) uncertain
    ; via_keeper
        "the chain through the keeper's grant is not cleared"
        ~f:(set_dependencies keeper_chain)
        (deny "dependencies_not_cleared")
    ; self
        "a request on another chain still runs"
        ~f:(set_dependencies keeper_chain)
        allow_self
    ]
;;

(* The decision asks about exactly the records it stands on. *)
let chain_names_what_the_decision_stood_on () =
  let asked = ref [] in
  let record (chain : D.Chain.t) =
    asked := chain :: !asked;
    found Dependency_state.Cleared
  in
  let facts = set_dependencies record base_facts in
  Alcotest.(check string) "allowed" allow_delegated (show (D.allowed facts delegated_request));
  match !asked with
  | [ chain ] ->
    let names to_string items = List.map to_string items in
    Alcotest.(check (list string))
      "principals: initiator, executor, owner"
      (names Principal.to_string [ bob; keeper; alice ])
      (names Principal.to_string chain.D.Chain.principals);
    Alcotest.(check (list string))
      "grants: initiator's, executor's"
      [ "g-bob"; "g-keeper" ]
      (names Grant_id.to_string chain.D.Chain.grants);
    Alcotest.(check (option string))
      "policy"
      (Some "p-1")
      (Option.map Policy_id.to_string chain.D.Chain.policy);
    Alcotest.(check string) "runtime" "rt-1" (Runtime_id.to_string chain.D.Chain.runtime_id);
    Alcotest.(check string)
      "provider account"
      "pa-1"
      (Provider_account_id.to_string chain.D.Chain.provider_account)
  | chains -> Alcotest.failf "expected one dependency question, got %d" (List.length chains)
;;

(* Two reasons must never share a label, or a test that compares labels could
   pass for the wrong reason. [index] is an exhaustive match, so a new reason
   cannot be added without this test. *)
let reason_labels_are_distinct () =
  let index = function
    | D.Authorization_uncertain -> 0
    | D.Principal_inactive _ -> 1
    | D.Auth_binding_inactive -> 2
    | D.Membership_inactive _ -> 3
    | D.Pat_expired -> 4
    | D.Pat_scope_not_explicit -> 5
    | D.Invocation_not_allowed -> 6
    | D.Initiator_grant_not_current _ -> 7
    | D.Executor_grant_not_current _ -> 8
    | D.Runtime_unavailable _ -> 9
    | D.Provider_account_unavailable _ -> 10
    | D.Runtime_out_of_scope -> 11
    | D.Channel_out_of_scope -> 12
    | D.Effects_out_of_scope _ -> 13
    | D.Revocation_pending _ -> 14
    | D.Dependencies_not_cleared -> 15
  in
  let parties = [ D.Initiator; D.Executor; D.Owner ] in
  let grant_defects =
    D.[ No_grant; Grant_revoked; Grant_purged; Grant_expired; Grantee_not_owner ]
  in
  let resource_defects =
    D.[ Resource_disabled; Resource_blocked; Resource_quarantined; Resource_purged ]
  in
  let reasons =
    [ D.Authorization_uncertain
    ; D.Auth_binding_inactive
    ; D.Pat_expired
    ; D.Pat_scope_not_explicit
    ; D.Invocation_not_allowed
    ; D.Runtime_out_of_scope
    ; D.Channel_out_of_scope
    ; D.Effects_out_of_scope (effects [ Effect.Read_state ])
    ; D.Effects_out_of_scope (effects [ Effect.Use_tool ])
    ; D.Revocation_pending (Subject.Runtime rt)
    ; D.Revocation_pending (Subject.Credential account)
    ; D.Dependencies_not_cleared
    ]
    @ List.map (fun party -> D.Principal_inactive party) parties
    @ List.map (fun party -> D.Membership_inactive party) parties
    @ List.map (fun defect -> D.Initiator_grant_not_current defect) grant_defects
    @ List.map (fun defect -> D.Executor_grant_not_current defect) grant_defects
    @ List.map (fun defect -> D.Runtime_unavailable defect) resource_defects
    @ List.map (fun defect -> D.Provider_account_unavailable defect) resource_defects
  in
  let labels = List.map D.deny_reason_to_string reasons in
  Alcotest.(check int)
    "every label is different"
    (List.length labels)
    (List.length (List.sort_uniq String.compare labels));
  Alcotest.(check (list int))
    "the list holds every kind of reason"
    (List.init 16 Fun.id)
    (List.sort_uniq Int.compare (List.map index reasons))
;;

(* No fact is optional: whichever one the store cannot read, the answer is
   [Authorization_uncertain]. The delegated world reads every fact. *)
let unreadable =
  group
    "unreadable store"
    [ via_keeper "initiator principal" ~f:(set_principal bob D.Unreadable) uncertain
    ; via_keeper "executor principal" ~f:(set_principal keeper D.Unreadable) uncertain
    ; via_keeper "auth binding" ~f:(set_binding (fun _ -> D.Unreadable)) uncertain
    ; via_keeper "membership" ~f:(set_membership keeper D.Unreadable) uncertain
    ; via_keeper "policy" ~f:(set_policy D.Unreadable) uncertain
    ; via_keeper "runtime" ~f:(set_runtime D.Unreadable) uncertain
    ; via_keeper "provider account" ~f:(set_account D.Unreadable) uncertain
    ; via_keeper "initiator grant" ~f:(set_grant bob D.Unreadable) uncertain
    ; via_keeper "executor grant" ~f:(set_grant keeper D.Unreadable) uncertain
    ; via_keeper "owner principal" ~f:(set_principal alice D.Unreadable) uncertain
    ; via_keeper "owner membership" ~f:(set_membership alice D.Unreadable) uncertain
    ; via_keeper "revocation" ~f:(set_all_revocations D.Unreadable) uncertain
    ; via_keeper "dependencies" ~f:(set_dependencies (fun _ -> D.Unreadable)) uncertain
    ]
;;

let () =
  Alcotest.run
    "authz_decision"
    [ baseline
    ; principals
    ; bindings
    ; memberships
    ; pat_expiry
    ; pat_naming
    ; invocation
    ; resources
    ; no_grant_reveals_nothing
    ; owner_standing
    ; grants
    ; runtime_scope
    ; channel_scope
    ; effect_scope
    ; pending_revocation
    ; dependencies
    ; ( "chain"
      , [ Alcotest.test_case
            "names what the decision stood on"
            `Quick
            chain_names_what_the_decision_stood_on
        ] )
    ; "labels", [ Alcotest.test_case "every label is different" `Quick reason_labels_are_distinct ]
    ; unreadable
    ]
;;

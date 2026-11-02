(* Whether a provider needs a credential, and what happens when nothing says.

   A selected keyless catalog row and an unknown provider remain distinct.
   Reading both as an absent credential let model discovery report success
   without a credential contract (#35651). *)

open Alcotest

(* Declared in packages/agent_core/models.toml with no required key. Local, so no network
   reachability is implied by naming it here. *)
let keyless_catalog_provider = "ollama"

(* No catalog row and no prefix that resolves to one. A colon would invite
   [resolve_provider_prefix] to find a registered prefix, so there is none. *)
let provider_with_no_catalog_row = "no-such-provider-in-the-catalog"

let selected_requirement provider_id =
  match Runtime_adapter.materialize_credentials ~provider_id ~credential:None with
  | Error detail -> fail detail
  | Ok selected -> Runtime_credential_selection.requirement selected.admission

let discovery_key ~provider_id ~credential =
  Result.bind (Runtime_adapter.materialize_credentials ~provider_id ~credential)
    Runtime_credential_selection.require_key

let test_the_two_absences_are_different_answers () =
  (match
     selected_requirement keyless_catalog_provider
   with
   | Runtime_credential_selection.Not_required -> ()
   | Required_env _ | Required_inline | Required_file -> fail "a keyless catalog row must not name a credential"
   | Required_undeclared ->
     fail "a keyless catalog row does not ask the deployment for a credential"
   | Unknown_provider -> fail "a provider in the catalog is not unknown");
  match
    selected_requirement provider_with_no_catalog_row
  with
  | Runtime_credential_selection.Unknown_provider -> ()
  | Not_required -> fail "no catalog row is not the same as a row saying no key is needed"
  | Required_undeclared ->
    fail "no catalog row is not the same as a row that requires a key"
  | Required_env _ | Required_inline | Required_file -> fail "nothing names a credential here"

let test_a_provider_with_no_catalog_row_is_refused () =
  match
    discovery_key ~provider_id:provider_with_no_catalog_row
      ~credential:None
  with
  | Ok _ -> fail "an unnamed credential for an unknown provider must not resolve"
  | Error detail ->
    (* The refusal has to say the provider is the reason, not read as a
       transient lookup failure. *)
    check bool "the refusal names the missing catalog row" true
      (String_util.contains_substring detail "catalog")

let test_a_keyless_catalog_provider_still_resolves () =
  match
    discovery_key ~provider_id:keyless_catalog_provider ~credential:None
  with
  | Error detail -> failf "a keyless provider must still resolve: %s" detail
  | Ok secret ->
    check bool "and it resolves to no secret" true (Llm_provider.Secret.is_empty secret)

let test_an_explicit_credential_carries_an_unknown_provider () =
  (* The refusal above is about an absent credential, not about the provider
     being unfamiliar: an operator who names one is answered. *)
  match
    discovery_key ~provider_id:provider_with_no_catalog_row
      ~credential:(Some (Runtime_schema.Inline "test-inline-value"))
  with
  | Error detail -> failf "an explicit credential must resolve: %s" detail
  | Ok secret ->
    check bool "the named credential is what came back" false
      (Llm_provider.Secret.is_empty secret)

let () =
  run "runtime adapter credential requirement"
    [ ( "requirement"
      , [ test_case "the two absences are different answers" `Quick
            test_the_two_absences_are_different_answers
        ; test_case "a provider with no catalog row is refused" `Quick
            test_a_provider_with_no_catalog_row_is_refused
        ; test_case "a keyless catalog provider still resolves" `Quick
            test_a_keyless_catalog_provider_still_resolves
        ; test_case "an explicit credential carries an unknown provider" `Quick
            test_an_explicit_credential_carries_an_unknown_provider
        ] )
    ]

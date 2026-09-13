(* Whether a provider needs a credential, and what happens when nothing says.

   [effective_credential_reference] used to answer [None] for two unrelated
   situations: a catalog row that declares an empty [api_key_env] (a provider
   that takes no key), and a provider with no catalog row at all (nothing has
   said either way). Reading them as one answer let model discovery resolve an
   empty secret and report success without a credential (#35651). *)

open Alcotest

(* Declared in packages/agent_core/models.toml with [api_key_env = ""], which
   is how the catalog says a provider takes no key. Local, so no network
   reachability is implied by naming it here. *)
let keyless_catalog_provider = "ollama"

(* No catalog row and no prefix that resolves to one. A colon would invite
   [resolve_provider_prefix] to find a registered prefix, so there is none. *)
let provider_with_no_catalog_row = "no-such-provider-in-the-catalog"

let test_the_two_absences_are_different_answers () =
  (match
     Runtime_adapter.credential_requirement ~provider_id:keyless_catalog_provider None
   with
   | Runtime_adapter.Not_required -> ()
   | Reference _ -> fail "a keyless catalog row must not name a credential"
   | Unknown_provider -> fail "a provider in the catalog is not unknown");
  match
    Runtime_adapter.credential_requirement ~provider_id:provider_with_no_catalog_row None
  with
  | Runtime_adapter.Unknown_provider -> ()
  | Not_required -> fail "no catalog row is not the same as a row saying no key is needed"
  | Reference _ -> fail "nothing names a credential here"

let test_a_provider_with_no_catalog_row_is_refused () =
  match
    Runtime_adapter.resolve_api_key ~provider_id:provider_with_no_catalog_row
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
    Runtime_adapter.resolve_api_key ~provider_id:keyless_catalog_provider ~credential:None
  with
  | Error detail -> failf "a keyless provider must still resolve: %s" detail
  | Ok secret ->
    check bool "and it resolves to no secret" true (Llm_provider.Secret.is_empty secret)

let test_an_explicit_credential_carries_an_unknown_provider () =
  (* The refusal above is about an absent credential, not about the provider
     being unfamiliar: an operator who names one is answered. *)
  match
    Runtime_adapter.resolve_api_key ~provider_id:provider_with_no_catalog_row
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

(** Pin the typed classification of the MASC-internal "Eio context
    unavailable" error ([Runtime_oas_runner.is_eio_context_error]).

    Before this suite the heartbeat loop
    ([keeper_heartbeat_loop_cycle.ml]) decided whether a failed keeper cycle
    was a fatal-environment error — and therefore whether to promote it to
    [Keeper_registry.Keeper_fiber_crash] for the supervisor — by
    substring-scanning [Agent_sdk.Error.to_string]:

      String_util.contains_substring e_str "Eio switch not available"

    That coupled a safety-critical promotion to the exact Eio wording. It
    would (a) silently MISS the error if the wording changed, and (b)
    WRONGLY MATCH any unrelated error whose rendered message merely contained
    the phrase. The classifier is now structural — the typed
    [Config (InvalidConfig { field = "eio_context" })] tag — and this suite
    locks both directions so a regression to substring matching fails here. *)

module R = Runtime_oas_runner

(* The error this module produces is classified true, regardless of which of
   the two context-missing diagnostics it carries. *)
let test_tagged_error_is_eio_context () =
  assert (
    R.is_eio_context_error
      (R.eio_context_error_to_sdk_error
         "Eio switch not available (running outside server context)"));
  assert (
    R.is_eio_context_error
      (R.eio_context_error_to_sdk_error
         "Eio net not available (running outside server context)"))

(* Robustness (the OLD substring matcher would MISS this): a future change to
   the Eio diagnostic wording must not drop the fatal-environment
   classification, because the typed [field] tag — not the message — is the
   discriminator. *)
let test_wording_independence () =
  assert (
    R.is_eio_context_error
      (R.eio_context_error_to_sdk_error "totally different diagnostic wording"))

(* Precision (the OLD substring matcher would WRONGLY match this): a
   runtime_id config error whose detail message happens to contain the Eio
   phrase must NOT be classified as eio-context — its [field] tag is
   "runtime_id", not "eio_context". *)
let test_other_config_field_excluded () =
  assert (
    not
      (R.is_eio_context_error
         (R.runtime_catalog_error_to_sdk_error "Eio switch not available")))

(* Non-Config error families are never eio-context, even when their message
   contains the phrase. *)
let test_non_config_errors_excluded () =
  assert (
    not (R.is_eio_context_error (Agent_sdk.Error.Internal "Eio switch not available")))

let () =
  test_tagged_error_is_eio_context ();
  test_wording_independence ();
  test_other_config_field_excluded ();
  test_non_config_errors_excluded ();
  print_endline "test_runtime_oas_eio_context_classify: OK"

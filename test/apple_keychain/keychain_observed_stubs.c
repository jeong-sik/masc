/* Dune can compile foreign objects for @check even when this macOS-only
 * test is disabled. Keep Security headers and the real fixture behind the
 * same platform guard as the production stub. Unexpected calls elsewhere
 * fail explicitly rather than inventing keychain or observation results. */
#ifdef __APPLE__
#include <Security/Security.h>

/* A headless runner may reject a prompt even if MASC left interaction enabled.
 * Observe the setting at the real API call to detect that regression without
 * relying on whether the runner can display UI. These counters are used only
 * by the sequential observed-fixture checks, before the concurrent tests. */
static int access_checks = 0;
static int interaction_violations = 0;

static void check_interaction_disabled(void) {
  Boolean allowed = true;
  if (SecKeychainGetUserInteractionAllowed(&allowed) != errSecSuccess || allowed)
    ++interaction_violations;
}

static OSStatus observed_copy_matching(CFDictionaryRef query, CFTypeRef *result) {
  ++access_checks;
  check_interaction_disabled();
  return SecItemCopyMatching(query, result);
}

/* Compile the production check again in its own translation unit. The
 * ordinary Apple_keychain entry point remains uninstrumented and is exercised
 * separately by the rest of the native integration test. */
#define SecItemCopyMatching observed_copy_matching
#define masc_antigravity_keychain_security_access masc_test_observed_security_access
#include "../../lib/apple_keychain/apple_keychain_stubs.c"
#undef masc_antigravity_keychain_security_access
#undef SecItemCopyMatching

CAMLprim value masc_test_observed_keychain_counts(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(counts);
  counts = caml_alloc_tuple(2);
  Store_field(counts, 0, Val_int(access_checks));
  Store_field(counts, 1, Val_int(interaction_violations));
  CAMLreturn(counts);
}

#else
#include <caml/mlvalues.h>
#include <caml/fail.h>

CAMLprim value masc_test_observed_security_access(value path) {
  (void)path;
  caml_failwith("macOS Keychain test fixtures require macOS");
}

CAMLprim value masc_test_observed_keychain_counts(value unit) {
  (void)unit;
  caml_failwith("macOS Keychain test fixtures require macOS");
}

#endif

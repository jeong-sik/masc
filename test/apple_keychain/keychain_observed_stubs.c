/* Dune can compile foreign objects for @check even when this macOS-only
 * test is disabled. Keep Security headers and the real fixture behind the
 * same platform guard as the production stub. Unexpected calls elsewhere
 * fail explicitly rather than inventing keychain or observation results. */
#ifdef __APPLE__
#include <Security/Security.h>

/* A headless runner may reject a prompt even if MASC left interaction enabled.
 * Observe the setting at both real API calls to detect that regression without
 * relying on whether the runner can display UI. These counters are used only
 * by the sequential observed-fixture checks, before the concurrent tests. */
static int read_checks = 0;
static int clear_checks = 0;
static int interaction_violations = 0;

static void check_interaction_disabled(void) {
  Boolean allowed = true;
  if (SecKeychainGetUserInteractionAllowed(&allowed) != errSecSuccess || allowed)
    ++interaction_violations;
}

static OSStatus observed_copy_matching(CFDictionaryRef query, CFTypeRef *result) {
  ++read_checks;
  check_interaction_disabled();
  return SecItemCopyMatching(query, result);
}

static OSStatus observed_delete(CFDictionaryRef query) {
  ++clear_checks;
  check_interaction_disabled();
  return SecItemDelete(query);
}

/* Compile the production operation again in its own translation unit. The
 * ordinary Apple_keychain entry point remains uninstrumented and is exercised
 * separately by the rest of the native integration test. */
#define SecItemCopyMatching observed_copy_matching
#define SecItemDelete observed_delete
#define masc_antigravity_keychain_item masc_test_observed_keychain_item
#include "../../lib/apple_keychain/apple_keychain_stubs.c"
#undef masc_antigravity_keychain_item
#undef SecItemDelete
#undef SecItemCopyMatching

CAMLprim value masc_test_observed_keychain_counts(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(counts);
  counts = caml_alloc_tuple(3);
  Store_field(counts, 0, Val_int(read_checks));
  Store_field(counts, 1, Val_int(clear_checks));
  Store_field(counts, 2, Val_int(interaction_violations));
  CAMLreturn(counts);
}

#else
#include <caml/mlvalues.h>
#include <caml/fail.h>

CAMLprim value masc_test_observed_keychain_item(value path, value remove_item) {
  (void)path;
  (void)remove_item;
  caml_failwith("macOS Keychain test fixtures require macOS");
}

CAMLprim value masc_test_observed_keychain_counts(value unit) {
  (void)unit;
  caml_failwith("macOS Keychain test fixtures require macOS");
}

#endif

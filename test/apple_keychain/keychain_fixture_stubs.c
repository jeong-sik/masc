#include <caml/mlvalues.h>
#include <caml/fail.h>
#include <Security/Security.h>
#include <string.h>

/* The creating executable gets its own trusted ACL/partition. The denied
 * fixture is created by security(1) instead, so it has a different owner. */
CAMLprim value masc_test_keychain_add_allowed(value path) {
  SecKeychainRef keychain = NULL;
  const char *credential = "dummy-antigravity-credential";
  OSStatus status = SecKeychainOpen(String_val(path), &keychain);
  if (status == errSecSuccess)
    status = SecKeychainAddGenericPassword(keychain, 6, "gemini", 11, "antigravity",
                                         (UInt32)strlen(credential), credential, NULL);
  if (keychain) CFRelease(keychain);
  if (status != errSecSuccess) caml_failwith("cannot add allowed fixture item");
  return Val_unit;
}

CAMLprim value masc_test_keychain_interaction_allowed(value unit) {
  (void)unit;
  Boolean allowed;
  if (SecKeychainGetUserInteractionAllowed(&allowed) != errSecSuccess)
    caml_failwith("cannot inspect fixture interaction setting");
  return Val_bool(allowed);
}

CAMLprim value masc_test_keychain_set_interaction(value allowed) {
  if (SecKeychainSetUserInteractionAllowed(Bool_val(allowed)) != errSecSuccess)
    caml_failwith("cannot set fixture interaction setting");
  return Val_unit;
}

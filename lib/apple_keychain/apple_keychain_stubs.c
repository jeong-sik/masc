#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <string.h>
#include <stdlib.h>
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#endif

/* security(1) find_first_generic_password collapses search errors to missing:
 * https://github.com/apple-oss-distributions/Security/blob/main/SecurityTool/macOS/keychain_find.c
 * Query Security directly, preserving locked/inaccessible vs absent. */
CAMLprim value masc_antigravity_keychain_item(value path, value remove_item) {
  CAMLparam2(path, remove_item);
  CAMLlocal2(result, text);
  int outcome = 2;
  text = caml_alloc_string(0);
#ifdef __APPLE__
  if (strlen(String_val(path)) != caml_string_length(path)) {
    outcome = 3;
  } else {
    char *owned_path = strdup(String_val(path));
    if (!owned_path) caml_raise_out_of_memory();
    int remove = Bool_val(remove_item);
    SecKeychainRef keychain = NULL;
    CFArrayRef search = NULL;
    CFMutableDictionaryRef query = NULL;
    CFTypeRef data = NULL;
    OSStatus status;
    SecKeychainStatus state = 0;
    caml_enter_blocking_section();
    status = SecKeychainOpen(owned_path, &keychain);
    free(owned_path);
    if (status == errSecSuccess) status = SecKeychainGetStatus(keychain, &state);
    if (status == errSecSuccess && !(state & kSecUnlockStateStatus))
      status = errSecInteractionNotAllowed;
    if (status == errSecSuccess) {
      const void *values[] = { keychain };
      search = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
      query = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                       &kCFTypeDictionaryValueCallBacks);
      if (!search || !query) status = errSecAllocate;
      else {
        CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
        CFDictionarySetValue(query, kSecAttrService, CFSTR("gemini"));
        CFDictionarySetValue(query, kSecAttrAccount, CFSTR("antigravity"));
        CFDictionarySetValue(query, kSecMatchSearchList, search);
        CFDictionarySetValue(query, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
        if (remove) status = SecItemDelete(query);
        else {
          CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
          CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
          status = SecItemCopyMatching(query, &data);
        }
      }
    }
    if (query) CFRelease(query);
    if (search) CFRelease(search);
    if (keychain) CFRelease(keychain);
    caml_leave_blocking_section();
    if (status == errSecItemNotFound) outcome = 1;
    else if (status != errSecSuccess) outcome = 3;
    else if (remove) outcome = 0;
    else if (data && CFGetTypeID(data) == CFDataGetTypeID()) {
      text = caml_alloc_initialized_string((mlsize_t)CFDataGetLength(data),
                                         (const char *)CFDataGetBytePtr(data));
      outcome = 0;
    } else outcome = 3;
    if (data) CFRelease(data);
  }
#endif
  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_int(outcome));
  Store_field(result, 1, text);
  CAMLreturn(result);
}

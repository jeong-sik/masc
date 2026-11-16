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
#include <pthread.h>

/* kSecUseAuthenticationUIFail does not suppress ACL prompts in file-based
 * keychains. SecKeychain's interaction setting is process-global: serialize
 * save/disable/query/restore, including callers on other OCaml domains.
 * Acquire only after releasing the OCaml runtime, and restore before taking
 * it again so an OCaml exception cannot leave UI disabled or the lock held. */
static pthread_mutex_t interaction_lock = PTHREAD_MUTEX_INITIALIZER;

/* agy writes its login through go-keyring, which runs security(1). The item's
 * decrypt ACL then names /usr/bin/security alone, so this process can never
 * read the value itself; security(1) can. */
static const char security_tool[] = "/usr/bin/security";

static int names_security_tool(CFDataRef data) {
  if (!data) return 0;
  CFIndex length = CFDataGetLength(data);
  const UInt8 *bytes = CFDataGetBytePtr(data);
  CFIndex tool_length = (CFIndex)strlen(security_tool);
  /* The trusted-application data is the path, NUL-terminated or not. */
  if (length == tool_length + 1 && bytes[tool_length] != 0) return 0;
  if (length != tool_length && length != tool_length + 1) return 0;
  return memcmp(bytes, security_tool, (size_t)tool_length) == 0;
}

/* HIGH-RISK-UNREVIEWED: whether security(1) may decrypt without a prompt. One
 * decrypt ACL must admit any application or name security(1), and must not
 * ask for the keychain password on every use. Anything else would raise a
 * dialog in security(1), so the caller must not run it. */
static int decrypt_admits_security_tool(SecKeychainItemRef item) {
  SecAccessRef access = NULL;
  if (SecKeychainItemCopyAccess(item, &access) != errSecSuccess || !access) return 0;
  CFArrayRef acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt);
  int admitted = 0;
  for (CFIndex i = 0; acls && !admitted && i < CFArrayGetCount(acls); i++) {
    CFArrayRef applications = NULL;
    CFStringRef description = NULL;
    SecKeychainPromptSelector prompt = 0;
    SecACLRef acl = (SecACLRef)CFArrayGetValueAtIndex(acls, i);
    if (SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess
        && !(prompt & kSecKeychainPromptRequirePassphase)) {
      if (!applications) admitted = 1;
      for (CFIndex j = 0; applications && !admitted && j < CFArrayGetCount(applications); j++) {
        CFDataRef data = NULL;
        SecTrustedApplicationRef application =
          (SecTrustedApplicationRef)CFArrayGetValueAtIndex(applications, j);
        if (SecTrustedApplicationCopyData(application, &data) == errSecSuccess)
          admitted = names_security_tool(data);
        if (data) CFRelease(data);
      }
    }
    if (applications) CFRelease(applications);
    if (description) CFRelease(description);
  }
  if (acls) CFRelease(acls);
  CFRelease(access);
  return admitted;
}
#endif

/* security(1) find_first_generic_password collapses search errors to missing:
 * https://github.com/apple-oss-distributions/Security/blob/main/SecurityTool/macOS/keychain_find.c
 * Query Security directly first, preserving locked/inaccessible vs absent,
 * and decide here whether security(1) may touch the item without a dialog.
 * 0 = present, unlocked and decryptable by security(1); 1 = absent;
 * 2 = not macOS; 3 = locked, not decryptable by security(1), or unreadable. */
CAMLprim value masc_antigravity_keychain_security_access(value path) {
  CAMLparam1(path);
  int outcome = 2;
#ifdef __APPLE__
  if (strlen(String_val(path)) != caml_string_length(path)) {
    outcome = 3;
  } else {
    char *owned_path = strdup(String_val(path));
    if (!owned_path) caml_raise_out_of_memory();
    SecKeychainRef keychain = NULL;
    CFArrayRef search = NULL;
    CFMutableDictionaryRef query = NULL;
    CFTypeRef item = NULL;
    OSStatus status;
    SecKeychainStatus state = 0;
    Boolean previous_interaction = false;
    int restore_interaction = 0;
    int admitted = 0;
    caml_enter_blocking_section();
    int locked = pthread_mutex_lock(&interaction_lock) == 0;
    status = locked ? SecKeychainGetUserInteractionAllowed(&previous_interaction)
                    : errSecNotAvailable;
    if (status == errSecSuccess) {
      restore_interaction = 1;
      status = SecKeychainSetUserInteractionAllowed(false);
    }
    if (status == errSecSuccess) status = SecKeychainOpen(owned_path, &keychain);
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
        /* A reference, not the value: no decrypt, so no ACL check here. */
        CFDictionarySetValue(query, kSecReturnRef, kCFBooleanTrue);
        CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
        status = SecItemCopyMatching(query, &item);
      }
    }
    if (status == errSecSuccess) {
      if (item && CFGetTypeID(item) == SecKeychainItemGetTypeID())
        admitted = decrypt_admits_security_tool((SecKeychainItemRef)item);
      else status = errSecInvalidItemRef;
    }
    if (item) CFRelease(item);
    if (query) CFRelease(query);
    if (search) CFRelease(search);
    if (keychain) CFRelease(keychain);
    if (restore_interaction) {
      OSStatus restored = SecKeychainSetUserInteractionAllowed(previous_interaction);
      if (restored != errSecSuccess) status = restored;
    }
    if (locked) pthread_mutex_unlock(&interaction_lock);
    caml_leave_blocking_section();
    if (status == errSecItemNotFound) outcome = 1;
    else if (status != errSecSuccess) outcome = 3;
    else outcome = admitted ? 0 : 3;
  }
#endif
  CAMLreturn(Val_int(outcome));
}

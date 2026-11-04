; What the boot reads for the account mode, on real files in a temporary
; directory: config.json, the authorization log, the install record and the
; external store, with installations made by the real Fresh_bootstrap.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_authz_boot_mode_read)
 (modules test_authz_boot_mode_read)
 (libraries masc_test_deps))

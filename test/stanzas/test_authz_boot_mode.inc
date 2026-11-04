; The boot judgment of the account mode on values built in memory, and the
; account_mode member of config.json. No files, clock, or network.
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable, and a stanza with an action sends the targeted CI runner down the
; alias path, where the whole build counts against the timeout of the suite.

(test
 (name test_authz_boot_mode)
 (modules test_authz_boot_mode)
 (libraries alcotest yojson masc.auth masc.masc_types))

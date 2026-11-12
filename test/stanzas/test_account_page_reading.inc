; The reading of the login of an account server page, as a browser parses the
; page (HTML through Markup_document). The suites that fetch such a page read
; it through this library (test_server_login_http, test_server_accounts), and
; the test below runs the reading over pages written by hand. The library does
; not list masc_test_deps, which test_server_accounts cannot link (see its
; stanza).
;
; There is no (action ...) field: the default action of a test stanza runs the
; executable.

(library
 (name account_page_reading)
 (wrapped false)
 (modules account_page_reading)
 (libraries alcotest markup masc.markup_document))

(test
 (name test_account_page_reading)
 (modules test_account_page_reading)
 (libraries alcotest account_page_reading))

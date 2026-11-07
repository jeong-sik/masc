; The login routes against the writer zone on real files, with a Google and a
; GitHub that the test plays: a sign-in from start to session, a new sign-in
; that ends the session of the browser, the refused starts, callbacks,
; sign-outs and reads, and the escaped path of the completion page. No
; network.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_login_routes)
 (modules test_login_routes)
 (libraries masc_test_deps jose mirage-crypto-pk digestif ptime))

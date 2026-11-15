; #32910: an HTTP/1.1 client that leaves a waiting GitHub login stops the
; login's gh. The route's keepalive turns the departure into a closed response;
; its interval runs on a mock clock.

(test
 (name test_keeper_github_login_h1_close)
 (modules test_keeper_github_login_h1_close)
 (libraries masc_test_deps masc.server eio.mock httpun gluten cstruct))

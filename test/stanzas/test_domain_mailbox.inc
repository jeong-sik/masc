; Operations sent from other domains reach one fiber in order, and each is
; handled, left unhandled or refused exactly once when the mailbox ends.

(test
 (name test_domain_mailbox)
 (modules test_domain_mailbox)
 (libraries masc_core alcotest eio eio_main))

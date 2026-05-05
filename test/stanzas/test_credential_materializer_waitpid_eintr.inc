; Issue #13060 regression guard.
; Pure source-text inspection; no MASC_BASE_PATH, no project libs.

(test
 (name test_credential_materializer_waitpid_eintr)
 (modules test_credential_materializer_waitpid_eintr)
 (deps ../lib/repo_manager/credential_materializer.ml))

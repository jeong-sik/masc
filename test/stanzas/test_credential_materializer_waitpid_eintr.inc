; 2026-05-05 EINTR-waitpid regression guard (issue #13060, fix #13088).
; Pure source-text inspection — no MASC_BASE_PATH, no project libs.
; Declares the inspected source as a dep so dune tracks it.

(test
 (name test_credential_materializer_waitpid_eintr)
 (modules test_credential_materializer_waitpid_eintr)
 (deps ../lib/repo_manager/credential_materializer.ml))

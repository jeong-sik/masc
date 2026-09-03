; The directory refresh classifies REST failures to decide what is worth
; retrying; this suite pins the classification and needs no workspace.

(test
 (name test_discord_directory_failure)
 (modules test_discord_directory_failure)
 (action (run %{test}))
 (libraries masc_test_deps))

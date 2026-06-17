; RFC-0254 follow-up — end-to-end coverage that gh REST/GraphQL endpoints
; are exempt from the Exec_policy path jail while real file args and [..]
; traversals stay jailed.

(test
 (name test_exec_policy_gh_endpoint_jail)
 (modules test_exec_policy_gh_endpoint_jail)
 (libraries masc.exec_policy masc.masc_exec))

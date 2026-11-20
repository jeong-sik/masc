; How the server divides Domain.recommended_domain_count () - 1 between its
; executor pools.

(test
 (name test_domain_budget)
 (modules test_domain_budget)
 (libraries masc_core alcotest))

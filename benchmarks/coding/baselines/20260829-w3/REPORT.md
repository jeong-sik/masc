=== Eval Suite: coding-eval ===
Runs: 23 | Pass Rate: 39.1% | Cost: unavailable

[FAIL] l1-bash-classify (coding)
  pass@k=0.00  mean=0.00  consistency=0.000  cost=unavailable
  run[1] FAIL score=0.00 turns=1 cost=unavailable completed
  run[2] FAIL score=0.00 turns=1 cost=unavailable completed
  run[3] FAIL score=0.00 turns=1 cost=unavailable completed
  run[4] FAIL score=0.00 turns=1 cost=unavailable completed
  run[5] FAIL score=0.00 turns=1 cost=unavailable completed

[FAIL] l1-calc-add (coding)
  pass@k=0.20  mean=0.20  consistency=0.400  cost=unavailable
  run[1] FAIL score=0.00 turns=1 cost=unavailable completed
  run[2] FAIL score=0.00 turns=1 cost=unavailable completed
  run[3] FAIL score=0.00 turns=1 cost=unavailable completed
  run[4] ok score=1.00 turns=1 cost=unavailable completed
  run[5] FAIL score=0.00 turns=1 cost=unavailable completed

[PASS] l1-node-sum (coding)
  pass@k=0.80  mean=0.80  consistency=0.400  cost=unavailable
  run[1] ok score=1.00 turns=1 cost=unavailable completed
  run[2] ok score=1.00 turns=1 cost=unavailable completed
  run[3] ok score=1.00 turns=1 cost=unavailable completed
  run[4] FAIL score=0.00 turns=1 cost=unavailable completed
  run[5] ok score=1.00 turns=1 cost=unavailable completed

[PASS] l2-node-stats (coding)
  pass@k=1.00  mean=1.00  consistency=0.000  cost=unavailable
  run[1] ok score=1.00 turns=1 cost=unavailable completed
  run[2] ok score=1.00 turns=1 cost=unavailable completed

[PASS] l2-py-slugify (coding)
  pass@k=0.50  mean=0.50  consistency=0.500  cost=unavailable
  run[1] FAIL score=0.00 turns=1 cost=unavailable completed
  run[2] ok score=1.00 turns=1 cost=unavailable completed

[PASS] l3-py-config-plumb (coding)
  pass@k=0.50  mean=0.50  consistency=0.500  cost=unavailable
  run[1] ok score=1.00 turns=1 cost=unavailable completed
  run[2] FAIL score=0.00 turns=1 cost=unavailable completed

[FAIL] l3-py-rename-callers (coding)
  pass@k=0.00  mean=0.00  consistency=0.000  cost=unavailable
  run[1] FAIL score=0.00 turns=1 cost=unavailable completed
  run[2] FAIL score=0.00 turns=1 cost=unavailable completed


## Outcome buckets (coarse, v0)

- verify_green: 9
- verify_red: 14
- timeout: 0
- provider_error: 0
- transport_error: 0

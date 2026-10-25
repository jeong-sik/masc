# Durable declined callback acknowledgement

Review response for #45765 review 5642776677, prepared on source
`106414161e8e3cd283eacdb8c3c5f9347e9abaec`, direct base
`e0c341ac41687882ea8cce89aeb6431f3048c66f`, Native Stack #45746 position 4/31.

The prior implementation wrote a disconnected record before returning a decline
receipt only in the response. Redelivery after losing that response could not
recover acknowledgement. The prior callback-capture evidence describes that
old limitation; this response changes that specific boundary.

The protected disconnected record now atomically retains the exact declined
receipt and original state with cancellation. The existing inactive-slot write,
protected readback and atomic nonsecret reference commit own the whole record.
No sidecar, plaintext credential file or additional provider request is added.

Only a validated declined callback with the original state and connection can
read the receipt back. Its retry confirms the committed reference with a
directory sync before acknowledgement. Busy, failed or unconfirmed storage does
not manufacture a receipt. Ordinary views/public status/manual cancellation do
not expose it. A replacement attempt supersedes the old receipt and refuses
redelivery from the old attempt.

## Bounded reproduction

```sh
python3 -m unittest discover -s addons/tests -p 'test_onepassword_*.py'
```

The updated lost-response fixture was also run against unchanged production
source `106414161e8e3cd283eacdb8c3c5f9347e9abaec`. It failed at matching
redelivery with `KeyError: 'callback_receipt'`. The repaired source passes all
67 selected Python tests.

The four changed Python production/fixture files also applied cleanly to an
isolated `addons/` snapshot of upper source
`15ef43fdd5447404907a7d3f6eca0e293465081b`. The same command passed all 163
selected tests there, including the upper login/worker consumers. This is a
bounded component composition, not publication or full-stack validation.

Focused scenarios include reconstructed Connector/Worker objects after a lost
response, original state/connection/callback validation, replacement attempts,
precommit backend failure preserving the pending attempt, visible-reference
directory-sync uncertainty with withheld acknowledgement until confirmed,
concurrent matching declines, strict nested receipt schema and exclusion from
public observations/nonsecret filesystem files.

These tests execute the actual Python package with explicit `MemoryRecords`,
fixture transport and owned temporary directories. Object reconstruction models
request-process loss while retaining that explicit protected-store fixture; it
is not an executed OS Keychain/Secret Service restart or real OAuth account flow.
No Dune, CI, installed-host, real browser or provider result is claimed.

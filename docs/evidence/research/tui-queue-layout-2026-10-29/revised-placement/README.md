# Revised narrow placement, before the final input repair

This manual run used the macOS executable for
`c2bdd3cc4b4106e83b3ea2b68413e902dd61143d`. Its [manifest](manifest.json)
and [receipt](native-receipt.json) bind the executable SHA-256 to
**Minimal manual checks**, [40732646584](https://github.com/jeong-sik/masc/actions/runs/40732646584),
workflow ref `main` / `2909fcaf49a579d376b6de5618a7aa9538654fed`.
Overall conclusion: **cancelled**; native-tui / macos-tui job: **success**.
The executable digest and `--build-commit` matched the receipt.

At 80×24, one pending event, a running item and a schedule retained
[Bottom with all Queue facts](c2-count1-adaptive-80x24.txt), also
[after selecting the event](c2-count1-selected-80x24.txt). Changing the fixture
to 18 events and explicitly refreshing switched automatic placement to
[Full with ten visible pending events](c2-count18-adaptive-80x24.txt).
The first event remained selected. No input was injected between refresh and
capture, so this does not verify the later input-transition repair. The pure
layout module remained unchanged through `d84c19c`; the later executable
itself was not exercised here.

The [controlled fixture](fixture.py) adds a fixture-only count/hold endpoint.
Its initial HTTP-only probe held a read and released it with 18 events.
The recorded 3→20 change describes **inventory objects** (running + pending
events + schedule), not TUI rows. A held read uses release-time values; it
does not replay an old snapshot or model out-of-order delivery.
`inventory_returned` in [fixture-events.jsonl](fixture-events.jsonl) precedes
HTTP writing and does not prove client receipt or UI application. Early log
entries belong to the HTTP-only probe; [input notes](c2-actions.jsonl) identify
the later UI sequence. Logs have no request IDs and cannot prove concurrent
delivery order.

## Footer warning condition

The ordinary fixture claims server commit `fixture`, making the generation
warning occupy footer space. A separate [fixture](matched-fixture.py) accepts
a synthetic server-commit claim as its second argument. Claiming the TUI's
`c2bdd3c…` source, with the same selected event/count, produced an
[80×24 footer](c2-matched-footer-80x24.txt) showing n:immediate priority,
l:low priority, Enter and Esc. Warning and ordinary footer conditions must
therefore be distinguished when assessing shortcut discoverability.

Matching health metadata is **not a matching real server binary** or
interoperability proof. Both fixtures acknowledge requests without applying
urgency or executing a Keeper. No production credential, model or runtime was
used. These observations do not validate later viewport-owner, pointer-tail
or repaint changes.


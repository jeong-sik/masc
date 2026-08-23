---
description: Goal proof lookup surface — read-only tools over the shared workspace playground
category: verification
template_variables: [lookup_tools, lookup_root_layout]
---

<live_lookup>
You hold read-only tools: {{lookup_tools}}.

They are rooted at the workspace playground, which holds every producer's
tree. A Goal belongs to no single producer, so the measurement you are looking
for may sit under any of them. Every path you give the file tool resolves
against that root, so a path inside one producer's tree needs that producer's
directory as its first segment. The listing below holds what the root contains
right now, and marks the git checkouts that were found:

{{lookup_root_layout}}

There is no pattern-search tool here. Establish the shape by reading from the
listing above and narrowing down; do not conclude a measurement is absent
because one path you guessed did not open.

The web tool reads the public internet. A metric recorded in a CI run, a
dashboard, or a release page is measurable through it, and a link left in a
note is a claim until you dereference it yourself.

What you are looking for is a measurement of the declared metric: a number, a
count, a rate, a pass/fail total that someone actually recorded. Source code
that would produce the measurement is not the measurement. A note asserting
the metric was reached is not the measurement either.

If nothing in reach records the metric, say so and reject. An honest "no
measurement exists" is the correct verdict for work nobody measured.
</live_lookup>

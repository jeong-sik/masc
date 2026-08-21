---
description: Review lookup surface — read-only tools bound to one producer sandbox root
category: verification
template_variables: [lookup_tools, lookup_root_layout]
---

<live_lookup>
You hold the producer's own tools, pointed at the producer's sandbox root:
{{lookup_tools}}. They run inside that producer's sandbox — the same jail the
producer worked in — and this verifier surface is read-only.

Every path you give them resolves against that root. The root is a sandbox
root, not a repository: a checkout lives one level down, so a path the
submitter wrote relative to a checkout needs that checkout's prefix here.
These paths exist under the root right now:

{{lookup_root_layout}}

If that listing is empty or says the root could not be read, establish the
shape with a lookup before concluding a path is absent. "file is missing"
answers the path you asked for, not the question of whether the work exists.

The snapshot is what was true when the work was submitted. A lookup is what is
true now. Both are evidence, and disagreement between them is also evidence: a
file the snapshot shows and the tree no longer contains was not durable.

A claim about behaviour is not settled by reading the code that makes it. If
the submitter says a build or test passed, require an inspectable run receipt
or log. This surface cannot execute that claim, so source text alone must not
be upgraded into execution evidence.

A note claiming a path, a commit, or a command result is still not proof by
itself. The difference is that you can now check the claims that name
something in the producer's tree, so approving without checking an available
one is your omission rather than the submitter's.
</live_lookup>

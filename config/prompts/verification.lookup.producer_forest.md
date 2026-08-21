---
description: Review lookup surface — read-only tools across a closed set of producer trees
category: verification
template_variables: [lookup_producers, lookup_tools, lookup_root_layout]
---

<live_lookup>
This Goal is backed by linked Tasks performed in different owned trees. The
closed producer set is: {{lookup_producers}}. Filesystem calls require one
producer from that set; selecting a producer does not grant access to any other
tree. The available tools are: {{lookup_tools}}.

Each producer has its own sandbox root, and a path resolves against the root
of the producer you name. A root is a sandbox root rather than a repository,
and where a producer keeps its git checkouts under it is that producer's own
choice, so a path the submitter wrote relative to a checkout needs that
checkout's prefix here. The listing below holds what each root contains right
now, marks the checkouts that were found, and prefixes every line with the
producer it belongs to:

{{lookup_root_layout}}

If that listing is empty or says a root could not be read, establish the shape
with a lookup before concluding a path is absent. "file is missing" answers the
path you asked for, not the question of whether the work exists.

Read the linked-task rollup first, then inspect the submitted artifact in the
tree of the Task performer that supplied it. A reference, a Task completion
state, or another verifier's verdict is not a substitute for this Goal
verifier's own inspection. Snapshot/live disagreement is evidence that the
claimed result is not durable.

These tools are read-only. Do not reinterpret a failed or refused call as empty
output. If an artifact cannot be inspected in its producer tree, reject or defer
rather than approving from the submitter's prose.
</live_lookup>

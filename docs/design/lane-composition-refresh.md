# Completed-input refreshes across Lane packages

Producer notifications are automatic refresh hints. They can arrive while a
consumer is acquiring input and leave a second notification queued after the
first acquisition already captured the same completed producer generation.
For model-backed consumers that previously meant another model call with the
same inputs.

`source_changes` packages compare the acquired input's identity with the last
successfully committed observation. Explicit Observe bypasses the comparison;
`every_hint` packages still observe every served notification.

File snapshots retain exact captured bytes. Completed Lane-output ports retain
producer instance, generation, configuration/package revision, selection,
worker status, coverage, original output and evidence identity. Only the host's
outer Lane-output acquisition timestamp is excluded. Nested source timestamps
remain part of the input. Mixed file/port bindings share this identity; live
machine, browser and native Fusion captures keep their existing behavior.

The native composition test suspends the consumer's first acquisition, commits
the producer's next generation and queues a notification, then lets the first
acquisition read that generation. The queued refresh must add neither a package
call nor an output generation. Explicit Observe and a later producer generation
must each make another call. The source-acquisition test separately checks that
worker failure, replacement, mapping edits and output timestamps change identity.

The container qualification now installs both panels, Judge and report together.
Its barrier proves panel HTTP calls overlap, and request-count checks include
the period up to completed detach. Native tests and actual container behavior
still require completed exact-head CI; source review is not execution proof.

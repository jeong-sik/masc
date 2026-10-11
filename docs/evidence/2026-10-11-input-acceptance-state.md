# Input delivery follows acceptance evidence

Base: a9d9fed89b8fe0e96fe554d8d6d4109a606d88f0 (#42399).

A deferred actual action fixture reproduced input marked delivered before the server acceptance event. Move that transition to the callback after exact operation identity validation. Before acceptance, authored input remains sending. An unaccepted transport failure has error delivery without duplicating the assistant's error details. If the observation ends without an acceptance receipt, a still-sending exact local input becomes interrupted, preserving original content and leaving confirmed delivered, error, cancelled and canonical history states intact.

Removing premature delivery exposed a second failure in the existing lost-acceptance/history fixture: a still-sending optimistic user remained alongside canonical history for the same operation. Canonical user history now supersedes its exact covered local placeholder, using the existing structured producer identity, just as assistant history already does. It does not match message prose.

Independent review found authentication withdrawal still left an unaccepted user sending. The existing old-stream fixture reproduced that state before the finally repair. Accepted withdrawal is separately asserted to retain delivered input and assistant recovery drafts.

Validation: 207 focused keeper-actions and keeper-state tests passed, TypeScript noEmit passed, and git diff --check passed. The three failure paths were directly observed before their repairs. Independent source review of the three source/test files passed; final committed full-scope review is separate. No CI, formal GitHub approval, merge, installation, runtime, browser screenshot or full provider parity is claimed.

### Internal

- Keeper test fixtures that product changes left behind match the current
  behavior again: a branch native call binds its own call id and locator, a
  history message line carries `origin`, the event-queue snapshot is compared
  as compact JSON under the snapshot encoder's pool, the activations answer
  runs with the commit observer the server installs, a second runtime attempt
  follows a first, the OAuth attempts announcement is heard through an SSE
  subscription, and a login fixture no longer names a live Keeper. Two cases
  still fail for reasons outside the fixtures and are left for product changes
  (#42430, #PENDING).

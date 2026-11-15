### Fixed

- A removal receipt left beside its journal line no longer keeps a Keeper's
  memory writes failing because of an unrelated older journal line. The
  reconcile reads from the newest line down to the first committed line below
  the target revision and does not decode the lines older than that. Lines
  newer than that stop are still decoded strictly: an unreadable one never
  lets the removal count as missing, and only the removal's exact line
  settles the receipt beside it. After a quarantine restarts revisions, an
  equal line from the earlier generation no longer settles the current
  generation's receipt without its own line (#37682, #PENDING).

### Documentation

- RFC tool-call-row-identity (Draft) proposes that `log_call` writes a
  `record_id` into every tool-call ledger row, so a reader can follow one row
  across ledger rotation, restarts and index rebuilds. The TUI Calls list
  would refuse rows without it and show their count. It adds no code
  (#37517, #PENDING).

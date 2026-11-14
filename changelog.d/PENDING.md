### Fixed

- The `direct_input_source` prompt block has a cache rank of its own, behind
  `active_goals`. It shared rank 5 with `active_goals`, which left the order
  of the two to whichever producer ran first; the blocks behind it move one
  rank back and keep their order (#42430, #PENDING).

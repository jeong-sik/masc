### Fixed

- Editing a Goal's success criterion while its proof is under review (the Goal
  is verifying, or paused or blocked on its way back to verifying) now cancels
  the running verifier review and frees its slot, as Drop and Reopen already
  did. The edit sends the Goal back to executing, so the old review could not
  commit, yet it held one of the four verifier slots and kept the Goal's next
  request waiting until its model call ended (#39192, #PENDING).

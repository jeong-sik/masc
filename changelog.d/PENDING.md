### Fixed

- A Keeper's history clear and retirement check no longer wait forever on a
  direct operation that a restart failed while it ran with no native call. Its
  semantic execution stays `Recovering` with the interrupted origin and keeps
  its input, but once the operation has ended and the record names no native
  call, checkpoint or Gate approval, neither check counts it as outstanding.
  The same failed operation's native history now reads instead of being
  refused as a damaged input binding. Stores that already hold such a record
  are released without repair (#46918, #PENDING).

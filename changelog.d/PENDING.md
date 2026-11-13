### Fixed

- A private JSONL append with a read dependency refuses a dependency that is
  the target file itself. The dependency guard used to re-lock the path mutex
  its own thread already held, which raised
  `Sys_error "Mutex.lock: Resource deadlock avoided"` out of the transaction,
  and Board recorded the post append as an unknown write. The target guard now
  compares the device and inode of the stable lock it holds with the lock entry
  the dependency would open, so `x.jsonl`, `./x.jsonl` and a path through a
  symlinked directory are all recognised. The call returns
  `Dependency_is_target` before the dependency guard starts, nothing is
  appended, and Board reports the post as not written (#PENDING).

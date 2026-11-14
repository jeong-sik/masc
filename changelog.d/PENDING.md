### Internal

- The GC pass that moves a non-terminal task from the archive back into the
  backlog names its activity event through `Event_kind.Task`
  (`Restored_from_archive`), so `task.restored_from_archive` is one of the task
  kinds `Event_kind.Task.of_string` decodes. The wire name stays the same
  (#42832, #PENDING).

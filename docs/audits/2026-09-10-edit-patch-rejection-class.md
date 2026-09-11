# Edit patch rejection classification

Actual baseline Edit calls at 1789046759.85118 and 1789046772.075873 reported old_string not found, followed by runtime_failure guidance stating that arguments were not the problem. The pure patch application error had escaped into the same outer Result.Error path used by filesystem failures; the remote producer also used its default runtime failure class.

At the pure Keeper_tool_patch.apply/apply_patch boundary, rejected patch results now become the existing Workflow_rejection classification. The local producer uses the existing typed Write_failed variant instead of letting this result escape into I/O handling. No message substring, regex or inferred error wording determines the class. Filesystem read/write and publication failures retain their existing classes, and unchanged edits retain their successful changed=false result.

Feature tests cover stale and ambiguous patches leaving the file untouched, corrected arguments succeeding, and a remote write transport failure remaining Runtime_failure after a valid patch. Source parsing and diff checks passed locally; CI owns compilation and execution. No runtime was restarted or changed.

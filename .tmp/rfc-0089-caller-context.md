# RFC-0089 Caller Context

Goal: replace internal string-prefix classifiers with typed variants, without adding lint or phrase-list workaround gates.

Evidence:

- `lib/audit_log.ml:126` action kind prefix round-trip.
- `lib/board_core_classify.ml:80` board author prefix classifier.
- `lib/tool_help_registry.ml:71` tool family prefix classifier.

Validation command:

```sh
python3 scripts/rfc_enforcer.py --check docs/rfc/ --files RFC-0089-string-classifier-to-typed-variant.md --ignore-missing-section1
```

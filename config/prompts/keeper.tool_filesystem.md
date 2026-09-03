---
description: Keeper filesystem tool-result guidance — read/write/patch failure wording the model reads, one slot per outcome
category: tool
operator_surface: fragment
---
### offset_not_1_based (vars: offset)
offset must be a 1-based line number (got {{offset}}). Read returns lines; use next_offset from the previous response to continue.

### limit_not_positive (vars: limit)
limit must be a positive number of lines (got {{limit}}). Omit limit to read up to the byte budget.

### available_cwds_partial (vars: limit, cwds)
available cwds (partial, {{limit}}): {{cwds}}

### checkout_scan_failed (vars: detail)
workspace checkout scan failed ({{detail}}); cwds could not be enumerated

### cwd_not_directory (vars: cwd)
cwd_not_directory: {{cwd}} (directory does not exist)

### offset_beyond_window (vars: offset, window_bytes)
offset {{offset}} is beyond the scanned window ({{window_bytes}} bytes)

### offset_beyond_scan_budget (vars: offset, file_bytes, budget)
offset {{offset}} is beyond the scanned window ({{file_bytes}} bytes; the file continues past the scan budget). Read line ranges within the first {{budget}} bytes, or narrow the file another way (e.g. Grep).

### capability_unavailable
filesystem capability unavailable: Eio filesystem was not installed at runtime startup

### publication_failed
Filesystem publication failed; target effect and cleanup outcome are reported explicitly.

### directory_publication_failed
Filesystem parent directory publication failed; creation effect and durability outcomes are reported explicitly.

### append_capability_failed
Filesystem append capability acquisition failed explicitly.

### append_incomplete
Filesystem append did not complete normally; exact written bytes and sync outcome are reported explicitly.

### recovery_lane_committed
filesystem publication committed, but publication recovery lane cleanup failed

### recovery_lane_effect_observed
filesystem publication produced an observable filesystem effect before the publication callback and recovery lane cleanup both failed

### recovery_lane_not_executed
filesystem publication left the target unchanged, but publication recovery lane cleanup failed

### recovery_lane_indeterminate
filesystem publication callback and publication recovery lane cleanup both failed

### recovery_lane_cleanup_detail
publication recovery lane cleanup failed after the publication callback returned

### gate_record_unavailable
External effect was not executed because the Gate could not durably record its decision state. This Keeper remains active and may continue other work.

### path_required
path is required. Good: path='lib/foo.ml'. Bad: path=''.

### patch_requires_old_string
mode=patch requires non-empty old_string. Good: old_string='let x = 1'.

### patch_target_missing
patch target file does not exist. Use mode=overwrite to create it.

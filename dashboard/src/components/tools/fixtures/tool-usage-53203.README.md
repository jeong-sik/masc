The JSON is an allowlisted projection of the actual dashboard tools response from
runtime commit `53203f998a2df9f6149e1c033d5602836a8d7066` on 2026-09-12. It retains
only tool names, visibility, counts, source labels and a response digest. Private
configuration, paths, tool arguments and outputs are excluded.

`original_*` fields are captured observations. `expected_catalog_usage` is the new
projection calculated from those observations for the UI fixture; the original
runtime did not emit that field. The 645 non-public call log rows are a separate
observation from the 775 metrics calls.

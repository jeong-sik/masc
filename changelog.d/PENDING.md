### Internal

- Six test suites that failed on the nightly `main` Test run expect the
  product's current behaviour again. `test_tui_next_request_band` decodes a
  v7 forecast, `test_tui_preparation_details` expects an Owner stop to be
  recorded as `Interrupted_by_restart`, `test_dos_addon_worker` expects the
  launch and the boot fault announcements of a faulted boot,
  `test_lane_addon_skills` and `test_lane_addon_reconcile` expect a superseded
  Lane instance to leave Inspect, and `test_tool_type_label` expects the seven
  `keeper_` memory, wiki and surface tools to carry their declared `read` or
  `write` label. `test_candle_appraiser_contract` now declares `config/prompts`
  as a dependency, so its sandbox holds the prompts it loads (#42430, #PENDING).

(test
 (name test_keeper_pause_silent_failure_source)
 (modules test_keeper_pause_silent_failure_source)
 (libraries alcotest unix str)
 (deps
  ../lib/server/server_dashboard_http_keeper_api_lifecycle_post.ml
  ../lib/server/server_dashboard_http_keeper_api_post.ml
  ../lib/keeper/keeper_status_detail.ml
  ../lib/keeper_metrics/keeper_metrics.ml))

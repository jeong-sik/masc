# Auth reader: measured native feature result

Published #40256 head46fb0eec8680e1dd0ded7ff341144972178320d2, targeted Test36692465819 completed success. Downloaded complete suite-runner log records **8 new reader cases +172 supporting cases =180 cases across11 suites**. Cases exercised public Auth/Login readers, configuration FIFO refusal with preserved pairs/bootstrap data and subsequent publishers, cancellation propagation, UUID verification/index refusal+recovery, Admin/internal/secret metadata and OAuth access/family typed refusal+lock recovery. This is execution evidence for the selected current-head fixture paths, not stat/open external-replacement safety or installed/live behavior.

Reader public functionality keeps regular symlinks and exact accepted bytes. Index authorization changes in #40259 have a separate head/run and are not covered by these180 cases. Required PR checks, review/main freshness and release remain separate; no merge/deployment/live mutation claim.

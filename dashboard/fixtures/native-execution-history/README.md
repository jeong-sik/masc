# Completed native history rendering fixture

Run `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:9 pnpm exec vite` from
`dashboard/` and open
`/fixtures/native-execution-history/fixture.html`. The fixture mounts the actual
`ChatTranscript` with a completed direct-operation identity and synthetic HTTP
responses for two calls. Expand **Core 실행 이력**, read the remaining event pages and
select the next call. Add `?missing` to observe a missing-journal error.

All responses are synthetic. This checks rendering, exact identity routing,
pagination and explicit error display. It does not prove an installed server,
Core execution, durable settlement or process-restart behavior. Browser captures
belong in repository `artifacts/`, not this source directory.

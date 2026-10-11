# Tool schema credential ownership

Base: e7199e2fbb7465d429f37127b024c19391f616bf (#42444).

Two consumer fixtures failed on the parent: the previous credential schema cache remained visible, and its pending read blocked the replacement credential read. RED log: /tmp/tool-schema-auth-red-20261012.log. MCP transport is mocked; token publication and consumer signals are real.

Credential notification retires schema cache, selection, form and result projection in one reactive batch. Each schema read owns an immutable credential revision and exact slot identity. Stale success, error, toast, cache freshness and cleanup cannot publish for a replacement owner. The old network promise is not cancelled by this consumer; its transport owns cancellation.

Three focused suites (tool-executor-state, core, schema-form) passed 78 tests; TypeScript noEmit exited 0. Log: /tmp/tool-schema-auth-focused-20261012.log. No CI, installation, screenshot or actual provider/runtime evidence. ExecuteTool itself still requires asynchronous receipt ownership; this schema unit does not certify it.

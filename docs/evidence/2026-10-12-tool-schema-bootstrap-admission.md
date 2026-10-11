# Tool schema actual MCP bootstrap admission

Base: bc1dd2ba906f22b71f84d7bfe24f708e36469aa5. F1 from the independent schema review was reproduced using real core, dev-token and MCP modules with fetch responses supplied at the network boundary. Both bootstrap and tools/list completed, but the old consumer published an empty tool list. RED: /tmp/tool-schema-bootstrap-red-20261012.log.

MCP aggregate now exposes its exact immutable admission revision after ensureBinding and before page acquisition, then rechecks binding after the consumer callback. Schema reads use immutable preparing/admitted records sharing a unique read identity. Normal bootstrap can admit its original preparing read; a replacement read cannot be overwritten by its old callback. Cache freshness includes credential revision, and the notification reset preserves already admitted current-owner reads/cache rather than assuming subscriber order.

Four focused suites passed 25 tests: real MCP bootstrap/aggregate admission, schema consumer ownership, mounted reload and existing MCP admission scenarios. TypeScript noEmit exited 0. Log: /tmp/tool-schema-bootstrap-focused-20261012.log. No live network/provider/browser screenshot, CI or official approval. Execution bootstrap ownership and reentrant selection reset still require independent review; this is not full chain approval.

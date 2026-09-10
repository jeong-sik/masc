# LSP recovery after a transport outage

The IDE LSP client stopped retrying after ten connection failures. A server
returning later could not restore diagnostics without recreating the connection.
The client now keeps its existing bounded exponential reconnect delay while it
is owned by the editor. Explicit authentication/policy closes and disposal still
end reconnects. No new timer, attempt cap or runtime setting was introduced.

Validation command:

```sh
pnpm exec vitest run src/components/ide/ide-lsp-client.test.ts
```

Observed: one file, 20 tests passed (2026-09-10 04:35 KST). The outage scenario
advances fake timers across 24 hours of failed WebSocket connections, then opens
a replacement connection and verifies initialization plus delivery of a source
file diagnostic. Existing scenarios also check disposal, terminal auth closure,
stale socket events and scope changes.

This is a mocked transport scenario, not a real 24-hour run, browser screenshot,
or proof that a deployed language server runs. CI build and deployed/browser
verification remain separate. No local build was run.

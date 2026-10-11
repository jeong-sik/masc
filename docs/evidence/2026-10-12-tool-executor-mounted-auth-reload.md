# Mounted tool executor credential reload

Base: bb7749cea5247f941f374afdddd1c63831047a7d. This addresses F2 from /tmp/masc-tool-schema-auth-findings-20261012/report.md, not F1 bootstrap admission.

A real Preact-mounted ToolExecutor with its schema-loader boundary mocked failed to request a second load after a real core credential publication. RED: /tmp/tool-mounted-auth-reload-red-20261012.log.

The component observes the existing readonly credential revision projection and runs its loader effect for that revision. It does not create another auth epoch or global subscription. Unmount removes the component effect; a later credential change causes no component request.

Three focused suites passed 27 tests, including mounted auth-change reload/unmount and consumer receipt/cache ownership. TypeScript noEmit exited 0. Log: /tmp/tool-mounted-auth-reload-focused-20261012.log. Tests use a mocked loader and happy-dom, not a running browser/provider or screenshot. F1 normal bootstrap admission remains unresolved and the chain is not integration-approved.

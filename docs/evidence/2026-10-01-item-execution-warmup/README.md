# Item execution warm-up withdrawal

The source receipt records a new functional regression failing against the parent and passing after the store correction from #40190 was carried onto the preview stack. The first corrected run exposed older currency fixtures without canonical workspace identity; the matching corrected fixtures were carried forward as well.

The final two focused suites passed 21 tests in 1.20s; TypeScript passed. The Item scenarios call the real refreshExecution path with a synthetic initializing HTTP envelope. They verify visible account and preview withdrawal, refusal of an old held reply, and a fresh account read after workspace recovery. Currency scenarios cover reconnect and epoch changes in existing summary/header consumers.

These are component/store checks using synthetic HTTP and a portrait stub. They do not prove native pixels, purchase/equip/restart durability or installed TUI. No Dune build or CI was started. Source identities and hashes are in receipt.json.

## Actual Chromium warm-up transition

Scenario source `4497c76d6b4ec134ce867ac621c2bb959bab43c7` passed through local Vite with production Item components and store. The browser made actual intercepted HTTP requests to both Item and execution endpoints. The original preview failed visibly through mocked PNG503; an initializing execution reply withdrew account, picture and failure. A recovered execution envelope restored a newly read account (0.600 Candle, two owned items) without reviving the old preview. Three captures and the original manifest are retained under browser/. No page errors were recorded.

The first successful attempt supplied an incorrect source identity and is excluded; the retained run used the independently read git HEAD. These captures prove fixture frontend behavior; native pixels, live purchases/restart and installed TUI remain unverified.

# Previous reasoning and newer response metadata boundary

Base: 9b8ea17708dc592e0bf2bc86c2f0618249272cbb.

A functional fixture admits exposed reasoning for generation 1 while buffered, then metadata for generation 2. It verifies previous reasoning remains tagged with generation 1, current response authority is generation 2, and activity is streaming/opening for the newer metadata response.

The initial fixture incorrectly expected delivery sending. The real metadata producer sets streaming/opening, so its failure did not establish a product defect. A speculative activity-preservation edit did not change that result and was reverted in full. No product source change is included in this unit. Earlier logs /tmp/chat-thinking-response-activity-red-20261012.log and /tmp/chat-thinking-response-activity-focused-20261012.log are rejected-hypothesis evidence, not confirmed bug reproductions.

The corrected keeper-stream suite passed 117 tests, TypeScript noEmit exited 0, and diff check passed. Log: /tmp/chat-thinking-generation-boundary-focused-20261012.log. This tests a response-generation protocol interaction and does not certify the rest of the chat goal. Browser tooling discovery found no live browser/computer screenshot tool in this session; GitHub API PR publication is still failing to connect. No live provider, screenshot, CI, approval or installation is claimed.

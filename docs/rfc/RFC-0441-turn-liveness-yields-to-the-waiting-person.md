---
rfc: "0441"
title: "A running turn must not misread or outrank the person waiting on it"
status: Draft
created: 2026-09-10
updated: 2026-09-10
author: goo-yang-bong
related: ["0345"]
---

# RFC-0441 — Typed turn-liveness policy: a running turn must not misread or outrank the person waiting on it (#25898)

- Status: Draft
- Author: goo-yang-bong
- Related: masc#25898 (root-fix, cluster `turn-liveness-policy`), masc#20849 (17+ min priority inversion + dashboard stall misread), masc#21971, masc#24164, RFC-0345 (stream idle fail-safe floor), #29230 (wall-clock ceiling escape, task-596), #28809 (HITL mid-turn preemption pattern)
- Boundary vs task-596/#29230: #29230 owns the **wall-clock ceiling** — how a turn that cannot progress escapes `awaiting_tool` and how hang durations distribute under a ceiling. This RFC owns the **priority and observability of what waits on a running turn** — when a running turn must yield its lane to a person, and how the waiting person reads the runner's health. Same cluster, disjoint mechanisms; #29230 bounds a turn's *duration*, this policy bounds its *cost to others*.

## 0. Summary

A long-running autonomous turn is not a bug. Two things about it were: (1) it outranked the operator's direct message for its whole duration — measured 17+ min in #20849 — and (2) while the operator waited, the dashboard read the runner's healthy tool-grinding as "스트림 지연" (a dying transport), because the only liveness signal the waiting client had was its own silent SSE feed.

This RFC addresses both under one typed policy statement: **the runner should yield to the person at the next proven resumable boundary, and the waiting person should see the runner's tool activity, not infer death from their own feed's silence.** AGENT_CORE has a checkpointed post-tool boundary. An official client's tool-completed notification alone does not prove that its result will be available to the model after a cold resume; that handoff needs separate verification.

## 1. What already exists (do not re-implement — task-596 lesson)

The cluster was filed before three layers landed; a reviewer must know what is already policy:

- **Wake-class priority** (`Keeper_event_queue.urgency`, `Keeper_external_attention`): a mention or DM is classified `Mention`/`Direct_message` at the connector and is not the fleet's lowest grade. Owner direct messages dispatch through `Keeper_owner_registry.submit_operation` (the owner-operation queue), not the ambient `Connector_attention` stimulus.
- **Mid-turn preemption for owner operations** (`chat_yield_request`): on AGENT_CORE, the running turn's checkpointed post-tool probe sees `queued_count > 0` and yields; the owner-op child (`Keeper_owner.start_child_if_needed`) is mutually exclusive with the running turn, so the yield is what hands the lane over. #28809 added the same probe for approved Gate resolutions. Official-client tool notifications have a separate result-handoff contract and do not establish this checkpoint guarantee.
- **Wall-clock ceiling** (#29230 / task-596): a turn that cannot progress escapes; hang-duration distribution is in-tree.
- **Stream-idle fail-safe floor** (RFC-0345): a hung provider stream cannot freeze the chat lane; 600 s floor when unset. This already covers the *genuine* dead-transport case the dashboard heuristic guesses at.

## 2. The two remaining gaps

### 2.1 Gap A — ambient connector conversations had no mid-turn preemption

The owner-operation probe covers a person's *direct* address. The HITL probe covers approved resolutions. But an **ambient** connector conversation (Slack/Discord channel the keeper follows, no mention, no DM) lands as a `Connector_attention` stimulus — and a running `Woken` turn never looked at those: its probe chain (`chat_yield_request` → `hitl_replay_yield_request`) ended there. A multi-hour autonomous run could hold an ambient conversation's turn behind it — the same inversion #20849 measured, one class over.

Empty wakes (`Proactive_tick`, `Woken []`) already yield to *any* pending stimulus (`autonomous_yield_request`), so the gap is specific to the nonempty `Woken` turn, which deliberately does not yield to the payloads it was itself woken by.

**Fix (this RFC, implemented for AGENT_CORE):** extend the nonempty-`Woken` probe chain with a third, narrow probe: `connector_attention_waiting` — yields only when a `Connector_attention` payload is pending, and does not yield to the turn's own wake payloads (all other payload kinds are matched `false`). The AGENT_CORE source turn checkpoints at the post-tool boundary and resumes after the conversation turn settles — the same cooperative yield `Runtime_agent.Yielded_to_durable_stimulus` models for #28809. This does not establish a replayable tool-result handoff for official clients.

**Re-entry and liveness:** `Runtime_agent` passes `cooperative_yield_probe` to `Agent_core.Agent.Advanced.continue` when resuming with a probe, so the resumed source can reach this probe again. Each yield must be justified by a currently pending stimulus. A one-shot latch would suppress a later, genuinely new conversation. The callback shape alone does not prove the absence of livelock; queue ordering and repeated-yield behavior need verification.

### 2.2 Gap B — the waiting client reads feed silence as death

`ChatComposer`'s stall hint (`STREAM_STALL_THRESHOLD_S = 15`) is driven by `lastEventAt`, which the live-send path marks **only on SSE events from this client's own stream**. When the operator's message is queued behind a running turn:

- the server has accepted (`KEEPER_CHAT_OPERATION_ACCEPTED`) and the operation is `queued`/`running` elsewhere;
- the runner's tool activity streams to *its own* consumers, not to this SSE feed;
- after 15 s of that silence the composer prints "마지막 수신 N초 전 — 스트림 지연" in warning color — to a user whose keeper is, in fact, healthily working.

The hydrate path (post-reload, `hydrateTrackedKeeperChatOperation`) already marks the signal on every poll tick while the operation is queued or running; the live-send path does not poll between acceptance and the first reply event. Same store, two paths, one marks liveness and one doesn't.

**Fix (this RFC):** liveness marking must not depend on which path owns the request. While the live-send stream is open and the operation is not yet streaming a reply, the client polls the operation (it already has the poll machinery and cadence from the hydrate path) and marks the stream signal from the operation's `queued`/`running` state — the same evidence the hydrate path uses. The runner's tool activity (last tool call time, count) is the deeper display the issue asked for; the poll-marked signal is the minimal honest fix that stops the death misread, and the display lands on top of the same poll data.

## 3. Policy, stated once

A running turn owes the person waiting on it at each proven resumable boundary:

1. **Yield order** (highest first): claimed owner operations → approved HITL resolutions → pending `Connector_attention`. A nonempty-`Woken` turn yields to none of its own wake payloads.
   If the provider has not reached a proven resumable boundary, the admitted turn keeps
   running. #39309 removes queue-triggered cancellation before its first response
   event. AGENT_CORE can yield at its checkpointed post-tool boundary. An
   official-client tool-completed event does not by itself prove a replayable
   result handoff, so this RFC does not claim the same mid-turn guarantee for
   official clients. Normal completion and configured no-progress timeouts
   also release the lane independently of the queued message.
2. **Honest liveness**: anyone waiting on the turn sees the turn's actual activity (tool calls, queue state), never an inference of death from their own feed's silence.
3. **Duration is not this policy's axis**: a turn that is *progressing* may run long; a turn that *cannot* progress is #29230's ceiling. Priority and observability here, duration there.

## 4. Non-goals

- Turn duration caps, hang-escape, distribution work (#29230 owns it).
- Stream idle floor values (RFC-0345 owns it).
- Changing how mentions/DMs are classified or that they route to the owner-operation queue (existing policy, kept).
- Interruption (cancel) of the source turn — the AGENT_CORE yield is cooperative at a persisted boundary; a forced-cancel lane is a separate design.

## 5. Verification

- Gap A: `test_keeper_turn_outcome` / `test_mid_turn_resume` (yield-and-resume still passes; probe chain extension adds a case); `dune build @check` clean. The 17-min symptom's class (ambient conversation held behind a `Woken` turn) has an in-tree fixture through the event queue's connector payload.
- Gap B: the dashboard composer fixture (`primitives.test.ts`, `data-chat-stall-hint`) gains the queued-poll marking case; vitest runs it without a browser.
- Post-merge: #25898 closes with before/after of one measured hold (issue text has the 17-min baseline from 2026-06-11).

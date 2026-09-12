---
name: team-channels-fixture
description: Read the Team Channels synthetic website through Browser Lane. Use when collecting Alpha, Beta, and Gamma channel decisions, mentions, and shared work from Team Channels pages.
---
# Team Channels

Use this instruction with browser-lanes for the Team Channels fixture only.
The Channels navigation contains ordinary same-tab links. Observe its link targets
and reuse those targets within this site; do not infer paths from channel names.
A channel's main landmark is labelled with its channel name. Its article is the
visible message list. The sidebar is a navigation summary, not message evidence.

Collect the requested channels' visible messages, sender, time, decision, open
request, and message permalink. Check the channel heading and message content after
navigation. Preserve a small per-channel result before leaving it. Reuse observed
same-site links instead of reopening the channel index for every channel.

A mention must occur in a message and name the requested person. Distinguish older
superseded decisions from current decisions. Derive shared work from the messages
across channels, with the per-channel sources. Do not invent a site API, token,
connector, or hidden history. Report the visible coverage and any missing channel.

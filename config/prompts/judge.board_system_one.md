---
description: System One Board question using the shared relevance policy
category: judge
operator_surface: fragment
template_variables: [board_policy, keeper_name_json, board_interests_json]
---

{{board_policy}}

The current Board signal is state.signal. The keeper is {{keeper_name_json}} and its board interests are {{board_interests_json}}. Apply the shared policy to that signal and keeper. Choose relevant or not_relevant as established by the policy. Choose uncertain when the supplied signal does not provide enough evidence for either decision and request a full judgment by the review lane.

### uncertain
The current signal does not provide enough evidence to decide; request a full judgment by the review lane.

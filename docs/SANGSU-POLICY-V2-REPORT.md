# Sangsu Policy V2 Report

Historical note: this document describes an older `policy_mode`-based keeper design.
The live runtime now uses a fixed keeper tool surface and hybrid autonomy instead.

## Goal

`sangsu v2` moves keeper behavior selection away from product heuristics and toward an explicit offline reward-model path.

The first implementation keeps hard deterministic safety gates and narrows the learned-policy action surface to:

- `noop`
- `reply_in_room`
- `board_post`

Everything else remains outside scope for this phase.

## What Changed

### Keeper policy metadata

Keeper meta now persists:

- `policy_mode`
  - `heuristic`
  - `learned_offline_v1`
- `policy_action_budget`
  - `conversation`
  - `board`
- `policy_reward_model_path`

### New MCP tools

- `masc_keeper_policy_set`
- `masc_keeper_feedback_record`
- `masc_keeper_dataset_export`
- `masc_keeper_action_explain`
- `masc_keeper_eval_replay`

These are agent-facing first. Dashboard work can stay a thin wrapper over these tools later.

### Learned-policy runtime

When `policy_mode=learned_offline_v1`:

- explicit-room wake-up still requires exact direct mention
- candidate actions are generated deterministically
- candidate selection uses a JSON reward model
- room-reply decisions are logged to `.masc/perpetual-keepers/<name>.policy.jsonl`
- feedback is logged to `.masc/perpetual-keepers/<name>.feedback.jsonl`
- dataset export writes `.masc/perpetual-keepers/<name>.dataset.json` by default

### Heuristic bypass

For `learned_offline_v1`, the regular keeper reply path now bypasses:

- skill routing injection
- self-model drift
- interesting alert fanout
- heuristic fallback model append

Infrastructure safety remains:

- context compaction gates
- handoff threshold gates
- action budget gates

## Reward Model Format

The runtime expects a JSON file shaped like:

```json
{
  "version": "reward-model-v1",
  "candidates": {
    "noop": {
      "bias": 0.0,
      "weights": {
        "direct_mention": -0.5
      }
    },
    "reply_in_room": {
      "bias": 0.1,
      "weights": {
        "direct_mention": 1.5,
        "question_mark": 0.2
      }
    },
    "board_post": {
      "bias": -0.3,
      "weights": {
        "active_goal_count": 0.8
      }
    }
  }
}
```

The current feature vector is deterministic and includes:

- `direct_mention`
- `question_mark`
- `message_chars`
- `active_goal_count`
- `joined_room_count`
- `room_scope_all`
- `idle_seconds`

This is intentionally simple. The goal of v1 is reproducible offline scoring, not end-to-end policy learning.

## Offline Loop

The current offline loop is:

1. Log policy actions.
2. Record structured feedback against `action_id`.
3. Export joined dataset.
4. Train reward weights offline.
5. Bind a reward model with `masc_keeper_policy_set`.
6. Replay prior actions with `masc_keeper_eval_replay`.

This phase does not train a full policy network. It only scores fixed candidates.

## Research Basis

### Intrinsic motivation

- Pathak et al. 2017, Curiosity-driven Exploration by Self-supervised Prediction  
  https://proceedings.mlr.press/v70/pathak17a.html

The keeper analogue is not game exploration. It is the idea that behavior selection can be driven by internal signals instead of only external commands.

### World-model planning

- Hafner et al. 2023/2024, Mastering Diverse Domains through World Models  
  https://arxiv.org/abs/2301.04104

This informed the split between:

- observation
- candidate action generation
- scoring
- execution under a separate safety gate

### Preference-based reward learning

- Christiano et al. 2017, Deep Reinforcement Learning from Human Preferences  
  https://arxiv.org/abs/1706.03741

This is the closest direct analogue to the keeper feedback path. We log behavior, attach feedback, and train a reward model offline.

### Intrinsic control / empowerment

- Mohamed and Rezende 2015, Variational Information Maximisation for Intrinsically Motivated Reinforcement Learning  
  https://arxiv.org/abs/1509.08731

This motivates keeping `noop` as an explicit candidate and treating action choice as an information-and-control tradeoff instead of hardcoded “always reply” logic.

### Long-horizon agent memory

- Wang et al. 2023, Voyager  
  https://arxiv.org/abs/2305.16291

This supports the versioned trace + replay + accumulated feedback workflow.

### Social continuity

- Park et al. 2023, Generative Agents  
  https://arxiv.org/abs/2304.03442

This informed the keeper split between static persona, persistent memory, and explainable action traces.

## Current Limits

This is not full “free will”.

Current implementation still has hard constraints:

- exact direct mention wake-up for explicit-room flow
- finite action set
- no file/task/destructive actions
- no online learning
- no full planner trained from trajectories

What changed is narrower and more important:

- behavior selection can now come from a bound reward model instead of keeper heuristics
- the decision is inspectable
- the data needed for offline improvement is now persisted

## Next Step

The next meaningful step is not more heuristics. It is a real trainer that fits reward weights from:

- accepted vs rejected actions
- missed vs unnecessary actions
- room/timing/tone failure labels

Once that exists, `sangsu v2` can shift from “heuristics disabled, fixed linear scorer” to “reward-model-backed proactive keeper with auditable decisions”.

# Keeper\ Autonomy\ Identity — Research References

## Core Papers

### 1. Stanford Generative Agents (Park et al., 2023)

**Title**: Generative Agents: Interactive Simulacra of Human Behavior

**Key Insight**: Agents with Memory Stream + Reflection develop emergent social behaviors.

**Applicable Concepts**:
- Memory stream as identity source
- Periodic reflection synthesizes experience into self-understanding
- Importance scoring for memory retrieval

**Application to Keeper Autonomy**:
- `reaction_history.jsonl` = memory stream
- `self_reflection_prompt` = periodic reflection
- Confidence score = importance weight

---

### 2. A-MEM (February 2025)

**Title**: A-MEM: Agentic Memory for MODEL Agents (arXiv:2502.12110)

**Key Insight**: Zettelkasten-style bidirectional linking between memories improves retrieval F1 by ~35%.

**Applicable Concepts**:
- Memories link to each other (not just flat storage)
- Confidence scores on memories
- Dynamic memory consolidation

**Application to Keeper Autonomy**:
- Cluster reactions by semantic similarity
- Link related reactions across time
- "Personality themes" emerge from clusters

---

### 3. EMNLP 2025 Diversity Paper

**Title**: Maintaining Diversity in Multi-Agent Dialogue Systems

**Key Insight**: Theory of Mind (ToM) + Persona = stronger agent differentiation.

**Applicable Concepts**:
- Agents model what other agents would do
- Cross-agent interaction patterns shape identity
- Consensus-diversity tradeoff management

**Application to Keeper Autonomy**:
- Prompt includes: "다른 에이전트들의 예상 반응"
- "dreamer는 이 글을 upvote할 것 같다. 너는?"
- Track inter-agent interaction patterns

---

### 4. Spontaneous Individuality (November 2024)

**Title**: Spontaneous Individuality in Multi-Agent Systems (arXiv:2411.03252)

**Key Insight**: Individuality emerges from interaction, not prescription.

**Applicable Concepts**:
- Role clusters form naturally through interaction
- No need for explicit role assignment
- Periodic archetype detection

**Application to Keeper Autonomy**:
- Don't prescribe "dreamer", "historian", etc.
- Cluster signatures periodically
- Auto-assign archetype labels for monitoring

---

### 5. Meta-Cognitive Patterns (2025)

**Title**: Self-Efficacy Monitoring in MODEL Agents (arXiv:2509.21224)

**Key Insight**: Agents with self-monitoring perform better on complex tasks.

**Applicable Concepts**:
- Mini-reflection after each action
- Identity coherence tracking
- Self-efficacy as emergent property

**Application to Keeper Autonomy**:
- Optional: "이 반응이 나의 정체성과 일관되는가?"
- Track coherence score over time
- Flag identity drift

---

## Implementation Mapping

| Paper | Core Concept | Keeper Autonomy Implementation |
|-------|--------------|---------------------|
| Stanford | Memory Stream | `reaction_history.jsonl` |
| Stanford | Reflection | `self_reflection_prompt` |
| A-MEM | Bidirectional Links | `keeper_memory_cluster.ml` |
| A-MEM | Confidence | `confidence_calibration` |
| EMNLP | Theory of Mind | `keeper_tom.ml` |
| EMNLP | Diversity | `find_similar_pairs` |
| Spontaneous | Emergent Roles | `keeper_archetype.ml` |
| Meta-Cog | Coherence | `coherence_score` |

---

## Quantitative Claims (Verified)

| Claim | Source | Page/Section |
|-------|--------|--------------|
| A-MEM improves F1 by ~35% | arXiv:2502.12110 | Table 2 |
| ToM + Persona improves diversity | EMNLP 2025 | Section 4.3 |
| Stanford agents develop social behaviors | UIST 2023 | Qualitative |

**Note**: Exact percentages should be re-verified before citing in production documentation.

---

## Open Questions

1. **Optimal reflection interval**: Stanford uses importance-weighted triggers. We use fixed 20 reactions. Better approach?

2. **Cold start diversity**: How to ensure founding reactions are diverse across agents?

3. **Convergence detection**: What similarity threshold indicates problematic convergence?

4. **Temporal decay rate**: 10-day half-life is arbitrary. What's optimal for keeper autonomy posting frequency?

5. **ToM computational cost**: Modeling all other agents is O(n²). How to scale?

---

## Future Research Directions

1. **Cross-community identity**: Same agent in different keeper rooms develops different facets?

2. **Identity transfer**: Can an agent's signature be transplanted to a new context?

3. **Adversarial identity**: Can agents be manipulated through targeted post exposure?

4. **Collective identity**: Does the keeper autonomy layer itself develop a "personality" from aggregate patterns?

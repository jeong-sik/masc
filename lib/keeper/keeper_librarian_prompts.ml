(** Keeper_librarian_prompts — prompt templates for the Memory OS librarian.

    Keeping prompts outside the pure logic module makes them easier to
    audit, diff, and eventually migrate to [masc.prompt_registry]. TODO:
    register this template under [keeper/librarian/episode_extraction]
    once the registry supports runtime overrides (#20829 follow-up). *)

let episode_extraction =
  {|You are a librarian for an AI agent. Your job is to read a slice of the agent's conversation history and extract a structured memory summary.

Rules:
1. Be objective. Extract only facts, decisions, constraints, and open items.
2. Do NOT preserve emotional fillers, emoji bursts, or repetitive catchphrases unless they encode a real fact.
3. Claims must be grounded in the conversation. If you are uncertain, use a low confidence (0.1-0.4) and include the uncertainty in the claim text.
4. Each claim must include the approximate turn number or tool call that supports it.
5. The output must be valid strict JSON with no markdown formatting.

Output schema:
{
  "episode_summary": "One-paragraph summary of what happened in this episode (max 400 chars).",
  "claims": [
    {
      "claim": "A single factual sentence.",
      "confidence": 0.95,
      "category": "code_change|fact|preference|blocker|goal",
      "source_turn": 12,
      "source_tool_call_id": "call_abc"
    }
  ],
  "open_items": ["Tasks or questions left unresolved."],
  "constraints": ["Blockers, limits, or policies mentioned."],
  "preserved_tool_refs": ["call_abc", "call_def"]
}

Conversation history:
%s

Respond with ONLY the JSON object.|}
;;

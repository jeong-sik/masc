### Changed
- Keep follow-on SDK handler results and separately typed native starts linked to the original children after an inline async result, preserving original Task and activation authority.
- Retain sibling result handles within an official-client attempt, revoke them on actual turn/attempt reset, and prevent late I/O from reviving prior authority.
- Expose strict causal action facts through the canonical v7 Skill ledger and Python, Dashboard and TUI data readers; deduplicate physical actions across sibling receipt links.

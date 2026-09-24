---
name: quiz-deck
description: Turn Board, memory or GitHub records into a quiz fact deck whose every answer is quoted from the record. Use before installing or refreshing the quiz-questions / quiz-grader Lane packages.
---

# Quiz deck from records

The quiz asks only about what a record says. You choose the facts; the script
refuses any fact whose answer is not in words the record actually contains.

## Steps
1. Read the records with the tools you already have (`masc_board_post_get`,
   `keeper_memory_search`, `gh issue view`). Save each one as a text file under
   one directory, exactly as the tool returned it. Do not retype or summarise.
2. Write `candidates.json`: a list of
   `{"id","field","subject","answer","quote","record":{"uri","file"}}`.
   - `field` must be one of `author`, `claimant`, `status`, `merged_commit`,
     `cause`, `decision` (the questioner has no template for anything else).
   - `quote` is copied from the saved file; `answer` is copied from `quote`.
   - `uri` names the record (e.g. `masc://board/<post>#<comment>`), `file` is the saved text.
   - Give each field at least two facts with different answers, or no question is asked.
3. Run `python3 scripts/build_deck.py candidates.json <record-dir> <deck-id> deck.json`.
   Exit 1 lists rejected facts; fix the quote or drop the fact, never the check.
4. Point both installations' `snapshot_file` at the same `deck.json` with the same
   `source_id` (`deck`). A new `deck-id` makes old questions ungradable on purpose.

## What this does not prove
The record hash is of your saved copy, not of the Board's stored bytes. The
check establishes that the answer is a whole word of the quote and the quote is
in the saved record. It does not catch a negation elsewhere in the quote
("원인은 unmerged 가 아니라 merged"), and it does not show you picked the
important facts. Quiz scores split by the answerer's own label, not by the
authenticated requester.

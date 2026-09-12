# Keeper reuse of a Browser Lane region

Two isolated runs used real Firefox, the same synthetic page and declared
`glm-coding.glm-5.3-flash` runtime, and a fresh manual Keeper for each request.
The first could not load the instruction; the second received the smaller
instruction and read the selected article directly.

| Observed result | Before | After |
|---|---:|---:|
| Main SKILL.md bytes, including frontmatter | 17,140 | 11,930 |
| Instruction body bytes at the provider boundary | 16,908, rejected | 11,698, delivered |
| Keeper BrowserRead calls | 5 | 1 |
| Total Keeper tool calls, including keeper_skill | 6 | 2 |
| Failed tool calls | 2 | 0 |

The before run tried regions, whole-page text, unsupported scoped elements,
whole-page elements, then scoped scene. The after run called `keeper_skill`,
then `BrowserRead mode=scene` with the observed tab, URL and selected region
reference. Both eventually answered Mina, Tuesday, and accessibility review.
The after scene contains only the selected Alpha article, excluding Beta and
the sidebar. These are observations from one pair, not a general performance
claim or proof of which wording change caused the shorter route.

## Evidence

- [keeper-pair.json](keeper-pair.json) retains the natural input, tool call IDs,
  exact inputs, tool-result bytes/hashes, BrowserRead outputs, final answers,
  server/driver identity, and the after run's Skill activation record.
- [fixture.html](fixture.html) is the complete synthetic page.
- The after activation has `invocation.kind=instruction`; its delivered body
  SHA-256 matches the tool result and the current SKILL.md without frontmatter.
  The following BrowserRead call ID is present in that activation's actions.
- Both chat operations reached `Succeeded`. The after shutdown record reached
  `finalized`. The before shutdown terminal record was observed but was not
  retained in this bundle before startup pruned it; admission alone is not
  presented as shutdown proof.

## Setup and limits

The installed server embeds `d568ba7ffcb35555cba5d07c4a87c3871ac67db8`;
this experiment supplies the instruction package from the worktree to its own
scratch skill source. It does not claim a newly deployed server. Before file
SHA-256 is from PR head `637efb0f25`; after content is from `869a35889a`.

Each profile made only `browser-lanes` eligible, and each natural user message
asked for the selected area's owner and decision without naming a tool or
skill. The TUI-shaped payload was constructed from the actual regions response;
it was not captured from the new TUI clipboard exporter. The payload contains
only the region label and references, not the requested answer. Browser setup
and observer calls were the same in both runs and are excluded from Keeper
call counts. No Slack workspace or other real target channels were accessed.

To repeat, use a separate initialized scratch workspace, a configured model,
a fresh Firefox session serving the fixture, and the candidate instruction
package. Read regions, construct the same payload shape from the selected
Alpha article, and submit the recorded natural request to a fresh Keeper.
Record the operation, final answer, tool I/O and Skill activation ledger before
shutting down the owned Keeper/session. Compare returned scope and content;
operation success alone does not establish correct browsing or Skill use.

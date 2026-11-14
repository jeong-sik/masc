### Internal

- Nine suites that failed in the nightly test lane now check what the product
  does today. The Board suites expect a deleted post's comments to be refused
  with the post, a store whose file changed behind it to refuse writes and
  evidence reads, an Internal post's deletion to be announced without naming
  the post, a pending deletion to finish at the next Board start, and a
  Consumed attention candidate to be pruned one wake after its partition
  settles. The GitHub checks fixture carries run ids, the Discord connector
  aggregate reads its binding store from a temp directory, and the artifact
  route case spreads its refused writes over three operators so none reaches
  the per-agent burst. `Board_attention_parent_fixture` reports why the Board
  refused to start instead of a bare `Invalid_argument` (#42430, #PENDING).

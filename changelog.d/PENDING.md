### Internal

- The merge sweep reads a branch's open pull requests again, by head and by
  base, right before it deletes that branch. A pull request opened while the
  sweep was deleting other branches keeps its branch, and a branch whose open
  pull requests cannot be read stays. Before, the sweep listed the open pull
  requests once and then deleted branches for the rest of its 20 minutes. The
  repository's default branch is never deleted, whatever its name, and when
  the default branch cannot be read nothing is deleted (#51677, #PENDING).

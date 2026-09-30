# Token prune transaction: local source evidence

`parse-only.log` records successful OCaml 5.5.1 syntax parsing of the Auth interfaces, private store, new feature operation, CLI and feature test. Parsing does not typecheck or run those files. `diff-check.log` records whitespace verification. `ignore-lint.log` records the targeted ignore justification check, including the feature test. `provenance.json` pins the exact inspected source bytes and commands.

Twelve feature scenarios are committed for native CI, including real credential-writer admission ordering, preview, validated UUID cleanup, forged UUID and traversal refusal, read-before-write failure, preservation, actual dangling raw-token removal and partial deletion. They were not executed locally. No local Dune build, native test, deployed CLI, network or CI was exercised.

The composed local parent is `219ff24a8ab705af76620af8039b614c3d5f81b1`: expiry stack `9d2e0d1448b27bd8952a5fcc51b8ba6e1015c607` plus the root's parent refusal assertion repair `886762f483` (exactly two `error`→`code` assertions). Those parent test changes are outside the prune delta. Original prune commits `072783ceed` and `2d587d4cbd` are composed on this parent; Auth's existing `let _stat` presence lookup is retained.

The current expiry inventory rule is used directly, preserving malformed input and the entire live expiry second. main's test/dune import, expiry include and prune include are all retained. This is a partial local source composition, not a complete current main tree or a published commit. Root owns publication and native CI.

`changelog.d/999998.md` is a positive numeric placeholder with matching `#999998` citation; root must replace it with the prune PR number before publication. The expiry parent's `999999.md` placeholder is unchanged. Older Play/expiry source evidence remains historical to its own captured source; this folder pins the prune composition bytes only.

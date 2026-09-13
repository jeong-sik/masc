# Owned restart configuration replacement validation

Thirteen tempfile tests cover candidate preparation without exposing new TOML,
original-hash and during-stop conflicts, missing arguments, invalid TOML, symlink
rejection, exact private-byte replacement, failures before and after rename, and
explicit before/after-hash reconciliation of a retained intent. These tests do
not stop a real process. Lifecycle ordering was separately reviewed in source.

The prepared full curator configuration preserves every existing parsed setting.
The live TOML still hashes to the recorded original and was not changed. This
archive contains hashes, not its private configuration bytes. Actual restart,
post-restart state preservation and successful exact-lane admission remain
separate acceptance steps. See the matching audit for retry behavior and the
process-interruption (not power-loss) limit of the operator state record.

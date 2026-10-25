# Cancellation after actual recovery record removal

Related to #25860 and the surviving #25740 atomic-write scope. This layer is
based on #46016 at 8a28193fb66a6a684baa839e7d0c3682b9227ce7.

The previous discharge witness cancelled before the recovery operation began.
It cannot prove what happens after a real record mutation. Two new controls
raise cancellation immediately after the actual exact Owned record unlink,
before directory sync: once after published replacement and once during cleanup
of an original Write_payload failure. They read the actual owner-area directory
through the store capability before/after, require the removed record to be
absent, check old/new target bytes and staging absence, and require exact
recovery phase/effect, original cancellation reason/backtrace and retained write
primary/backtrace. The fault supplies no record, writer, effect or durability
outcome. Its binding is fiber-local and limited to exact owner and typed record
kind. The workspace-only facade is not installed with the public fs library.

Source inspection found that remove_exact_source did not capture cancellation
with its actual removed flag. The outer run_mutation could report its last
completed Owned_record_durable state, although the file was already gone.
The repair carries Source_removal_durability_unknown from the real inner
boundary and preserves an already typed inner cancellation rather than nesting
it inside a stale outer observation. Existing writer/sync order, public API,
on-disk format and cancellation protection are unchanged.

Test-only baseline fd7ad319107aee9d9452724759cb4a8210ba5e3f was dispatched as
[40234530023](https://github.com/jeong-sik/masc/actions/runs/40234530023), selecting
only test_fs_compat_capability_write with minimal=true. Actual result is unread.
Parsing and whitespace pass; corrected selected execution and independent source
reviews are pending at creation. No local Dune build/typecheck was run.

This is an explicit cancellation-exception fault at a real filesystem boundary.
It is not a physical fsync failure, cooperative parent-cancel timing proof,
power-loss/abrupt-crash test, full regression, runtime install or deployment.
The outer lane-scope release fault is not used as a substitute for mutation.

# Owned sampling recovery boundaries (#40960)

This response is against published2e34863666dde7dd334adb47dee397b81358f928.
It fixes two review findings: fallback publication previously returned an address
that public readers refused when the canonical parent was unreadable; fallback
readers followed symlinks and accepted matching hardlinked external bytes.

write_sampling_blob now uses the same missing/directory canonical states as
readers when deciding whether fallback can be advertised. The existing private
bounded file reader retains its limit-before-full-allocation and charged-budget
behavior, uses the shared owned-file boundary for no-follow parent/descriptor
validation, and explicitly checks single-link identity before and after reading.
This includes snapshot device/inode/size/mtime/ctime verification. It does not
claim the shared range helper alone rejects hardlinks.

Three final-fixture cases were executed against the original production file:
all three failed at their intended assertions (unreadable address, external
symlink, external hardlink). The clean RED logs and source/binary hashes are
retained. Restoring the repair and rebuilding passed all32 worker tests.
Earlier attempts had a fixture optional-argument compile error, a parenthesis
compile error after separating link cases, and a dangling-symlink cleanup error;
those logs are retained distinctly and are not the final RED proof. The fixture
now unlinks its test link in Fun.protect and keeps both bounded/unbounded checks.

Build command: DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build
test/test_lane_addon_worker.exe. Clean RED selected lifecycle0,1,2. Final worker
execution used the declared test/dune env: blank MASC_BASE_PATH/ZAI_API_KEY/
TYPESAFEAI_API_KEY, false sandbox preflight/playground, and checkout DUNE_SOURCEROOT.

This is focused native proof, not full-suite/CI/production proof. #40960 bounds
the encoded payload and does not promise full-frame evidence preservation. The
separate history-scan P1 and stdio readiness issue remain open.

## Earlier response checkpoint

The source and binary hashes in this directory describe tree `0147eb99c1c72913ae915c3237d9be59c40b96d4`, before the subsequent owned-parent publication repair. Current final source/binary hashes and the 35-case execution are in [the follow-up evidence](../2026-10-05-pr40960-owned-parent-publication/README.md). Earlier raw logs and hashes are preserved.

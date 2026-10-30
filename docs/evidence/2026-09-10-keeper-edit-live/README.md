# Actual Keeper Edit artifact proof

The isolated 17b9 CI binary running on port 18937 retained the earlier conversation and playground. During the Poppler correction operation, Keeper called Edit through its normal tool loop. The tool-calls API returned success with a durable result manifest and both snapshot references. Independent reads checked SHA256 and byte length of all three blobs; the manifest records Docker execution and stored snapshots. The diff is derived from those exact historical blobs, not the later current file.

This verifies the successful live path of PR34960. It does not exercise its injected post-commit storage failure, prove chat/browser diff rendering, or accept the generated PDF. The changed script remains part of ongoing PDF quality work.

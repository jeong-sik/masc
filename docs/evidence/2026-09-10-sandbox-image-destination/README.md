# Local ARM64 creative image verification

CI run 34404224985 exported source `de1d81f9662cecad3117e22a17df9bbaff3a86b1`. The downloaded archive, recipe, receipt and all 14 CI files passed byte-count and SHA-256 checks. Docker loaded the unique CI tag in local Colima.

The CI inspect ID is the archive config digest. Local containerd-backed Docker reports the OCI manifest digest instead; the archive index links that manifest to the same config. RootFS layer digests match. This distinction must be retained when comparing image identity.

The existing creative fixture ran locally with a read-only root filesystem, no network, no capabilities, and UID 65532. It exited 0 after creating and reopening all 14 artifacts. PDF and slide PNG renders were visually inspected and contain readable Korean text. Actual outputs and receipt are included here.

This proves image capabilities on the destination architecture. It does not prove autonomous Keeper creation, multi-turn continuity, or production deployment. The isolated Keeper guide operation separately failed with RateLimited; its earlier PDF remains rejected for unreadable rendering.

# Local ARM64 creative image verification

CI run 34404224985 exported source `de1d81f9662cecad3117e22a17df9bbaff3a86b1`. The downloaded archive, recipe, receipt and all 14 CI files passed byte-count and SHA-256 checks. Docker loaded the unique CI tag in local Colima.

The CI inspect ID is the archive config digest. Local containerd-backed Docker reports the OCI manifest digest instead; the archive index links that manifest to the same config. RootFS layer digests match. This distinction must be retained when comparing image identity.

The existing creative fixture ran locally with a read-only root filesystem, no network, no capabilities, and UID 65532. It exited 0 after creating and reopening all 14 artifacts. PDF and slide PNG renders were visually inspected and contain readable Korean text. Actual outputs and receipt are included here.

This proves image capabilities on the destination architecture. It does not prove autonomous Keeper creation, multi-turn continuity, or production deployment. The isolated Keeper guide operation separately failed with RateLimited; its earlier PDF remains rejected for unreadable rendering.

`archive-destination-identity.json` was produced by the new archive verifier.
All eight blob hashes and linked descriptor sizes were verified. The OCI index,
manifest, configuration, Docker export layer list and uncompressed diff IDs
agree. Destination descriptor, rootfs and configuration fingerprint agree with
that archive. Its ID is explicitly classified as `manifest_digest`; the build
engine ID is classified as `config_digest`, never compared as equal IDs.

The export manifest now records separate `config_digest`, `manifest_digest`,
`manifest_media_type`, `build_engine_id` and `build_engine_identity_kind` fields.
To verify a loaded destination without rebuilding, run:

```sh
python3 scripts/verify-sandbox-image-archive.py \
  --artifact-dir /path/to/downloaded-artifact \
  --expected-commit SOURCE --architecture arm64 --image-tag EXACT_TAG \
  --destination-inspect /path/to/destination-inspect.json \
  --output /path/to/fresh-verification.json
```

Four behavior tests cover differing valid engine IDs, changed blob bytes,
linked size mismatch, and changed destination metadata despite a matching ID.

The configuration fingerprint covers all configuration fields, including nonempty User, Entrypoint and WorkingDir. Only explicitly enumerated false/empty legacy serialization defaults, empty User/WorkingDir, and null Entrypoint/Volumes/OnBuild are normalized to omission; unexpected fields or changed execution settings fail verification.

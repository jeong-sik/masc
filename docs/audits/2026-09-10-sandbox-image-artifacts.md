# Installable Keeper sandbox images from CI

The creative-image scenario originally proved an amd64 CI image but exported
only example files. A local arm64 operator still could not use that image
without rebuilding it. The Keeper sandbox image workflow builds native amd64
and arm64 artifacts on their respective runners, using the actual embedded
recipe module compiled in CI. It has no copied package list.

Each image runs the creative-artifact scenario as an unknown non-root UID with
a read-only root filesystem and no network before export. The Docker archive
is compressed and accompanied by its SHA-256, byte count, image ID, exact
source revision, architecture, recipe hash and smoke receipt hash. Both
architectures keep their own proof files. A failed smoke produces no verified
image artifact. No registry tag is published or runtime restarted.

Before loading, compare the downloaded archive and recipe hashes with the
manifest and check its revision against the expected PR head. After loading,
read the image ID and architecture independently from Docker and compare them
with the manifest. Select the unique CI tag in the intended Keeper's existing
`sandbox_image` setting; loading alone does not change a running Keeper.

Workflow lint passed locally. Image builds, exported archive verification and
actual local Keeper use are pending CI artifacts. No local build was run.

# Configure the existing per-Keeper sandbox image

The Keeper already carried a TOML-owned `sandbox_image`, but its config API and
Up argument surface omitted it. The existing field now accepts a nonblank image
string through Up and config POST; config POST also accepts null to remove the
override. Omitting it retains the current declaration. No environment variable
or parallel setting is introduced.

The requested image is used by admission preflight before materialization.
Create/update and full/partial TOML persistence carry it, and config GET exposes
the materialized optional field. Clearing removes the declaration so normal
runtime image resolution supplies the default.

The existing owner lifecycle fence still controls lane replacement. An admitted
turn keeps its immutable metadata and sandbox; updating during that turn can
commit the next configuration but returns `keeper_turn_in_flight` instead of
restarting the lane. Retry Up when idle to replace it. This change does not
claim an image update hot-swaps a running container.

Tests cover typed config API acceptance/refusal, requested-image preflight,
TOML set/retain/replace/clear, GET projection, and image update while the owner
turn is busy. No local build or runtime image mutation was performed; CI and
deployed API/disk/container evidence remain required.

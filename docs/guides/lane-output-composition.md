# Connect completed Lane outputs through TOML

An installation can read the latest completed output of another installation in
the same run. The connection is generic: neither the source adapter nor the
consumer needs an MSX, Browser, DOS, or metrics dispatcher in MASC.

```toml
[[binding.sources]]
source_id = "game"
kind = "lane_output"
installation_id = "msx-frames"
selection = "latest_completed"
```

`installation_id` refers to the stable ID in an installation declaration. The
host captures the actual applied configuration revision, package revision,
instance ID, run ID, completed observation sequence, output, and worker coverage
together. It preserves upstream row IDs, clocks, actors, timestamps, and source
coverage. The output receives a retained content-addressed evidence reference.
Acquisition uses the current immutable output, without loading the full history
or repeatedly copying referenced HTML or pixel bodies.

An absent, stopping, or different-run producer yields incomplete coverage with
no fabricated observation. A failed producer may still have a completed output;
its worker status and the source's gaps remain explicit. Each input is captured
at its own read time: this is not an atomic snapshot of an entire world and does
not combine independent clock domains.

Committing producer output wakes its direct consumers. Repeated notifications
use the existing coalescing behavior. Cyclic connections are rejected before
retiring an already applied installation. Removing or replacing a producer
notifies consumers that their input is unavailable even if cleanup is pending.
These checks apply to the optional connection, not to Keeper tasks or tools.

The [output-statistics package](../../addons/output-statistics/README.md) is an
example consumer. Its value rows count the rows actually supplied by each
producer, with a separate input-completeness indicator. It does not accumulate
repeated reads into a world event count. Its [installation example](../examples/lane-addons/output-statistics.toml)
connects an existing MSX observer installation without a domain-specific UI
component. For DOS, use [the DOS statistics declaration](../examples/lane-addons/dos-statistics.toml)
with the [DOS installation](../../addons/dos-world/install.toml). Both declarations
use `run_id = "dos-demo"`; the consumer's `installation_id = "dos-demo"` selects
the producer's stable installation ID. Adjust each manifest path when copying the
declarations into the active configuration directory. The statistics still count
output rows, not the guest's counter or game score.

The required package images can be built and exported by the Lane Add-on
package images workflow; adding a package with `lane.toml` and `Dockerfile`
includes it in that workflow's discovery.

Upstream row references are preserved in fields and evidence. This slice does
not add cross-Lane connector lines or reinterpret the worker's local
`related_ids` as external IDs. It also does not add an action port or DOS machine
owner. These are separate contracts from reading a completed output.

The source adapter and package tests use controlled data. Host and Dashboard
revision `2ffb1e772c73dc4d6c94262f09d30a3e61ae7989` also passed an isolated actual
Docker/server/browser scenario: a controlled MSX-format capture fed statistics
through TOML, repeated cursors did not accumulate counts, and partial input,
producer replacement/removal and retained evidence were inspected. The host
came from [native CI](https://github.com/jeong-sik/masc/actions/runs/34699594706)
and [Dashboard CI](https://github.com/jeong-sik/masc/actions/runs/34698924065).
This qualifies the connection and its coverage behavior; the capture fixture
does not establish real MSX gameplay, Keeper reasoning or production deployment.

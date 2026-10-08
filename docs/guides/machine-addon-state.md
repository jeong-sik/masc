# MSX and DOS Add-on state

This guide describes the source candidate. Focused remote tests exercise worker
stdio behavior, but Docker images and volume replacement remain unverified.
Each Dockerfile requires its target-architecture Linux worker executable in the
build context. A successful loader check alone does not establish MCP or game
behavior.

## Install a persistent machine

Use a configured installation for a machine you want to resume. Copy the
[MSX declaration](../examples/lane-addons/msx-machine.toml) or
[DOS declaration](../examples/lane-addons/dos-machine.toml) to
`<resolved-config-root>/lane-addons/`, adjusting `manifest_path` to the actual
package location. Prepare the matching image in the Docker engine MASC uses.
Reconciliation applies the declaration; inspect its applied state before making
machine calls. The machine packages need no input source of their own.

Each worker mounts its package read-only at `/addon` and a named Docker volume
at `/state`. Its executable receives `--base-path /state`. Tools, observation
rows and package skills are supplied by that installation. Host machine activity
settings still govern execution and input; storing media does not enable play.

The volume identity includes the canonical host Lane store path, declaration
ID and package ID. Keeping all three preserves the volume across image/revision
replacement. Renaming the declaration ID, changing the package ID or moving the
workspace creates a different state identity. A manual Attach uses its instance
ID instead: a later manual Attach does not resume the earlier volume.

Detach/disable removes the worker, not its named volume. It does not save live
CPU/RAM state automatically. Save a checkpoint and confirm its receipt before
stopping a machine you want to resume. A replacement worker starts unloaded;
restore an explicit checkpoint after it becomes available. DOS may report an
autosave, but does not restore it automatically.

## Files inside the volume

| Worker path | Contents |
| --- | --- |
| `/state/.masc/msx/bios/` | BIOS inventory; automatic inventory selection checks `cbios_main_msx2.rom`. Supply the ROM set required by the chosen machine. |
| `/state/.masc/msx/carts/` | Cartridge and floppy images selected by inventory name. |
| `/state/.masc/msx/saves/<slot>.json` | Named MSX machine checkpoints. |
| `/state/.masc/dos/programs/` | COM/EXE files or game directories; select `boot` for a directory containing multiple programs. |
| `/state/.masc/dos/saves/<program>/` | Files written by the DOS guest, retained separately from whole-machine checkpoints. |
| `/state/.masc/dos/checkpoints/` | DOS machine checkpoints, including autosave slots. |
| `/state/.masc/dos/pads/<program>.toml` | Optional per-inventory pad layout overrides. |

Machine input ledgers also live under the respective `.masc/msx` or `.masc/dos`
directory. Copying only a checkpoint file is not a full state backup. Retain the
whole machine directory when transferring an existing installation.

Explicit MSX media paths refer to the worker filesystem. A file included in the
package can be addressed under `/addon`; a host path outside the package is not
implicitly mounted. DOS program names resolve within its `programs` inventory.
No game images are included by these packages.

## Provision or transfer state

1. Let the configured installation create its volume, then set `enabled = false`
   and wait for the applied installation to report detached. Do not write into a
   volume while its machine is active.
2. Identify its Docker volume and inspect `Labels["masc.lane.state.owner"]`.
   Verify the canonical Lane store, configuration ID and package ID. The volume
   name is a digest, not a human-readable installation name. Do not infer
   ownership from a name prefix alone.
3. Mount that verified volume in a temporary helper container and copy the
   staged machine directory to the paths above. For a new installation, create
   the inventory directories and copy only media you intend it to use. For a
   transfer, preserve the original host directory and use a fresh destination;
   do not merge over existing saves or checkpoints.
4. Remove the helper, re-enable the same declaration and inspect applied state.
   For MSX use `masc_msx_meta` with `include_inventory=true`; for DOS use
   `masc_dos_inventory`. Verify the expected media before loading. After restore,
   check the reported program/media and a fresh screen before sending input.

Docker volumes are managed by the Docker engine, including when the host is
macOS. The old host `<base-path>/.masc/msx` and `dos` directories are not bind
mounts of `/state` and are not automatically imported or deleted. Copying them
requires an explicit transfer. Checkpoint readability also depends on the worker
core version; retain the original files until restore and image checks succeed.

For read-only volume discovery:

```sh
docker volume ls --filter label=masc.lane.state.owner
# Set state_volume to the exact selected volume, then inspect its owner label.
docker volume inspect "$state_volume"
```

The host rejects a state volume whose recorded owner does not match. Do not
change owner labels to force a different installation to reuse it. Use a copied
backup and a fresh installation when moving state between owners.

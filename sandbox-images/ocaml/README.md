# `ocaml` sandbox recipe

`Dockerfile` builds the image Keepers run their tools in for MASC development:
the compiler `masc.opam` pins and MASC's whole dependency set. `inputs` lists
the repository files the recipe copies; they and the Dockerfile's own bytes
make up the image's input hash.

The Dockerfile keeps its comments to one or two lines and the reasons live
here, because the file's size decides whether it builds. Apple's `container`
CLI sends the Dockerfile to its builder in a gRPC header, whose default ceiling
is 16 KiB (apple/container#735). The CLI refuses a file of 16,384 bytes or more
itself; a file somewhat under that still fails, with
`Error: unavailable: "Stream unexpectedly closed."`, before BuildKit starts.
With container CLI 1.3.1 and builder 0.13.1 on 2026-09-28, a copy of this
file cut to 14,829 bytes started and one cut to 15,057 bytes did not (#39447).

## Base image and compiler

`masc.opam` pins `"ocaml" {= "5.5.1"}`. An `ubuntu:24.04` image with
`opam switch create ocaml-system` resolved to the distribution compiler (4.x),
so `opam install --deps-only` for this repository could never succeed there.
The upstream opam image ships a built compiler, which also saves a 20-40
minute compiler build on every rebuild.

The `ocaml-5.5` base tag ships 5.5.0 and pins `ocaml-base-compiler` to it, so
`--deps-only` cannot solve against the 5.5.1 pin (#34143, for the 5.5.1
security and runtime-leak fixes). With that pin in place the only route to
5.5.1 is `ocaml-variants`, which wants libunwind-dev and autoconf that are not
installed, and the build stops with "No solution found". Dropping the pin and
moving the switch invariant keeps the compiler on `ocaml-base-compiler`, so no
depext is needed and the switch keeps the name "5.5" that the
`OPAM_SWITCH_PREFIX` paths spell out.

`scripts/check-sandbox-ocaml-version.sh` reads the compiler version out of the
Dockerfile and fails CI when `masc.opam` asks for a different one.

## Everything is baked in

Keeper tool dispatch runs each turn in a fresh `docker run --rm` container with
a `--read-only` rootfs and `--cap-drop=ALL` (`keeper_sandbox_docker.ml`,
`docker_run_argv`), so a Keeper cannot install anything at run time. Whatever
a Keeper needs to build must already be in the image.

`/tmp/keeper-creds` is a volume because masc projects each Keeper's GitHub and
SSH credential bundle there (`keeper_sandbox_runtime_setup.ml`).

## Vendor apt repositories

GitHub CLI comes from its own apt repository. The Ubuntu archive package trails
upstream by months, and Keepers authenticate and drive PRs through `gh`.

Node comes from the nodesource apt repository, with the same keyring and
signed-source shape. Ubuntu 24.04 ships nodejs 18.19, while
`dashboard/package.json` declares `"engines": {"node": ">=22"}` and
`"packageManager": "pnpm@10.31.0"`. Measured 2026-08-26: pnpm installed on top
of apt's node 18 is on PATH and unusable -- `pnpm --version` answers "requires
at least Node.js v22.13". The contract test cannot run the image, so it checks
that the `node_22.x` source and the `pnpm@10.31.0` pin are both there.

pnpm is pinned to the version the repository declares, so the image tracks the
project rather than the registry's "latest".

## System packages

The -dev packages are the depexts opam reports for this dependency set
(`opam install --deps-only --depext-only --dry-run`): libgmp-dev,
libprotobuf-dev, libsqlite3-dev, libssl-dev, pkg-config, protobuf-compiler.
They are installed by apt rather than opam because the opam stage runs as a
non-root user and the container has no package manager access at run time.

libncurses-dev is there because the build stopped without it. Measured
2026-08-26, the opam solve failed with

    Missing dependency: conf-ncurses
    depends on the unavailable system package 'ncurses-dev'

conf-ncurses names the depext `ncurses-dev`, which is not a package on Ubuntu
24.04; the name there is `libncurses-dev`. The image then on disk predated
whatever pulled conf-ncurses into the solve, so the failure only appeared on a
rebuild, as exit 20 out of the opam stage with no other clue.

## Measured tool usage

The command list follows what Keepers actually invoke.

- 35,919 filesystem tool calls (2026-08-20..26) added procps (ps/pgrep/pkill,
  35 uses), lsof (7), fd (2), zsh (3) and trash (39).
- 93,111 Execute records (2026-09-10..24) found commands neither this image nor
  the general one had: file (20 calls from 12 Keepers), ip, ss, nslookup and
  dig (37), python3's yaml module (15), time (8) and xxd (7).
- pip is there so a turn can make a venv inside its workspace. The rootfs stays
  read-only, so nothing lands in the image at run time.
- `gtimeout` and `fd` are symlinks for the names Keepers type.

The commands left out on purpose, with their reasons, stay in the Dockerfile
next to the package list; `test/test_keeper_sandbox_image_contract.ml` reads
them from there.

## Playground

`MASC_KEEPER_DOCKER_PLAYGROUND_ROOT` defaults to `/home/keeper/playground` and
is supplied as a bind mount. The container runs as the host uid/gid
(`--user <uid>:<gid>`), which matches no image account, so the mount point is
created up front and left group/other writable.

## Dependencies

Only the package metadata is copied. The dependency set belongs in the image;
copying sources would pin the image to one commit of the repository a Keeper is
about to clone itself.

The pins are replayed explicitly. The packages under `pin-depends:` in
`masc.opam.locked` are absent from opam-repository, so `--deps-only` alone
fails to solve, and opam does not apply the lock file's `pin-depends:` on its
own here.
`scripts/opam-pin-from-lock.sh` records what was tried and how each option
failed.

`COPY --chown=opam:opam`: COPY writes as root, but this stage runs as `opam`,
so the cleanup at the end of the install step could not remove root-owned
files.

`--with-test` pulls alcotest, qcheck-* and bisect_ppx, which `masc.opam`
declares under `{with-test}`. Without it `dune build @check` fails on every
test stanza: a Keeper that cannot run the suite cannot verify its own change.

## Switch environment

Tool dispatch invokes `bash -c`, which reads neither a login profile nor an
opam environment, so `eval $(opam env)` never runs. Exporting the switch
variables is what makes the installed packages visible: with only the binaries
on PATH, dune runs but every `(libraries yojson ...)` stanza fails with
"Library not found", because dune resolves libraries through
`OPAM_SWITCH_PREFIX`.

The switch name is fixed by the base image tag (`ocaml-5.5` yields switch
"5.5"). The `lib/yojson` check fails the build if that stops holding, instead
of shipping an image whose dune cannot see any library.

`OPAMROOT` is stated rather than discovered. The entrypoint inherited from the
base image is `opam exec --`, and opam looks for its root at `$HOME/.opam` when
nothing says otherwise. masc sets HOME to `/tmp` for every container it starts
(`keeper_sandbox_runtime_setup.ml`, #12036, for a sandbox UID mismatch), so
that lookup finds nothing and the entrypoint exits 50 with "Opam has not been
initialised" before the requested command runs. Turn containers start with
`--rm`, so the Keeper sees "no such object", which names the symptom and not
the cause. Where opam lives is a fact about this image, not about whoever runs
it.

## Permissions

The container runs as the host uid, which matches no account in the image, so
every path it reads has to be world-readable. `/home/opam` ships 0750 and the
switch below it 0755; the parent is what denies, and PATH pointing at
`${OPAM_SWITCH_PREFIX}/bin` does not help when the directory above cannot be
traversed.

Measured 2026-08-26: `docker exec` as the host uid answered "Permission denied"
for `${OPAM_SWITCH_PREFIX}/bin/dune`, and the live fleet showed "OCI runtime
exec failed, exit 127, dune build" five times in 24 hours on the Keepers that
run containers. The fix adds traverse and read only; no write bit, and the
switch stays owned by opam.

The `test -x` after the chmod runs as root, and root traverses a directory
whether or not o+rx is set, so it stays green with the chmod deleted (that was
measured). It still catches the switch moving out from under
`${OPAM_SWITCH_PREFIX}`. Reachability is asked by the final check.

## Final check

The last step runs as a uid that matches no account, because that is what a
Keeper is: masc passes `--user <host uid>:<gid>` and mounts an `/etc/passwd`
that names it "keeper". A root check would prove nothing -- root ignores the
permission bits this is meant to catch; deleting the chmod was tried and a root
check stayed green.

It runs `opam exec` with `HOME=/tmp`, the value masc passes, so it is a Keeper
turn in miniature: if `OPAMROOT` or the chmod stops covering that shape, the
build fails here rather than in a container that vanishes before anyone can
look at it. The version it prints lands in the build log, the cheapest place to
read what shipped.

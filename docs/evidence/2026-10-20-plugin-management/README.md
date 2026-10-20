# Plugin management: Dashboard execution evidence

2026-10-20 KST. This is the real `LaneAddonsPanel` and its real HTTP decoders,
installer, declaration editor and activity panel against an isolated HTTP fixture.
It does not prove a live MASC configuration write, worker launch, Docker image
availability, native ego installation or production Dashboard deployment.

`proof-server.mjs` serves only local fixture routes using the Dashboard's installed
Vite/Tailwind dependencies. Run it from the repository root with Node; it prints
its local URL. `proof-client.ts` mounts the actual Dashboard component and styles
with a fixture workspace authority. `/fixture` paths are synthetic identifiers;
the fixture stores documents in memory and writes no MASC configuration files.

Native ego space 4 was operated by the coding agent:

1. Open the component; inspect the five installation states (`manager.png`).
2. Search for ego-browser, then Check observation. The recorded request names only
   `worker-ego`; its displayed observation sequence advanced from 3 to 4.
3. Filter Needs attention. The failed cleanup stays visible with Requested: Off
   and its failure; it is not reported as a successfully stopped worker
   (`attention-snapshot.txt`). Search/filter actions send no mutation requests.
4. Choose the fixture package in the installer, enter installation ID, Run ID and
   binding path, prepare the TOML draft and explicitly Save TOML. Exactly one
   declaration POST was recorded. The new installation appears as Waiting for
   first application with Check observation disabled (`installed.png` and
   `installed-snapshot.txt`); the fixture deliberately starts no worker.
5. Open On/off for that saved installation. Its actual file activity and retained
   source revision appear in the existing activity panel (`activity-snapshot.txt`).

`http-events.json` retains the fixture HTTP requests. `source-hashes.json` binds
the implementation and PNG bytes used in this run. Both screenshots were opened
and visually inspected. After verification, ego `finish({keep:[]})` resolved once
and the owned fixture server received SIGTERM (`cleanup.json`).

`focused-tests.txt` records **111 passing tests in seven files**, including nine
new DOM scenarios. Those scenarios exercise ownership mismatches, retained and
ambiguous workers, missing application evidence, cleanup failures, incomplete
inventory, stale refreshes, search/filter behavior and identity-bound callbacks.
The existing installer/CAS/workspace/navigation/Slice tests remain in the run.
Dashboard `tsc --noEmit`, ESLint for changed implementation/test files and
`git diff --check` passed. No local OCaml build or full CI was run.

The interaction reference was the installed extension search/filter and explicit
management flow in [VS Code's official extension guide](https://code.visualstudio.com/docs/configure/extensions/extension-marketplace).
Application/cleanup meanings come from MASC's existing
`lib/lane_addon/lane_addon_application.ml`, not from revision equality.

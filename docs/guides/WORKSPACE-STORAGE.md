# Repository documents and run output

[한국어](WORKSPACE-STORAGE.ko.md)

Choose a location by what the file is for. All paths in this table are relative
to the MASC repository, except the explicitly marked runtime paths.

| Content | Location | Treatment |
| --- | --- | --- |
| Research, prior art, comparisons and design investigations | `docs/research/` | Versioned, with sources and uncertainties; a proposal is not a decision |
| Retained verification records and supporting captures | `docs/evidence/<topic-or-run>/` | Versioned intentionally; preserve provenance and the limits of the observation |
| Reports that explain findings, results and remaining work | `docs/reports/` | Versioned narrative; link to supporting evidence rather than copying captures |
| Reusable contributor and operator knowledge | `docs/guides/` | Maintained instructions, checked against current behavior |
| Accepted design and interface decisions | `docs/design/`, `docs/rfc/` | Follow the existing design/RFC process |
| Dashboard reproduction fixture source | `dashboard/fixtures/<topic>/` | Source, with dashboard dependencies; output goes under `artifacts/dashboard/` |
| New local measurements, screenshots, generated reports and scratch output | `artifacts/<topic-or-run>/` | Git-ignored working output; captured Dune rules are not evaluated; no automatic deletion |
| Keeper runtime records | `<base-path>/.masc/` | Owned by the running product; use its tools and APIs |
| Published report catalog | `<base-path>/.masc/published_artifacts/` | Managed publication metadata; bodies use the blob store |

A research document can discuss a measurement, but the retained run record belongs
under `docs/evidence/` and is linked from the analysis. In particular,
`docs/evidence/research/` holds the run records and source/provenance supporting
investigations; `docs/research/` holds their analysis and conclusions. A polished report belongs
under `docs/reports/`; reusable instructions belong under `docs/guides/`. MASC
research belongs in this repository, rather than a second repository-local
`knowledge/` tree. An operator's independent workspace knowledge base is outside
this repository's ownership.

## Capture, retain, explain

1. Write a new run into `artifacts/<topic-or-run>/`. Keep distinct runs separate
   when comparing before and after results.
2. Select the proof needed for the change. Check for credentials, private
   conversations and host-specific data before including it in a PR.
3. Retain that selected bundle under `docs/evidence/`, with a README explaining
   the source head, environment, commands, observed results and unverified scope.
   Do not replace an earlier run's capture with a new run. A copied reproduction
   helper can stay with a retained bundle, but must write new output elsewhere.
4. Link the bundle from the research, report or PR that interprets it. If a
   capture is sanitized or regenerated, identify it as a derivative; preserve
   the original digest's meaning instead of claiming the changed bytes match it.

Capture-time path/digest manifests retain their original bytes. When their files
move, link a separate `current-locations.json` from the bundle README. Its current
addresses locate retained captures or editable reproduction sources; an old digest
does not certify edited current source. Use
`scripts/check-evidence-locations.py` with explicit sidecars to check locations,
retained capture bytes and historical Git objects.

Git ignores common capture extensions such as logs. When intentionally retaining
such a file, inspect it and add the individual path with `git add -f -- <path>`.
Do not force-add an entire working-output directory.

`artifacts/` is a local output directory, not the dashboard's publication catalog.
Publish a report explicitly through `keeper_artifact_publish` or the published
artifact API. The product does not recursively index arbitrary folders. See
[report publication](../design/report-artifacts.md#storage-and-authority).

Existing benchmark datasets and package fixtures keep their documented input
contracts. An output directory inside a downloaded CI artifact is local to that
artifact's archive; it does not create another repository evidence root.

## Runtime boundary

Resolve the runtime root from the server's effective base path. With base path
`/path/to/workspace`, it is `/path/to/workspace/.masc`, regardless of the checkout's
current working directory. Runtime `evidence/`, blobs and published artifacts are
different owned stores, not aliases for repository documentation. Do not rename
or merge them as a repository cleanup.

The [evidence provenance note](../evidence/README.md) explains sanitized captures.
The [research index](../research/README.md) lists investigations; the
[report index](../reports/README.md) lists retained reports.

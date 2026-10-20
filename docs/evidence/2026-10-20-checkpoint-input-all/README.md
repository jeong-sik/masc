# Canonical checkpoint file-read allocation

The live process allocation profile on 2026-10-20 identified
`Keeper_checkpoint_store.load_canonical_bytes_strict` as a substantial cumulative
allocation site. The sampled profile attributed about 28.95 GB to that reader
over the process lifetime. This is sampled, cumulative process data with dropped
samples, not the bytes retained in memory or an endpoint-specific measurement.

The reader previously expanded a Buffer and copied its final contents. For a
stable-size regular file, OCaml 5.5.1's `In_channel.input_all` allocates from the
descriptor's remaining length and returns that storage without the final copy.
The installed standard-library source, `stdlib/in_channel.ml` lines 153–193,
also handles files growing or shrinking. Those fallback paths can still copy.
The existing regular-file admission, file identity, Eio offload, decode, and
checkpoint source-admission rules remain in place.

## Reproduction

From this checkout, with git and OCaml 5.5 available:

```sh
python3 docs/evidence/2026-10-20-checkpoint-input-all/read_probe.py \
  --before c3e7acc0e28c7b46d7906b2f9a927e3d9c6e1e58
```

The probe extracts both actual private reader function bodies. It uses real
Unix descriptors and channel I/O; only Eio offload and the file-identity adapter
are stubbed. Eight binary file sizes from zero to 32 MiB and one UTF-8/NUL case
preserved exact bytes. Missing files, directories, and symlinks produced equal
results. These checks do not exercise concurrent file mutation.

Observed output on the development machine:

```text
exact_bytes_cases=9 missing_directory_symlink=equal
before-32MiB elapsed_ms=16.265 allocated_bytes=100668712
after-32MiB elapsed_ms=3.249 allocated_bytes=33555120
```

This is 66.7% less allocated memory for the isolated 32 MiB read. The timing is a
single warm-filesystem observation, not a server latency or cold-disk benchmark.
The probe does not validate native MASC types, linkage, Eio scheduling, locking,
or checkpoint identity admission.

## Native coverage and limits

`test/test_keeper_owned_checkpoint.ml` adds a public-store fixture with a
checkpoint larger than 1 MiB, binary-sensitive escaping, and UTF-8. It compares
both exact canonical bytes and the accepted source reference. The fixture was
added and syntax checked, but not executed. Both changed ML files pass
`ocamlc -stop-after parsing`; `git diff --check` passes.

No local Dune build, native test execution, full CI, installed-runtime test, or
end-to-end browser/TUI performance result is claimed.

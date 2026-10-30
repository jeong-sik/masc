# When Lane Add-ons observe sources

Installing an Add-on performs an initial observation. An explicit `observe`
request always invokes its worker, including when source bytes are unchanged.
This preserves workers that intentionally take another sample or update their
own state. Completing an Add-on action also retains the existing follow-up
observation.

Automatic activity follows the sources in the binding:

| Bound source | Automatic activity |
|---|---|
| `snapshot_file` | A completed Keeper tool is a hint to capture the explicitly bound file again. |
| `msx_capture` | A completed MSX load, eject, restore, disk change, press, step or step-until-change operation. |
| `browser_document` | A completed Browser session, navigation, action or interaction operation. |
| `lane_output` | Existing notifications from the declared producer in the same run. Unrelated Keeper tools do not wake the consumer. |
| No external sources | Initial/explicit observation and the Add-on's own action lifecycle. Unrelated Keeper tools do not sample an owned environment. |

Packages default to `every_hint`: source interest filtering still applies, but
every matching hint invokes the worker even for equal captures. A package whose
automatic observation depends only on changed captured input can opt in:

```toml
[interface]
refresh_policy = "source_changes"
```

With this explicit policy and a binding containing only snapshot files,
automatic capture compares the exact source envelopes with the last
successfully committed observation. Those
envelopes include retained hashes of the original file bytes. An unchanged
capture does not invoke the worker, append a new observation, or wake downstream
consumers. `unchanged_source_refreshes` in instance inspection counts these
skipped refreshes; it is not an output sequence or a completeness measure.

A changed capture, unavailable source, or recovery produces a new observation.
A failed worker/commit is retried on the next relevant activity even if source
bytes match an earlier success. Explicit observations take precedence when they
coalesce with automatic refresh hints.

Native browser and MSX captures, mixed-source bindings, and producer-output
notifications are not deduplicated by this file-only policy. A repeated sample
can carry stateful meaning; the host does not infer otherwise from equal values
or a package name.

This is not a file watcher. An export written outside Keeper activity needs an
explicit observation or a later activity hint. Browser/MSX changes outside the
relayed tool lifecycle likewise need an explicit capture. Bindings currently
have no Keeper-source ownership field, so this policy does not guess which
Keeper owns a file from its name, path, or tool arguments.

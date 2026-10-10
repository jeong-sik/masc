# Process fallback working directory, 2026-10-09

Parent: `ac3f9924b197aeada0e908e72ffb01c6aa024dde` (#41992).
Issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

`Process_eio.with_unix_capture` received `cwd` from status, stdin, streaming and
pipeline runners, but the foreground spawn did not receive it. The child ran in
the parent's directory; even a missing or non-directory cwd allowed execution.
[before.log](before.log) records both failures against unchanged parent production
source. Public documentation acknowledged the asymmetry, but a requested working
directory has concrete execution semantics and should be enforced on fallback.

The synchronous foreground owner validates the complete requested path and opens
the directory, supplies its descriptor to the existing posix_spawnp child actions,
and closes the parent's descriptor on success and failure. No process-global
chdir is used. A directory-open failure retains its errno and cwd and becomes
`Cwd_unavailable`; executable lookup failures remain `Executable_not_found`.
The shared C helper's Eio path still accepts a path, while its synchronous PATH
lookup path accepts the acquired directory descriptor. Both retain group setup,
FD closure and the existing libc lookup semantics. Platform-specific directory
open flags use O_SEARCH on macOS and O_PATH on glibc Linux; Linux execution is
not claimed by the local macOS checks.

Independent review found two acquisition defects in the first published repair.
The NUL-containing cwd was truncated before opening, directly reproduced as an
unexpected echo execution in [review-before.log](review-before.log). The stub now
uses OCaml's standard path check before copying the string. Linux O_PATH also
does not check final-directory search permission: the acquired FD now receives
a descriptor-relative X_OK check using effective credentials, and closes on
denial before spawning. See [open(2)](https://man7.org/linux/man-pages/man2/open.2.html)
and [access(2)](https://man7.org/linux/man-pages/man2/faccessat.2.html).
Child fchdir still enforces permission if it changes after acquisition.

For an initialized runtime, fallback resolves relative/default cwd through the
same Eio path rule and opens the directory through the capability before native
acquisition, matching the native manager's probe. Unsupported/denied Eio directory
access stays an Eio directory error and cannot turn into a child execution.
Without initialization, relative cwd uses the parent's directory. The private
spawn forwarding function is deleted; the actual owner is called directly.
Directory errors use a closed backend distinction preserving the native errno or
Eio error. The existing cancellation cleanup/reraise branch remains in place.

## Consumer verification

| Changed boundary | Direct consumer / scenario | Final result |
| --- | --- | --- |
| Acquired cwd descriptor and native spawn | Status/typed/relative/stdin/streaming/pipeline runners; distinct stage cwd; search-only directory and unchanged parent cwd | New case 0 passed |
| Directory-open refusal | Missing/non-directory/NUL cwd, exact native errno, mode 000 denied for effective UID 502, valid-cwd executable refusal | New case 1 passed |
| Initialized Eio-to-Unix fallback | Real Eio manager with only pipe creation faulted at bind; default/relative cwd and denied capability | New case 2 passed |
| Foreground ownership and refusal | Existing fallback cases 2-14 and 16-19, including descendants, unrelated sibling, exit status and exceptional cleanup | 17 existing cases passed |
| Shared C Eio branch and existing execution paths | Existing cancellation-propagation cases 0-4 and 8-9: cancellation, native cwd, stdin/streaming | 7 existing cases passed |

[checks.json](checks.json) records exact commands, terminal results and executable
identity. Final focused build succeeded. Twenty-seven unique cases passed in
27 executions. The earlier pre-review selection executed new case 2 twice;
its 28 executions and earlier executable identity are retained separately.
Skipped cases are not counted. The initial red check contains two failures; the third
bind-fallback scenario and exact errno assertions were added before final checking.
The strengthened refusal case directly verifies NUL and permission denial on
macOS. Root runs omit the mode 000 denial assertion and must not claim that proof.
The Linux search-permission fix has independent source evidence, not runtime proof.

Intermediate builds are labeled separately: one compiler failure caught a duplicate
cancellation branch, and another caught the test manager's abstract platform tag.
Both were corrected before the final build and all passing selections. An earlier
successful intermediate build does not certify the final source.
Stored terminal logs normalize trailing whitespace; diagnostic content is retained.
[source-sha256.json](source-sha256.json) fingerprints all six changed source files
and three unchanged dependencies inspected for the effect boundary.

## Remaining scope

`process_eio.ml` changes from 2,032 to 2,054 lines: this is a behavior/ownership
repair, not a size-completion claim. Capture/drain, pipeline, refusal, timeout and
process lifecycle responsibilities still need semantic review. The original 171
candidates remain in scope. Tests use controlled local subprocesses and temporary
paths; no live Keeper process, operation, queue or provider was touched. Full
suites/builds, Linux runtime, CI and deployment remain unverified.

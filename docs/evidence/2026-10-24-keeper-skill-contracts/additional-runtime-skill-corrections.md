# Additional runtime Skill corrections

Two more installed instruction packages contained procedures that could turn an
unverified diagnosis or an environment workaround into claimed execution evidence.
Their complete originals were backed up and every file's bytes and SHA-256 checked
before either package changed. Private source and backup paths are not published.

The DNS instructions now distinguish a hostname-resolution failure from a resolver
root-cause hypothesis, compare the same target and query type, inspect response
state and answers, and remove historical destination addresses. They explain that
an explicit DoH bootstrap resolve avoids the DoH server's initial system lookup.
The procedure preserves TLS and existing network authority and does not replay an
uncertain write merely because connectivity recovered. It also separates failed
collection, unverified HTTP content and a verified empty result.

The machine-test instructions now follow the repository's current execution and
dependency-repair contracts. They distinguish pin inspection from installation,
record the complete dependency sources actually linked, and reject identity-only
vendor replacement as proof of an exact pin. A failed build cannot be followed by
executing a retained executable and claiming that result for the current head.
Environment failure, source review, test execution and installed behavior remain
separate observations.

The current argument branches and source comments of
`scripts/opam-pin-external-deps.sh` were read. It provides `--check` and `--install`
with different inspection/mutation semantics, and does not provide `--help`.
`bash scripts/dune-local.sh --help` was run to inspect its existing wrapper
contract. No pin check, dependency repair, download or build was executed.

## Publication evidence

`additional-runtime-skill-publication.json` records this operation's actual server
identity, exact before/after references, hashes and publication results. Both
candidates passed the existing editor preview without diagnostics. The editor
then performed revision CAS, atomic save and catalog publication. Editor, disk
and catalog rereads matched. A final explicit catalog refresh returned unchanged.

| Package | SKILL.md bytes before | SKILL.md bytes after | Save result |
| --- | ---: | ---: | --- |
| microvm-dns-outage | 5,349 | 5,131 | saved_and_published |
| machine-lane-pin-receipt | 5,131 | 5,393 | saved_and_published |

This operation observed 49 catalog surfaces before and after publication. It did
not exercise DNS, a proxy, a network workaround, dependency repair, a build, a test
or a new Keeper activation. Publication and lower instruction byte counts do not
prove improved behavior. The earlier three runtime packages, the managed built-in
bundle and the shared live Keeper prompt were not changed by this operation.

## Primary sources checked

- [curl error codes](https://curl.se/libcurl/c/libcurl-errors.html): error 6 reports
  failure to resolve the given remote host; it does not identify the failing layer.
- [curl DoH option](https://github.com/curl/curl/blob/master/docs/cmdline-opts/doh-url.md):
  `--resolve` can provide the DoH server's bootstrap address.
- [RFC 1035](https://www.rfc-editor.org/rfc/rfc1035), section 4.1.1: a DNS response
  has query identity, response flags and an error/status code as well as answers.
- [Git HTTP configuration](https://git-scm.com/docs/git-config#Documentation/git-config.txt-httpcurloptResolve):
  `http.curloptResolve` supplies host/port address overrides to libcurl.
- [GitHub IP addresses](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/about-githubs-ip-addresses):
  addresses can change; a historical address is not a current lookup result.
- [Dune external-library lookup](https://dune.readthedocs.io/en/stable/usage.html#finding-external-libraries):
  installed-library lookup applies when the library is unavailable in the workspace.

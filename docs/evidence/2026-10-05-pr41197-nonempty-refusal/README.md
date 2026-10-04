# Sampling nonempty-refusal boundary (#41197)

Original head650879ef1e87c00fcf56a1b11f4b50e7f8fa2d87 admitted two reply
bytes. The final-spec manifest and actual broker tests reproduced both failures:
the manifest accepted that undersized budget, and the actual out-of-observation
handler returned Error with an empty string. Both raw individual failures and
source/binary hashes are retained. No provider was invoked.

The published parent2e34863666dde7dd334adb47dee397b81358f928 was then merged
cleanly. Lane_addon_types now owns the existing fixed fallback text `refused`
and derives its minimum from actual JSON string encoding. Manifest and direct
broker admission use that same bound; the private refusal formatter returns the
complete fixed fallback instead of truncating it. Model-disabled one-byte
admission is unchanged. Tests cover every nonnegative budget below the derived
minimum and the exact admitted boundary, real handler output, encoded length,
and zero provider calls. The earlier oversized-request test retains its
no-invocation assertion with a now-valid minimum budget.

Focused wrapper build and the entire Lane Add-on worker executable passed;
checks.json records the exact test count and hashes. The declared test/dune
environment isolates execution from live workspace/provider settings. Final
fragment/evidence additions are documentation only. No full build/suite,
provider call, browser, TUI, hosted CI or deployed-runtime proof is claimed.

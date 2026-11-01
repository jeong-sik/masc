# Pure catalog profile dependency repair

Source PR [#47361](https://github.com/jeong-sik/masc/pull/47361) moves immutable
capability data/presets out of model-policy lookup and puts default wire paths
in the closed Provider_kind. Policy and parsing values are preserved. The two
derived debug printers follow the new profile module prefix; exact diagnostic
strings are outside this preservation claim.

Actual workflow **Test** [41323090017](https://github.com/jeong-sik/masc/actions/runs/41323090017), checkout
`d6ce437549da7cbe303922879b2468c65820fbfd`, ref `refactor/catalog-pure-profiles-20261102`, explicit
`minimal=true`, existing 600-second targeted-suite guard: **SUCCESS,
461 PASS / 0 FAIL**. Capability 124, JSON provider catalog 17, provider config
142, runtime config 178. Six default wire paths and the explicit override case
are registered/executed request_path cases; internal assertions are not extra
cases. This is one focused execution with no before/after counterpart.

`source-sha256.json` binds 38 named inputs and four complete trees at that
actual source. The evidence parent has those same inputs/trees. Evidence-only
commits preserve them; their later heads are not newly executed. The unpublished
Catalog_snapshot work is excluded. `movement.json` preserves the initial b468
extraction facts and separates d6's later comment/document changes. Original
block hashes are never relabeled as the later changed bytes.

`candidate.txt` is an ANSI/BOM-normalized line-selected derivative preserving
all checkout, target, case and summary lines. Raw and retained byte digests are
distinct. Raw capture metadata paths are repository-relative in this derivative.
Case identity is source/group/index/fixture-SHA; display names may be ellipsized.
Compact UTF-8 JSON of those keys plus one LF hashes to `cb51a43a423a033e4f0d9c4fd56b3f1850317c6e24366cb1e560f3ef836c541b`.

No local build/typecheck ran. Source review, actual focused execution, formal
non-author GitHub approval and merge are separate. The existing two global
catalog sources remain; atomic publication, strict missing-field parsing and
the rest of #27898's hard cut are still open. Full regression, installed runtime,
real provider/account, OS restart and whole-stack integration are unverified.

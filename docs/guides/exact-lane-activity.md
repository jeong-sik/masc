# Exact Lane activity

Each `[runtime.exact_output_lanes.<id>]` table accepts `enabled`. Omitting the
key means `true`. Set it to `false` to refuse new implicit work while retaining
`slots`, `cli_slots`, their order, `thinking` and `max_output_tokens`.

```toml
[runtime.exact_output_lanes.librarian_exact]
enabled = false
slots = ["provider.model"]
cli_slots = ["official.client"]
```

The IDs above are examples; keep the candidates already declared for your
deployment. An optional lane may be off with empty candidate lists. Enabling it
requires at least one candidate and the usual admission checks. Malformed or
duplicate candidates remain configuration errors even when off.

The existing Required lanes, Board Attention and HITL auto-judge, cannot be
disabled. Loading or saving such a declaration is refused. Librarian, Workspace
Curator, Verifier, Browser Stagehand Exact and Candle Appraiser are Optional.
Stagehand Exact activity controls its model requests; Browser executor/session
activity is a separate owner.

Save through the existing runtime TOML editor. Its revision check, validation
and commit receipt still apply. A saved file alone does not establish that the
registry was replaced: read the application receipt. Activity is published in
the same immutable registry as the lane's candidates. An off acquisition returns
`Exact_lane_off`; already acquired snapshots remain usable. A Required lane
cannot be disabled through a publication exception or replacement transaction.

Librarian acquires its candidates before JEV preflight. Off prevents both a new
JEV judgment and a new full generation; the pending range remains unconsumed.
A pass already in JEV retains its acquired candidates for generation fallback
and can finish normally. Verifier refuses new implicit reviews, while an accepted
review retains its declared CLI execution constraint. An explicit single-runtime
evaluator override remains independent of the Verifier lane's activity. The
acquired Verifier candidate kind survives a publication fence and later
declaration changes. This does not freeze a removed or reconfigured runtime
binding for execution.

TUI and Web observations show `off` separately from unavailable/unconfigured.
Declared candidates and retained run evidence remain visible, including accepted
work still finishing. `running_count` describes retained observation coverage,
not an atomic census of all processes. Browser Stagehand has no standalone run
history. The inventory read never starts or stops work.

The TUI and Web provide the activity drafts described below. Publishing an
enabled Workspace Curator declaration wakes its parked owner to reconsider
retained facts without another memory commit or manual request. First registry
publication does the same. Work deferred while a configuration replacement
fenced registry access is reconsidered when that fence closes, including a
failed write that leaves the previous registry serving. The owner rereads
current admission, so a failed attempt to enable an off lane cannot run it.
This wake does not establish that model execution or curation succeeded; the
Exact run reading records that outcome.

## Upgrade notes

Prompt presets capture and restore lane activity with their candidate lists;
the autosave records the activity before restoration. Saved preset lane entries
require a Boolean `enabled`. Presets lacking that field are refused explicitly;
recapture the desired state rather than assigning a default to an old snapshot.

Existing declarations with no `enabled` keep their behavior. Install a binary
that accepts the key before adding it to a live configuration. This change does
not require new tables/keys in every deployment or edit operator configuration.

Native backend and TUI execution evidence is separate from parser, isolated
decoder/display and synthetic Web evidence in the corresponding evidence folders.

## TUI activity draft

In **Lanes**, select an Exact row and press **Space**. Opening the activity
screen reads `runtime.toml`; it does not change the file. The existing **s**
model-order editor and **a** candidate picker remain available on the list.

Inside **Exact activity**:

- **Space** changes the on/off draft. Candidates and their order are retained.
- **s** previews and saves using the original source revision. Required lanes
  cannot be switched off; an empty lane needs a candidate before enabling it.
- **r** reads the current file, preserving unsaved activity changes. With no
  unsaved change and the same file path, the draft follows the current setting
  and revision. Reopening the activity screen uses the same rule.
- After a concurrent edit, **u** reapplies only the desired activity to that
  current file; **s** then saves. Other current settings are preserved.
- **x** discards the draft. **Esc** or **q** closes the screen while retaining
  the draft for this workspace and lane. **?** explains the controls.
- **j/k**, arrows, **PgUp/PgDn** and **Home/End** scroll the reading.

Drafts survive navigation and workspace roundtrips within the TUI process.
Reconnecting requires a fresh read; a callback from an earlier workspace
request cannot complete the new request. An uncertain save retains the draft
and requires a current-file read before retrying. TUI process restart recovery
is not provided.

The screen distinguishes the current file setting from the write receipt's
live-application result. A saved file may still report that Exact configuration
was kept or could not be published. It rereads both the file and Lane inventory
after a save; this is not proof that a model or parked Curator has run.

Activity editing handles a lane's own TOML table, including quoted headers.
Inline or dotted lane declarations can be changed with the existing source
editor (**e** on Lanes). If the server changes the configuration path, discard
the old activity draft before editing the newly read file.

## Web activity draft

Open an Exact row under **All Lanes**, then choose **활동 설정 열기**. The same
control is available in **Runtime → Lane 후보**. Opening reads the current
file; the activity switch edits a local draft. **활동 설정 저장** previews the
result and saves only after checking the source revision on which it was based.

The activity draft is separate from a raw runtime.toml editor draft. Saving
activity retains that raw draft and withdraws its old save basis; compare the
current file before saving the raw text. Both drafts survive navigation and
workspace roundtrips within the page session. Reloading the browser page is not
a draft recovery mechanism.

**현재 설정 읽기** preserves unsaved activity changes. If no activity change
is pending, it follows the newly read file. After a conflict, **활동 값만 다시
적용** keeps the desired on/off value over the latest file and its candidate
order; a subsequent explicit save commits it. **초안 버리기** discards the
activity draft without writing. A changed file path requires an explicit discard.
Quoted, dotted and inline TOML lane declarations are edited by parsed ranges.

Required lanes cannot be switched off; a Required lane already declared off in
an invalid file can be corrected to on. An optional empty lane needs a candidate
before on can be saved. The screen separately shows the file setting, observed
Lane state and the commit's durability/application result. A kept registry or
failed setup resume is not reported as successful Lane activation. Saving
rereads the file and observations after setup resume completes, including when
the operator navigated away and returned during that resume. An open activity
panel and its receipt survive these observation refreshes. This does not prove
a model has executed.

A manual setup retry in Runtime settings refreshes Lane observations after the
attempt completes. A verified Activity file receipt also refreshes mounted
Settings snapshots even when setup resume fails; this refresh does not claim
that live application succeeded or replace an independent raw TOML draft.

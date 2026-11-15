"""Mutants of the subscriptions panel of the account console (#51797) and
the runner that tries each one against the console's vitest suite.

usage: python3 -I mutants.py DASHBOARD_COPY OUT_TSV

DASHBOARD_COPY is a copy of dashboard/ at the head under test, with
node_modules linked into it and the repository's test/ linked next to it
(src/api/composition-observation-native.test.ts reads ../../../test/fixtures).
Each mutant replaces one text, found exactly once, in one file of the copy.
A mutant no test catches is then type-checked, so a survivor that tsc
refuses is told apart from one nothing refuses. Every file is restored
after each mutant and at the end."""
import json, pathlib, subprocess, sys

# name: (file in the copy, text found once, its replacement)
MUTANTS = {
    'm01-acted-on-first': ('src/accounts/subscriptions.ts',
        "const actedOn = (first: Problem, second: Problem): Problem => (second.kind === 'signed_out' ? second : first)",
        'const actedOn = (first: Problem, _second: Problem): Problem => first'),
    'm02-acted-on-second': ('src/accounts/subscriptions.ts',
        "const actedOn = (first: Problem, second: Problem): Problem => (second.kind === 'signed_out' ? second : first)",
        'const actedOn = (_first: Problem, second: Problem): Problem => second'),
    'm05-reads-again-for-same-person': ('src/accounts/subscriptions.ts',
        "    if (now.kind !== 'waiting' && now.forUser === userId) return Promise.resolve()\n",
        '    void now\n'),
    'm06-retry-while-retrying': ('src/accounts/subscriptions.ts',
        "    if (now.kind !== 'failed' || now.next !== 'idle') return Promise.resolve()\n",
        "    if (now.kind !== 'failed') return Promise.resolve()\n"),
    'm07b-slow-at-once': ('src/accounts/subscriptions.ts',
        '    }, slowAfterMs)\n',
        '    }, slowAfterMs * 0)\n'),
    'm08-follow-does-not-track': ('src/accounts/subscriptions.ts',
        '    const now = frame.value\n',
        '    const now = frame.peek()\n'),
    'm09-read-state-alert': ('src/accounts/subscriptions.ts',
        '        <${Read} integrations=${view.integrations} owned=${view.owned} />\n        <p class="hint" role="status"></p>',
        '        <${Read} integrations=${view.integrations} owned=${view.owned} />\n        <p class="hint" role="alert"></p>'),
    'm10-attempts-reset': ('src/accounts/subscriptions.ts',
        'attempts: attemptsBefore + 1 }',
        'attempts: 1 }'),
    'm11-no-leave': ('src/accounts/subscriptions.ts',
        '      leave()\n',
        ''),
    'm12-checked-any-runtime': ('src/accounts/subscriptions.ts',
        '  const checked = runtimes.some((runtime) => runtime.model.read)\n',
        '  const checked = runtimes.length > 0\n'),
    'm15-fact-value-and-unread': ('src/accounts/wire.ts',
        '  if (value !== null) return json.unread === undefined ? { read: true, value } : null\n',
        '  if (value !== null) return { read: true, value }\n'),
    'm16-fact-missing-field': ('src/accounts/wire.ts',
        '  return json[name] === null && code !== null ? { read: false, unread: readUnread(code) } : null\n',
        '  return code !== null ? { read: false, unread: readUnread(code) } : null\n'),
    'm17-accounts-old-shape': ('src/accounts/wire.ts',
        'function readAccount(json: unknown): ProviderAccount | null {\n  if (!isRecord(json)) return null\n',
        "function readAccount(json: unknown): ProviderAccount | null {\n  if (typeof json === 'string') return { id: json, integration: { read: false, unread: 'unrecognised' } }\n  if (!isRecord(json)) return null\n"),
    'm18-runtimes-optional': ('src/accounts/wire.ts',
        '  const runtimes = readList(json.runtimes, readRuntime)\n',
        '  const runtimes = json.runtimes === undefined ? [] : readList(json.runtimes, readRuntime)\n'),
    'm19-refused-without-code': ('src/accounts/wire.ts',
        "      return code === null ? null : { kind: 'refused', refusal: readCallRefusal(code) }\n",
        "      return { kind: 'refused', refusal: code === null ? 'unrecognised' : readCallRefusal(code) }\n"),
    'm20-unknown-refusal-known': ('src/accounts/wire.ts',
        "    case 'person_homes_unread':\n      return code\n    default: return 'unrecognised'\n",
        "    case 'person_homes_unread':\n      return code\n    default: return 'native_unpublished'\n"),
    'm21-unknown-model-unread-known': ('src/accounts/wire.ts',
        "    case 'runtime_not_bound':\n      return code\n    default: return 'unrecognised'\n",
        "    case 'runtime_not_bound':\n      return code\n    default: return 'runtime_not_bound'\n"),
    'm22-unknown-integration-unread-known': ('src/accounts/wire.ts',
        "    case 'login_receipt_unreadable':\n      return code\n    default: return 'unrecognised'\n",
        "    case 'login_receipt_unreadable':\n      return code\n    default: return 'login_receipt_missing'\n"),
    'n02-runtimes-not-filtered': ('src/accounts/subscriptions.ts',
        '    const runtimes = owned.runtimes.filter((runtime) => runtime.accountId === account.id)\n',
        '    const runtimes = owned.runtimes\n'),
    'n03-offered-ignores-id': ('src/accounts/subscriptions.ts',
        'integrations.find((one) => one.id === integration.value) ?? null : null\n',
        'integrations[0] ?? null : null\n'),
    'n04-offered-for-unknown-account': ('src/accounts/subscriptions.ts',
        'integrations.find((one) => one.id === integration.value) ?? null : null\n',
        'integrations.find((one) => one.id === integration.value) ?? null : integrations[0] ?? null\n'),
    'n05-accounts-reordered': ('src/accounts/subscriptions.ts',
        '  return owned.accounts.map((account) => {\n',
        '  return [...owned.accounts].reverse().map((account) => {\n'),
    'n06b-chip-says-runs-always': ('src/accounts/subscriptions.ts',
        '      ${keeper.kind === \'can_run\' ? html`<span class="chip">Keeper 실행 가능</span>` : null}\n',
        '      ${keeper.kind !== \'refused\' ? html`<span class="chip">Keeper 실행 가능</span>` : null}\n'),
    'n07b-chip-says-checked-always': ('src/accounts/subscriptions.ts',
        "      <span class=${checked ? 'chip' : 'chip chip-todo'}>${checked ? '모델 확인됨' : '모델 확인 필요'}</span>\n",
        "      <span class=${checked === checked ? 'chip' : 'chip chip-todo'}>${checked === checked ? '모델 확인됨' : '모델 확인 필요'}</span>\n"),
    'p01-older-reading-writes': ('src/accounts/subscriptions.ts',
        '    if (mine !== latest) return\n',
        ''),
    'p02-stale-timer-marks-slow': ('src/accounts/subscriptions.ts',
        "      if (mine === latest && now.kind === 'reading') view.value = { ...now, slow: true }\n",
        "      if (now.kind === 'reading') view.value = { ...now, slow: true }\n"),
    'p03-retry-drops-its-page': ('src/accounts/subscriptions.ts',
        "      view.value = now.kind === 'failed' ? { ...now, next: 'leaving' } : { kind: 'leaving', forUser }\n",
        "      view.value = { kind: 'leaving', forUser }; void now\n"),
    'p04-keeper-ignores-model': ('src/accounts/subscriptions.ts',
        "  return checked ? { kind: 'can_run' } : { kind: 'needs_model' }\n",
        "  return checked || !checked ? { kind: 'can_run' } : { kind: 'needs_model' }\n"),
    'p05-keeper-ignores-refusal': ('src/accounts/subscriptions.ts',
        "  if (offered.calls.kind === 'refused') return { kind: 'refused', refusal: offered.calls.refusal }\n",
        ''),
    'p06-runnable-all': ('src/accounts/subscriptions.ts',
        "  integrations.filter((one) => one.calls.kind === 'allowed')\n",
        "  integrations.filter((one) => one.calls.kind === 'allowed' || one.calls.kind === 'refused')\n"),
    'p07-no-heading-focus': ('src/accounts/subscriptions.ts',
        'heading.current?.focus()',
        'void heading.current'),
    'p08-focus-taken-from-elsewhere': ('src/accounts/subscriptions.ts',
        "    if (shown.current === 'failed' && view.kind === 'read' && fell) heading.current?.focus()\n",
        "    if (shown.current === 'failed' && view.kind === 'read' && (fell || !fell)) heading.current?.focus()\n"),
    'p09-focus-on-first-read': ('src/accounts/subscriptions.ts',
        "    if (shown.current === 'failed' && view.kind === 'read' && fell) heading.current?.focus()\n",
        "    if (view.kind === 'read' && fell) heading.current?.focus()\n"),
    'p10-owned-on-unlisted-account': ('src/accounts/wire.ts',
        '  return runtimes.every((runtime) => listed.has(runtime.accountId)) ? { accounts, runtimes } : null\n',
        '  return runtimes.every((runtime) => listed.has(runtime.accountId) || true) ? { accounts, runtimes } : null\n'),
    'p11-offer-names-every-subscription': ('src/accounts/subscriptions.ts',
        '  const names = runnable(integrations).map(integrationName)\n',
        '  const names = integrations.map(integrationName)\n'),
}

# Mutants of the earlier runs left out, and why.
LEFT_OUT = {
    'm03-keeps-answer-for-other-person': 'its check gave way to the reading number; p01 removes that',
    'm04-no-join-in-flight': 'the code it changed was removed after run 1',
    'm07-slow-at-once': 'm07b replaces it and keeps the import in use',
    'm13-calls-always-allowed': 'the row code it changed moved into accountFacts; n03 and p05 change that',
    'm14-runtimes-not-filtered': 'the row code it changed moved into accountFacts; n02 changes that',
    'n01-checked-any-runtime': "its text is m12's now",
    'n06-chip-says-runs-always': 'rewritten as n06b for the chips that read `keeper`',
    'n07-chip-says-checked-always': 'rewritten as n07b, with `checked` still read',
}

copy = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(sys.argv[2])
report = copy / ".mutant-report.json"
RUN = ["npx", "vitest", "run", "--config", "vitest.config.ts", "src/accounts",
       "--reporter=json", f"--outputFile={report}"]
TSC = ["npx", "tsc", "--noEmit", "-p", "."]
RUN_TIMEOUT_S = 300


def caught_by() -> list[str]:
    """The tests that failed, or the files that did not load."""
    if not report.exists():
        return ["no report written"]
    data = json.loads(report.read_text(encoding="utf-8"))
    failed = []
    for result in data.get("testResults", []):
        names = [a["fullName"] for a in result.get("assertionResults", []) if a.get("status") == "failed"]
        if names:
            failed.extend(names)
        elif result.get("status") == "failed":
            failed.append(f"{pathlib.Path(result.get('name', '?')).name} did not load")
    return failed


def run_tests() -> list[str]:
    report.unlink(missing_ok=True)
    try:
        subprocess.run(RUN, cwd=copy, capture_output=True, text=True, timeout=RUN_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return ["timed out"]
    return caught_by()


def type_error() -> str | None:
    ran = subprocess.run(TSC, cwd=copy, capture_output=True, text=True)
    if ran.returncode == 0:
        return None
    lines = [line for line in ran.stdout.splitlines() if "error TS" in line]
    return lines[0][:160] if lines else "tsc failed"


originals: dict[str, str] = {}
rows = []
try:
    baseline = run_tests()
    rows.append(("baseline", "all pass" if not baseline else "FAILS", "; ".join(baseline[:3])))
    for name, (rel, old, new) in MUTANTS.items():
        original = originals.setdefault(rel, (copy / rel).read_text(encoding="utf-8"))
        if original.count(old) != 1:
            rows.append((name, "old text not found once", ""))
            continue
        (copy / rel).write_text(original.replace(old, new, 1), encoding="utf-8")
        failed = run_tests()
        if failed:
            rows.append((name, "caught", f"{len(failed)}: " + "; ".join(failed[:2])))
        else:
            refused = type_error()
            rows.append((name, "NOT CAUGHT" if refused is None else "type error only", refused or ""))
        (copy / rel).write_text(original, encoding="utf-8")
finally:
    for rel, original in originals.items():
        (copy / rel).write_text(original, encoding="utf-8")
    report.unlink(missing_ok=True)
out.write_text("".join("\t".join(row) + "\n" for row in rows), encoding="utf-8")
for row in rows:
    print(" | ".join(row))

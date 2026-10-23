"""Counts how Keepers wait on a browser page: repeated reads of one tab and shell sleeps between browser calls.

usage: wait_census.py <keepers dir> <since YYYY-MM-DD>
Reads only tool_execution_started records of raw-traces files modified since the date.
"""
import json, os, re, sys, collections, datetime

root, since = sys.argv[1], sys.argv[2]
cutoff = datetime.datetime.fromisoformat(since).timestamp()
BROWSER = re.compile(r"^(Browser(Read|Tabs|Interact|Act|Goto|Session|Instruct)|masc_browser_\w+)$")
READS = {"BrowserRead", "masc_browser_read", "BrowserTabs", "masc_browser_tabs"}
SLEEP = re.compile(r"(^|[;&|\s])sleep\s+\d")

calls = collections.defaultdict(list)  # keeper -> [(ts, tool, input)]
for keeper in os.listdir(root):
    d = os.path.join(root, keeper, "raw-traces")
    if not os.path.isdir(d):
        continue
    for name in os.listdir(d):
        path = os.path.join(d, name)
        if os.path.getmtime(path) < cutoff:
            continue
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"tool_execution_started"' not in line:
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                tool = r.get("tool_name") or ""
                inp = r.get("tool_input") if isinstance(r.get("tool_input"), dict) else {}
                ts = r.get("ts")
                if isinstance(ts, (int, float)) and ts >= cutoff:
                    calls[keeper].append((ts, tool, inp))

browser_total = reads_total = 0
runs = collections.Counter()      # length of same-tab read runs (>= 2)
extra_reads = 0
sleeps = 0
sleep_examples = []
run_examples = []
per_keeper = collections.Counter()
for keeper, items in calls.items():
    items.sort(key=lambda x: x[0])
    last_browser = None
    run = []
    pending_sleep = None
    for ts, tool, inp in items:
        if BROWSER.match(tool):
            browser_total += 1
            if tool in READS:
                reads_total += 1
            tab = inp.get("tabId")
            mode = inp.get("mode")
            is_read = tool in READS
            if pending_sleep is not None and last_browser is not None:
                sleeps += 1
                if len(sleep_examples) < 6:
                    sleep_examples.append((keeper, last_browser[1], pending_sleep[:80], tool))
            pending_sleep = None
            if is_read and run and run[-1][2] == tab and run[-1][3] == mode and ts - run[-1][0] <= 60:
                run.append((ts, tool, tab, mode))
            else:
                if len(run) >= 2:
                    runs[min(len(run), 6)] += 1
                    extra_reads += len(run) - 1
                    per_keeper[keeper] += len(run) - 1
                    if len(run_examples) < 6:
                        run_examples.append((keeper, run[0][1], run[0][2], run[0][3], len(run), round(run[-1][0] - run[0][0], 1)))
                run = [(ts, tool, tab, mode)] if is_read else []
            last_browser = (ts, tool)
        else:
            command = inp.get("command") if isinstance(inp.get("command"), str) else ""
            if last_browser is not None and SLEEP.search(command):
                pending_sleep = command
    if len(run) >= 2:
        runs[min(len(run), 6)] += 1
        extra_reads += len(run) - 1
        per_keeper[keeper] += len(run) - 1

print(f"since {since}: keepers with browser calls {sum(1 for v in calls.values() if any(BROWSER.match(t) for _, t, _ in v))}")
print(f"browser calls {browser_total}, reads {reads_total}")
print(f"same-tab same-mode read runs within 60 s: {sum(runs.values())} (by length, 6 means 6+: {dict(sorted(runs.items()))}), extra reads {extra_reads}")
print(f"shell sleeps between two browser calls: {sleeps}")
for e in run_examples: print("run", e)
for e in sleep_examples: print("sleep", e)
print("extra reads by keeper", per_keeper.most_common(6))

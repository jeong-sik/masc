#!/usr/bin/env python3
"""위임 대상 Keeper의 큐가 비어 있었는지 저장된 기록으로 다시 계산한다.

위임(masc_keeper_delegate)마다 같은 순간에 후보 Keeper 각각에 작업을 넣었다면 몇 초 기다렸을지
Keeper별 chat-operations.sqlite3 의 시간 기록만으로 계산한다. 읽기 전용이고, 서버를 부르지 않는다.

계산 규칙
- 큐는 선입선출이고 한 번에 한 작업만 돈다. 시각 t 에 만든 작업은 t 이전에 만든 작업 중
  실제로 시작한 것이 모두 끝난 뒤에 시작한다. 시작하지 않고 취소된 작업은 Keeper를 쓰지 않았으므로 뺀다.
- 위임을 받은 Keeper에도 같은 계산을 해서 저장된 실제 대기(started_at - created_at)와 견준다.
  이 차이가 작을수록 계산이 기록과 맞는다.
- 후보는 --family 로 주거나, 주지 않으면 창 안에서 보낸 사람이 한 번이라도 위임한 Keeper 전부다.

한계
- 위로 잡은 값이다. 대기가 짧은 후보를 보낸 사람이 알았다고 가정하고, 그 선택이 후보의 다른 작업을
  늦추는 일은 세지 않는다.
- 저장소에는 채팅 작업만 있다. 자기 틱 같은 다른 턴 때문에 후보가 바빴어도 기록에는 없다.
- 아직 끝나지 않은 작업은 기록에 완료 시각이 없어 건너뛴다.

--ledger 를 주면 배포 뒤 사용을 같이 센다. tool_calls 장부에서 masc_keeper_delegate_targets 를 먼저 부르고
같은 턴 안에서 위임한 경우와 그러지 않은 경우의 대기를 나란히 보인다. 인과 추정이 아니라 두 집단의 서술이다.
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import sqlite3
import sys
from dataclasses import dataclass
from pathlib import Path

LONG_WAIT_S = 60.0
VERY_LONG_WAIT_S = 600.0
FREE_NOW_S = 1.0
MODEL_TOLERANCE_S = 5.0
TARGETS_TOOL = "masc_keeper_delegate_targets"
DELEGATE_TOOL = "masc_keeper_delegate"
SECONDS_PER_HOUR = 3600.0
LONG_WAIT_HEAD_CHARS = 110


@dataclass(frozen=True, slots=True)
class Op:
    operation_id: str
    keeper: str
    created: float
    started: float | None
    completed: float | None
    sender: str | None


def parse_time(text: str) -> float:
    return dt.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def keeper_dbs(base: Path) -> dict[str, Path]:
    root = base / ".masc" / "keepers"
    return {p.parent.name: p for p in sorted(root.glob("*/chat-operations.sqlite3"))}


def load_ops(dbs: dict[str, Path], since: float, until: float) -> dict[str, list[Op]]:
    ops: dict[str, list[Op]] = {}
    for keeper, path in dbs.items():
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        if con.execute("select 1 from sqlite_master where name = 'operations'").fetchone() is None:
            con.close()
            continue
        rows = con.execute(
            "select operation_id, created_at, started_at, completed_at, source_json"
            " from operations where created_at >= ? and created_at < ? order by created_at",
            (since, until),
        ).fetchall()
        con.close()
        loaded = []
        for op_id, created, started, completed, source in rows:
            parsed = json.loads(source) if source else {}
            sender = parsed.get("sender_keeper") if isinstance(parsed, dict) else None
            loaded.append(Op(op_id, keeper, created, started, completed, sender))
        ops[keeper] = loaded
    return ops


def hypothetical_wait(keeper_ops: list[Op], t: float, skip: str) -> float:
    free = t
    for op in keeper_ops:
        if op.created > t or op.operation_id == skip:
            continue
        if op.started is None or op.completed is None:
            continue
        free = max(free, op.completed)
    return free - t


def quantile(sorted_values: list[float], q: float) -> float:
    return sorted_values[min(len(sorted_values) - 1, int(len(sorted_values) * q))]


def summarize(values: list[float]) -> dict[str, float | int]:
    ordered = sorted(values)
    return {
        "n": len(ordered),
        "sum_hours": round(sum(ordered) / SECONDS_PER_HOUR, 3),
        "p50_s": round(quantile(ordered, 0.5), 1),
        "p90_s": round(quantile(ordered, 0.9), 1),
        "max_s": round(ordered[-1], 1),
        "at_least_60s": sum(1 for v in ordered if v >= LONG_WAIT_S),
        "at_least_600s": sum(1 for v in ordered if v >= VERY_LONG_WAIT_S),
    }


def counterfactual(ops: dict[str, list[Op]], sender: str, family: list[str], since: float) -> dict[str, object]:
    """결정은 since 이후 위임만 세고, 큐 계산에는 불러온 작업을 모두 쓴다."""
    decisions = [
        op
        for keeper in family
        for op in ops.get(keeper, [])
        if op.sender == sender and op.created >= since and op.started is not None and op.completed is not None
    ]
    if not decisions:
        return {"delegations": 0}
    actual: list[float] = []
    best: list[float] = []
    model_error: list[float] = []
    long_count = long_free_count = 0
    long_total = long_free_total = 0.0
    long_rows: list[dict[str, object]] = []
    for op in decisions:
        assert op.started is not None
        wait = op.started - op.created
        alternatives = {k: hypothetical_wait(ops.get(k, []), op.created, op.operation_id) for k in family}
        best_wait = min(alternatives.values())
        actual.append(wait)
        best.append(best_wait)
        model_error.append(abs(alternatives[op.keeper] - wait))
        if wait >= LONG_WAIT_S:
            long_count += 1
            long_total += wait
            free = sorted(k for k, w in alternatives.items() if k != op.keeper and w < FREE_NOW_S)
            if free:
                long_free_count += 1
                long_free_total += wait
            long_rows.append(
                {"operation_id": op.operation_id, "created": op.created, "target": op.keeper, "wait_s": round(wait), "free": free}
            )
    errors = sorted(model_error)
    return {
        "delegations": len(decisions),
        "picks": dict(collections.Counter(op.keeper for op in decisions).most_common()),
        "actual_wait": summarize(actual),
        "best_of_family_wait": summarize(best),
        "long_waits": {
            "count": long_count,
            "hours": round(long_total / SECONDS_PER_HOUR, 3),
            "count_with_free_alternative": long_free_count,
            "hours_with_free_alternative": round(long_free_total / SECONDS_PER_HOUR, 3),
        },
        "long_wait_rows": sorted(long_rows, key=lambda r: float(r["created"])),  # type: ignore[arg-type]
        "model_check_on_actual_target": {
            "p50_abs_error_s": round(quantile(errors, 0.5), 1),
            "p90_abs_error_s": round(quantile(errors, 0.9), 1),
            "within_5s": sum(1 for e in errors if e <= MODEL_TOLERANCE_S),
            "of": len(errors),
        },
    }


def ledger_files(base: Path, since: float, until: float) -> list[Path]:
    start = dt.datetime.fromtimestamp(since, dt.timezone.utc)
    end = dt.datetime.fromtimestamp(until, dt.timezone.utc)
    months = sorted({(start.year, start.month), (end.year, end.month)})
    files: list[Path] = []
    for year, month in months:
        files += sorted((base / ".masc" / "tool_calls" / f"{year:04d}-{month:02d}").glob("*.jsonl"))
    return files


def turn_id(row: dict[str, object]) -> object:
    contract = row.get("runtime_contract")
    if isinstance(contract, dict) and "keeper_turn_id" in contract:
        return contract["keeper_turn_id"]
    return row.get("keeper_turn_id")


def operation_id_of(row: dict[str, object]) -> str | None:
    try:
        parsed = json.loads(str(row.get("output") or ""))
    except json.JSONDecodeError:
        return None
    return parsed.get("operation_id") if isinstance(parsed, dict) else None


def delegate_prompts(base: Path, sender: str, since: float, until: float) -> dict[str, str]:
    prompts: dict[str, str] = {}
    for path in ledger_files(base, since, until):
        with path.open() as handle:
            for line in handle:
                if DELEGATE_TOOL not in line:
                    continue
                row = json.loads(line)
                if row.get("tool") != DELEGATE_TOOL or row.get("keeper") != sender:
                    continue
                op_id = operation_id_of(row)
                given = row.get("input")
                if op_id and isinstance(given, dict):
                    prompts[op_id] = str(given.get("prompt", ""))
    return prompts


def print_long_waits(rows: list[dict[str, object]], prompts: dict[str, str]) -> None:
    """읽는 사람이 이름표를 붙일 수 있게 표로 보인다. 프롬프트 본문은 JSON 에 넣지 않는다."""
    for row in rows:
        when = dt.datetime.fromtimestamp(float(row["created"]), dt.timezone.utc).strftime("%d %H:%M")  # type: ignore[arg-type]
        head = " ".join(prompts.get(str(row["operation_id"]), "").split())[:LONG_WAIT_HEAD_CHARS]
        free = ",".join(str(k) for k in row["free"]) or "-"  # type: ignore[union-attr]
        print(f"{when}Z {row['target']} wait {row['wait_s']}s free {free} | {head}", file=sys.stderr)


def ledger_usage(base: Path, ops: dict[str, list[Op]], sender: str, since: float, until: float) -> dict[str, object]:
    waits = {op.operation_id: op.started - op.created for v in ops.values() for op in v if op.started is not None}
    reads: dict[object, float] = {}
    delegates: list[tuple[float, object, str]] = []
    for path in ledger_files(base, since, until):
        with path.open() as handle:
            for line in handle:
                if TARGETS_TOOL not in line and DELEGATE_TOOL not in line:
                    continue
                row = json.loads(line)
                if row.get("keeper") != sender or not since <= row.get("ts", 0.0) < until:
                    continue
                if row.get("tool") == TARGETS_TOOL:
                    reads.setdefault(turn_id(row), row["ts"])
                elif row.get("tool") == DELEGATE_TOOL:
                    op_id = operation_id_of(row)
                    if op_id:
                        delegates.append((row["ts"], turn_id(row), op_id))
    informed: list[float] = []
    uninformed: list[float] = []
    for ts, turn, op_id in delegates:
        if op_id not in waits:
            continue
        read_at = reads.get(turn)
        (informed if read_at is not None and read_at <= ts else uninformed).append(waits[op_id])
    return {
        "targets_reads": len(reads),
        "delegate_calls": len(delegates),
        "informed": summarize(informed) if informed else {"n": 0},
        "uninformed": summarize(uninformed) if uninformed else {"n": 0},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-path", type=Path, default=Path.home() / "me", help="workspace root that holds .masc")
    parser.add_argument("--since", required=True, help="UTC, e.g. 2026-11-08T00:00:00Z")
    parser.add_argument("--until", required=True, help="UTC, exclusive")
    parser.add_argument("--sender", help="delegating Keeper; default is the one with the most delegations")
    parser.add_argument("--family", help="comma separated candidate Keepers; default is every Keeper the sender delegated to")
    parser.add_argument("--lookback-hours", type=float, default=6.0, help="earlier operations that may still hold a queue at --since")
    parser.add_argument("--ledger", action="store_true", help="also count masc_keeper_delegate_targets reads from the tool_calls ledger")
    parser.add_argument("--long-waits", action="store_true", help="print each wait of 60 s or more with its prompt head to stderr")
    parser.add_argument("--out", type=Path, help="write the result as JSON")
    args = parser.parse_args()

    since, until = parse_time(args.since), parse_time(args.until)
    dbs = keeper_dbs(args.base_path)
    if not dbs:
        print(f"no chat-operations.sqlite3 under {args.base_path}/.masc/keepers", file=sys.stderr)
        return 2
    ops = load_ops(dbs, since - args.lookback_hours * SECONDS_PER_HOUR, until)

    pairs = collections.Counter(
        (op.sender, op.keeper)
        for v in ops.values()
        for op in v
        if op.sender and since <= op.created < until
    )
    by_sender: collections.Counter[str] = collections.Counter()
    for (who, _), count in pairs.items():
        by_sender[who] += count
    if not by_sender:
        print("no delegations in the window", file=sys.stderr)
        return 2
    sender = args.sender or by_sender.most_common(1)[0][0]
    family = [k for k in args.family.split(",") if k] if args.family else sorted({k for (who, k) in pairs if who == sender})

    result: dict[str, object] = {
        "since": args.since,
        "until": args.until,
        "sender": sender,
        "family": family,
        "delegations_by_sender": dict(by_sender.most_common()),
        **counterfactual(ops, sender, family, since),
    }
    if args.ledger:
        result["ledger"] = ledger_usage(args.base_path, ops, sender, since, until)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    print(text)
    if args.long_waits:
        print_long_waits(result.get("long_wait_rows", []), delegate_prompts(args.base_path, sender, since, until))  # type: ignore[arg-type]
    if args.out:
        args.out.write_text(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

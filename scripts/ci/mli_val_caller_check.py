#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mli_val_caller_check.py — 공개 시그니처(.mli val) 변경이 시험 호출부 전파를 빠뜨렸는지 경고한다.

배경: 2026-11-09 하루에 두 번(#50684→#50721 수리, #50718→#50739 수리) lib/*.mli 의
필수 레이블 인자 변경이 test 호출부 전파를 빠뜨려 main 의 `dune build @check`
(PR type-check)가 빨갛게 됐다. dune @check 는 첫 오류에서 멈추고, test .ml 만
두 ref 로 비교하면 .mli 에만 추가된 인자를 놓친다. 이 스크립트는 그 누락을
변경 시점에 기계적으로 경고한다. 경고이지 차단이 아니다(비게이팅).

이 저장소의 레이블 표기(실측):
  - .mli 타입식의 필수 레이블은 물결 없이 `name:string` 으로 쓴다(예: lib/keeper/
    keeper_tool_plan.mli `val export : name:string -> node_id:Node_id.t -> ...`).
    물결을 붙인 `~name:` 형태도 함께 인정한다.
  - 선택 인자는 `?name:float`.
  - record 필드는 콜론 앞에 공백이 있다(`name : type`) → 레이블로 세지 않는다.
    즉 필수 레이블 판정은 "이름 뒤에 콜론이 바로 붙거나(공백 없음) 물결이 앞에 있다".
  - .ml 호출부는 `~name:...` / `?name:...` 형태다.

사용법:
  # 두 ref 사이(워크트리 안에서, 정밀 모드 — 권장):
  python3 scripts/ci/mli_val_caller_check.py --base origin/main --head HEAD
  # diff 파일만 있을 때(호출부 스캔 트리는 --tree, 근사 모드):
  python3 scripts/ci/mli_val_caller_check.py --diff-file pr.diff --tree HEAD
  # 기계 판독용:
  python3 scripts/ci/mli_val_caller_check.py --base A --head B --json
  # 자기검증(합성 케이스 — #50718·#50684 회귀 포함, git 불필요):
  python3 scripts/ci/mli_val_caller_check.py --selftest

판정 규칙:
  - 대상: lib/**/*.mli 와 packages/*/lib/**/*.mli 의 val 블록(old/new 파일 전문 비교).
  - 전파 필요(kind): 필수 레이블 추가·삭제, 선택 인자 제거, 레이블은 같은데 본문이
    변한 경우(type_only), val 삭제(removed).
  - 전파 불필요(kind, 경고 안 함): 선택 인자 추가만(optional_only), 새 val 추가(added).
  - 전파 필요인 val 마다 test/**.ml · packages/*/test/**.ml 의 호출부를 찾는다.
    strong: `Module.name` 한정 호출, weak: 단독 name 뒤에 ~ ? ( 토큰.
  - 파일 단위 억제 규칙: 필수 레이블이 추가된 변경에서 호출부 파일에 이미
    `~새레이블`(호출부 스타일)이 보이면 갱신된 것으로 보고 경고하지 않는다.
    반대로 제거된 레이블 토큰이 아직 보이면 경고한다. 레이블 정보가 없는
    변경(type_only·removed)은 호출부가 보이면 경고한다.
  - 그 PR(diff)이 건드린 파일은 처음부터 검사 대상에서 뺀다(갱신 여부를 이미
    작성자가 알고 있다고 보는 자리다).
  - 경고에는 심볼명·.mli 좌표·변경 종류·미갱신 파일과 호출 줄 번호가 들어간다.
  - 항상 exit 0 (--strict 제외 — 프로브용).
"""

import argparse
import json
import re
import subprocess
import sys

VAL_RE = re.compile(r"^val\s+([a-zA-Z_][a-zA-Z0-9_']*)")
# .mli 필수 레이블 두 형태: 물결형(~name: / ~name :)과 베어형(name: — 콜론 앞 공백 없음).
LABEL_REQ_TILDE_RE = re.compile(r"~\s*([a-zA-Z_][a-zA-Z0-9_']*)\s*:")
LABEL_REQ_BARE_RE = re.compile(r"(?<![?~\w.'`])([a-zA-Z_][a-zA-Z0-9_']*):")
LABEL_OPT_RE = re.compile(r"\?\s*([a-zA-Z_][a-zA-Z0-9_']*)\s*:")
BLOCK_END_RE = re.compile(r"^(type\b|and\b|exception\b|module\b|include\b|let\b|@)")


def is_mli_target(path):
    """시그니처 감시 대상: lib/**/*.mli, packages/*/lib/**/*.mli"""
    p = path.replace("\\", "/")
    return p.endswith(".mli") and (
        p.startswith("lib/") or re.match(r"^packages/[^/]+/lib/", p) is not None
    )


def is_test_ml(path):
    """호출부 스캔 대상: test/**/*.ml, packages/*/test/**/*.ml"""
    p = path.replace("\\", "/")
    return p.endswith(".ml") and (
        p.startswith("test/") or re.match(r"^packages/[^/]+/test/", p) is not None
    )


def normalize_block(text):
    return re.sub(r"\s+", " ", text).strip()


def split_val_blocks(text):
    """파일 전문 -> {val이름: (시작줄(1based), 블록텍스트)}.
    블록은 val 줄부터 빈 줄 또는 다음 톱레벨 선언 직전까지."""
    blocks = {}
    lines = text.splitlines()
    cur = None  # [name, start, lines]

    def flush():
        if cur is not None:
            blocks[cur[0]] = (cur[1], "\n".join(cur[2]))

    for idx, line in enumerate(lines, 1):
        m = VAL_RE.match(line)
        if m:
            flush()
            cur = [m.group(1), idx, [line]]
            continue
        if cur is not None:
            if line.strip() == "" or BLOCK_END_RE.match(line):
                flush()
                cur = None
            else:
                cur[2].append(line)
    flush()
    return blocks


def label_sets(block_text):
    """(필수 레이블 집합, 선택 레이블 집합). 물결형+베어형을 합친다."""
    req = set(LABEL_REQ_TILDE_RE.findall(block_text))
    req |= set(LABEL_REQ_BARE_RE.findall(block_text))
    opt = set(LABEL_OPT_RE.findall(block_text))
    return req, opt


def classify_change(old_block, new_block):
    """항상 네 키를 갖춘 detail 을 돌려준다(고정 모양 — JSON 소비자 대비)."""
    oreq, oopt = label_sets(old_block)
    nreq, nopt = label_sets(new_block)
    detail = {
        "added_required": sorted(nreq - oreq),
        "removed_required": sorted(oreq - nreq),
        "added_optional": sorted(nopt - oopt),
        "removed_optional": sorted(oopt - nopt),
    }
    if detail["added_required"] or detail["removed_required"]:
        return "labels_changed", detail
    if detail["removed_optional"]:
        return "optional_removed", detail
    if detail["added_optional"]:
        return "optional_only", detail
    return "type_only", detail


def diff_val_blocks(old_text, new_text):
    """정밀 엔진: old/new 파일 전문에서 val 블록을 비교한다.
    -> [{name, kind, old_start, new_start, detail}]"""
    old_b = split_val_blocks(old_text)
    new_b = split_val_blocks(new_text)
    out = []
    for name in sorted(set(old_b) | set(new_b)):
        if name not in new_b:
            out.append({"name": name, "kind": "removed", "old_start": old_b[name][0],
                        "new_start": None, "detail": {}})
        elif name not in old_b:
            out.append({"name": name, "kind": "added", "old_start": None,
                        "new_start": new_b[name][0], "detail": {}})
        else:
            old_blk, new_blk = old_b[name][1], new_b[name][1]
            if normalize_block(old_blk) == normalize_block(new_blk):
                continue
            kind, detail = classify_change(old_blk, new_blk)
            out.append({"name": name, "kind": kind,
                        "old_start": old_b[name][0], "new_start": new_b[name][0],
                        "detail": detail})
    return out


def diff_file_val_changes(diff_text):
    """근사 엔진: unified diff 텍스트에서 .mli 의 val 추가/삭제와
    val 문맥 안의 레이블 +/- 를 추린다(--diff-file 모드용, best-effort)."""
    results = []
    cur_file = None
    last_val = None
    labels_plus = {}
    labels_minus = {}
    for line in diff_text.splitlines():
        if line.startswith("+++ b/"):
            cur_file = line[6:].strip()
            last_val = None
            continue
        if line.startswith("--- "):
            continue
        if cur_file is None or not is_mli_target(cur_file):
            continue
        body = line[1:] if line[:1] in "+-" else line
        m = VAL_RE.match(body)
        if m:
            last_val = m.group(1)
            key = (cur_file, last_val)
            labels_plus.setdefault(key, {"req": [], "opt": []})
            labels_minus.setdefault(key, {"req": [], "opt": []})
            if line.startswith("-"):
                results.append({"mli": cur_file, "symbol": last_val, "kind": "removed"})
            elif line.startswith("+"):
                results.append({"mli": cur_file, "symbol": last_val, "kind": "added"})
            continue
        if last_val is None:
            continue
        key = (cur_file, last_val)
        if line.startswith("+") or line.startswith("-"):
            req = set(LABEL_REQ_TILDE_RE.findall(body)) | set(LABEL_REQ_BARE_RE.findall(body))
            opt = set(LABEL_OPT_RE.findall(body))
            sink = labels_plus[key] if line.startswith("+") else labels_minus[key]
            sink["req"] = sorted(set(sink["req"]) | req)
            sink["opt"] = sorted(set(sink["opt"]) | opt)
    done = {(r["mli"], r["symbol"]) for r in results}
    for (path, name), plus in labels_plus.items():
        if (path, name) in done:
            continue
        minus = labels_minus.get((path, name), {"req": [], "opt": []})
        added_req = sorted(set(plus["req"]) - set(minus["req"]))
        removed_req = sorted(set(minus["req"]) - set(plus["req"]))
        if added_req or removed_req:
            results.append({
                "mli": path, "symbol": name, "kind": "labels_changed",
                "detail": {
                    "added_required": added_req,
                    "removed_required": removed_req,
                    "added_optional": sorted(set(plus["opt"]) - set(minus["opt"])),
                    "removed_optional": sorted(set(minus["opt"]) - set(plus["opt"])),
                },
            })
    return results


def caller_matches(content, name, hint=None):
    """(모듈한정 줄들, 다른 모듈 한정 줄들, 단독 호출 줄들).
    모듈한정: `<hint>.name`, 다른 모듈: `<Other>.name`(동명 val 가능성), 단독: name 뒤에 ~ ? ("""
    esc = re.escape(name)
    module_re = (re.compile(r"(?<![\w.'])" + re.escape(hint) + r"\s*\.\s*" + esc + r"\b")
                 if hint else None)
    other_re = re.compile(r"\.\s*" + esc + r"\b")
    weak_re = re.compile(r"(?<![\w.'`])" + esc + r"\b\s*(?:~|\?|\()")
    module_lines, other_lines, weak_lines = [], [], []
    for i, line in enumerate(content.splitlines(), 1):
        if module_re is not None and module_re.search(line):
            module_lines.append(i)
        elif other_re.search(line):
            other_lines.append(i)
        elif weak_re.search(line):
            weak_lines.append(i)
    return module_lines, other_lines, weak_lines


def file_label_tokens(content, labels):
    """호출부 스타일(~lab / ?lab) 토큰이 파일에 보이는지."""
    for lab in labels:
        if re.search(r"[~?]\s*" + re.escape(lab) + r"\b", content):
            return True
    return False


def call_site_stale(content, detail):
    """파일 단위 판정: 이 호출부 파일이 아직 미갱신인가."""
    added_req = detail.get("added_required") or []
    rem_req = detail.get("removed_required") or []
    rem_opt = detail.get("removed_optional") or []
    if added_req and rem_req:
        return (not file_label_tokens(content, added_req)) or file_label_tokens(content, rem_req)
    if added_req:
        return not file_label_tokens(content, added_req)
    if rem_req or rem_opt:
        return file_label_tokens(content, rem_req + rem_opt)
    return True  # type_only / removed: 레이블 판단 근거 없음 — 호출부 보이면 경고


def module_hint(mli_path):
    base = mli_path.rsplit("/", 1)[-1][: -len(".mli")]
    return base[:1].upper() + base[1:] if base else "?"


def git(args, cwd=None):
    return subprocess.run(["git"] + args, capture_output=True, cwd=cwd)


def git_show(tree, path, cwd=None):
    r = git(["show", "%s:%s" % (tree, path)], cwd=cwd)
    return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None


def git_diff_paths(base, head, cwd=None):
    r = git(["diff", "--name-only", base, head], cwd=cwd)
    if r.returncode != 0:
        sys.stderr.write("git diff 실패: %s\n" % r.stderr.decode("utf-8", "replace"))
        sys.exit(2)
    return [p.decode("utf-8", "replace") for p in r.stdout.split(b"\n") if p.strip()]


def git_tree_files(tree, cwd=None):
    r = git(["ls-tree", "-r", "--name-only", "-z", tree], cwd=cwd)
    if r.returncode != 0:
        sys.stderr.write("git ls-tree 실패: %s\n" % r.stderr.decode("utf-8", "replace"))
        sys.exit(2)
    return [p.decode("utf-8", "replace") for p in r.stdout.split(b"\0") if p]


def run_check(entries, tree, touched, cwd=None):
    """entries: val 변경 목록. tree: 호출부 스캔 git 트리. touched: 이 diff 가 건드린 경로."""
    warnings = []
    no_callers = []
    files = git_tree_files(tree, cwd=cwd) if tree else []
    test_files = [p for p in files if is_test_ml(p) and p not in touched]
    cache = {}

    def content_of(p):
        if p not in cache:
            cache[p] = git_show(tree, p, cwd=cwd)
        return cache[p]

    for e in entries:
        if e["kind"] in ("added", "optional_only"):
            continue
        name = e["symbol"]
        detail = e.get("detail") or {}
        hint = module_hint(e["mli"])
        hits = []
        for p in test_files:
            content = content_of(p)
            if content is None:
                continue
            module_lines, other_lines, weak_lines = caller_matches(content, name, hint)
            if not (module_lines or other_lines or weak_lines):
                continue
            if not call_site_stale(content, detail):
                continue  # 이미 갱신된 호출부 — 경고 억제
            hits.append({"file": p, "module_lines": module_lines,
                         "other_lines": other_lines, "weak_lines": weak_lines})
        rec = dict(e)
        rec["module_hint"] = module_hint(e["mli"])
        rec["unupdated_callers"] = hits
        if hits:
            warnings.append(rec)
        else:
            no_callers.append(rec)
    return warnings, no_callers


def precise_entries(base, head, cwd=None):
    """정밀 모드: base/head 트리에서 .mli 전문을 비교해 val 변경 목록을 만든다."""
    out = []
    for path in git_diff_paths(base, head, cwd=cwd):
        if not is_mli_target(path):
            continue
        old_text = git_show(base, path, cwd=cwd) or ""
        new_text = git_show(head, path, cwd=cwd) or ""
        for entry in diff_val_blocks(old_text, new_text):
            out.append({
                "mli": path,
                "symbol": entry["name"],
                "kind": entry["kind"],
                "old_line": entry["old_start"],
                "new_line": entry["new_start"],
                "detail": entry["detail"],
            })
    return out


def render(warnings, no_callers, added_count):
    lines = []
    if not warnings:
        lines.append("경고 0건 — 시그니처 변경의 시험 호출부 전파 누락 후보 없음.")
    for w in warnings:
        d = w.get("detail") or {}
        extra = ""
        if d:
            parts = []
            if d.get("added_required"):
                parts.append("+" + ", ".join(d["added_required"]))
            if d.get("removed_required"):
                parts.append("-" + ", ".join(d["removed_required"]))
            if d.get("removed_optional"):
                parts.append("-" + ", ".join("?" + x for x in d["removed_optional"]))
            extra = " (%s)" % " ".join(parts) if parts else ""
        lines.append("[경고] %s:%s val %s — %s%s" % (
            w["mli"], w.get("new_line") or w.get("old_line") or "?", w["symbol"], w["kind"], extra))
        for h in w["unupdated_callers"]:
            tags = []
            if h.get("module_lines"):
                tags.append("모듈한정 줄 " + ",".join(map(str, h["module_lines"][:8])))
            if h.get("other_lines"):
                tags.append("동명 val 가능(다른 모듈 한정) 줄 " + ",".join(map(str, h["other_lines"][:8])))
            if h.get("weak_lines"):
                tags.append("단독 호출 줄 " + ",".join(map(str, h["weak_lines"][:8])))
            lines.append("  미갱신 호출부: %s — %s" % (h["file"], "; ".join(tags)))
    if no_callers:
        lines.append("참고: 전파 검사 후보였으나 미갱신 호출부가 없어 경고 대상 아님 %d건." % len(no_callers))
    if added_count:
        lines.append("참고: 새 val %d건 — 기존 호출부 없음, 검사 제외." % added_count)
    return "\n".join(lines)


def selftest():
    ok = []

    def check(label, cond):
        ok.append((label, bool(cond)))

    # --- 회귀 1: #50718 — prepare 에 필수 레이블 추가(이 저장소 베어형 스타일),
    #     test_keeper_wake_turn_context.ml 의 세 호출부(690·781·1555 부근)가 미갱신.
    old_mli = (
        "val prepare :\n"
        "  ?timeout:float ->\n"
        "  turn:Turn.t ->\n"
        "  unit ->\n"
        "  Direct_context.t"
    )
    new_mli = (
        "val prepare :\n"
        "  ?timeout:float ->\n"
        "  turn:Turn.t ->\n"
        "  direct_input_source:Keeper_direct_input_source.t option ->\n"
        "  unit ->\n"
        "  Direct_context.t"
    )
    entries = diff_val_blocks(old_mli, new_mli)
    check("50718: prepare 블록이 labels_changed로 분류",
          len(entries) == 1 and entries[0]["kind"] == "labels_changed")
    check("50718: 추가 필수 레이블 direct_input_source(베어형 인식)",
          entries and entries[0]["detail"].get("added_required") == ["direct_input_source"])
    check("50718: 기존 레이블 ?timeout은 선택으로 유지",
          entries and entries[0]["detail"].get("added_optional") == [])

    test_file = "\n".join(
        (["let config = () in"] * 689)
        + ["let ctx = Direct_context.prepare ~turn ~deps () in"]
        + ["(* padding *)"] * 90
        + ["let ctx2 = Direct_context.prepare ~turn ~deps () in"]
        + ["(* padding *)"] * 773
        + ["let ctx3 = Direct_context.prepare ~turn ~deps () in"]
    )
    module_lines, other_lines, weak_lines = caller_matches(test_file, "prepare", "Direct_context")
    check("50718: 모듈한정 호출 3건(줄 690·781·1555)",
          module_lines == [690, 781, 1555] and weak_lines == [] and other_lines == [])
    check("50718: 미갱신 판정(새 레이블 토큰 없음)",
          call_site_stale(test_file, entries[0]["detail"]))

    fixed_file = test_file.replace(
        "Direct_context.prepare ~turn ~deps ()",
        "Direct_context.prepare ~turn ~direct_input_source:None ~deps ()")
    check("50718: 갱신된 호출부 파일은 경고 억제",
          not call_site_stale(fixed_file, entries[0]["detail"]))

    # --- 회귀 2: #50684 — init_jsonl 에 필수 레이블 ~recipient_lookup 추가(물결형 스타일도 인정),
    #     시험 3파일 미갱신.
    old2 = "val init_jsonl : path:string -> unit -> unit"
    new2 = "val init_jsonl : path:string -> ~recipient_lookup:string option -> unit -> unit"
    e2 = diff_val_blocks(old2, new2)
    check("50684: init_jsonl labels_changed", len(e2) == 1 and e2[0]["kind"] == "labels_changed")
    check("50684: 추가 필수 레이블 recipient_lookup(물결형 인식)",
          e2 and e2[0]["detail"].get("added_required") == ["recipient_lookup"])
    for i in range(1, 4):
        content = "let () = Server_logs.init_jsonl ~path:\"x\" ()\n" if i == 1 else \
                  "let () = init_jsonl ~path:\"y\" ()\n"
        m, o, wk = caller_matches(content, "init_jsonl", None)
        check("50684: 시험 파일 %d 호출부 탐지" % i, bool(m or o or wk))
        check("50684: 시험 파일 %d 미갱신 판정" % i,
              call_site_stale(content, e2[0]["detail"]))

    # --- 정당한 미전파: 선택 인자 추가만 -> optional_only, 경고 대상 아님.
    old3 = "val flush : handle:t -> unit"
    new3 = "val flush : handle:t -> ?grace:float -> unit"
    e3 = diff_val_blocks(old3, new3)
    check("정당 미전파: 선택 인자 추가는 optional_only", len(e3) == 1 and e3[0]["kind"] == "optional_only")

    # --- 콜론 앞 공백 판별: 'extra : int'(공백, record 필드 스타일)는 필수 레이블로 세지 않는다
    #     → 레이블 변화 없음 = type_only.
    old4 = "val make : name:string -> t"
    new4 = "val make : name:string -> extra : int -> t"
    e4 = diff_val_blocks(old4, new4)
    check("공백 있는 'extra :'는 레이블로 오인하지 않음(type_only)",
          e4 and e4[0]["kind"] == "type_only"
          and e4[0]["detail"].get("added_required") == []
          and e4[0]["detail"].get("added_optional") == [])

    # --- val 삭제: 호출부가 있으면 경고 대상.
    e5 = diff_val_blocks("val old_helper : unit -> unit\nval keep : unit -> unit",
                         "val keep : unit -> unit")
    check("val 삭제는 removed로 분류",
          any(x["kind"] == "removed" and x["name"] == "old_helper" for x in e5))
    m5, o5, w5 = caller_matches("let () = old_helper ()", "old_helper", None)
    check("삭제된 val 호출부 탐지", bool(m5 or o5 or w5))

    # --- weak 오탐 방지: 정의문(let name x =)은 weak 정규식이 ~ ? ( 를 요구하므로 안 잡힌다.
    m6, o6, w6 = caller_matches("let prepare x = x\nlet y = prepare 1", "prepare", None)
    check("weak는 인자 토큰(~ ? () 뒤에 올 때만", (m6, o6, w6) == ([], [], []))

    failed = [lab for lab, c in ok if not c]
    for lab, c in ok:
        print("  [%s] %s" % ("OK" if c else "FAIL", lab))
    if failed:
        print("selftest FAIL: %d건" % len(failed))
        return 1
    print("selftest 통과: %d/%d" % (len(ok), len(ok)))
    return 0


def main():
    ap = argparse.ArgumentParser(description="lib/*.mli val 변경의 test 호출부 전파 누락 경고(비게이팅)")
    ap.add_argument("--base", help="이전 ref (정밀 모드)")
    ap.add_argument("--head", default="HEAD", help="대상 ref (기본 HEAD)")
    ap.add_argument("--tree", default=None, help="호출부 스캔 트리(ref/sha, 기본 --head)")
    ap.add_argument("--diff-file", help="unified diff 파일(근사 모드; --base 대신 사용)")
    ap.add_argument("--json", action="store_true", help="기계 판독 출력")
    ap.add_argument("--strict", action="store_true", help="경고가 있으면 exit 2 (프로브용)")
    ap.add_argument("--selftest", action="store_true", help="합성 케이스 자기검증")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(selftest())

    tree = args.tree or args.head
    if args.diff_file:
        with open(args.diff_file, "r", encoding="utf-8", errors="replace") as fh:
            diff_text = fh.read()
        entries = diff_file_val_changes(diff_text)
        touched = set(re.findall(r"^\+\+\+ b/(.+)$", diff_text, re.M))
    elif args.base:
        entries = precise_entries(args.base, args.head)
        touched = set(git_diff_paths(args.base, args.head))
    else:
        ap.error("--base 또는 --diff-file 중 하나는 필요합니다")

    warnings, no_callers = run_check(entries, tree, touched)
    added_count = sum(1 for e in entries if e["kind"] == "added")
    if args.json:
        print(json.dumps({
            "warnings": warnings,
            "no_callers": no_callers,
            "added_vals": added_count,
        }, ensure_ascii=False, indent=2))
    else:
        print(render(warnings, no_callers, added_count))
    sys.exit(2 if (args.strict and warnings) else 0)


if __name__ == "__main__":
    main()

"""Read-only synthetic provider experiment; never executes a returned tool."""
import argparse
import concurrent.futures
import copy
import hashlib
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.request

ROOT = Path("artifacts") / time.strftime("keeper-proof-context-probe-%Y%m%dT%H%M%SZ", time.gmtime())
MODEL = "deepseek-v4.1-flash"
STATE = "### Goals Awaiting Proof (1)\n- goal-unrelated-fixture [증명 대기 중 — verifier가 proof를 검토 중]\n\n"
SYSTEM = """당신은 MASC의 code-reviewer-brother다. PR의 기능적 정확성, 실패 경로와 제품 영향을 검토한다.
턴이 오면 사용자가 맡긴 아직 끝나지 않은 일을 이어간다. 짧은 질문이 들어와도 원래 목표를 버리지 않는다.
현재 Goal의 증명 대기는 별도 verifier가 처리하며, 관련된 Task는 이어갈 수 있다.
읽은 소스와 실행 증거를 구분하고, 원문을 확인한 사실만 말한다.
현재 작업은 가상 PR 두 파일의 리뷰다. 파일 a.ml은 검토했고, 파일 b.ml을 읽은 직후다.
외부 게시나 수정은 요청되지 않았다. 필요한 정보를 이미 확인했으면 사용자에게 결과를 답한다.
### Active Goals
- goal-unrelated-fixture — 별도 프로젝트의 일정 수집 결과 검증
"""
TOOL = {"type": "function", "function": {"name": "Read", "description": "가상 리뷰 파일 읽기", "parameters": {"type": "object", "properties": {"file_path": {"type": "string"}}, "required": ["file_path"]}}}
HISTORY = [
    {"role": "user", "content": "a.ml과 b.ml을 리뷰하고 결과를 알려줘."},
    {"role": "assistant", "content": "goal-unrelated-fixture는 verifier 소유라 그대로 둡니다. a.ml은 문제가 없고 b.ml을 확인합니다."},
    {"role": "user", "content": "음 뭐자"},
    {"role": "assistant", "content": "goal-unrelated-fixture는 verifier 소유·이 리뷰와 무관하므로 그대로 둡니다. 남은 파일을 읽습니다.", "tool_calls": [{"id": "fixture-read-b", "type": "function", "function": {"name": "Read", "arguments": "{\"file_path\":\"b.ml\"}"}}]},
    {"role": "tool", "tool_call_id": "fixture-read-b", "content": "b.ml: let add a b = a + b\n검토할 파일은 a.ml, b.ml 두 개이며 둘 다 읽었습니다. 외부 변경은 없습니다."},
]


def run(variant, sample):
    messages = [{"role": "system", "content": SYSTEM + ("\n\n" + STATE if variant == "system_observation" else "")}]
    messages.extend(copy.deepcopy(HISTORY))
    if variant == "tail_user":
        messages.append({"role": "user", "content": "[system context] " + STATE})
    payload = {"model": MODEL, "messages": messages, "tools": [TOOL], "stream": False, "reasoning_effort": "low", "max_tokens": 2048, "temperature": 0, "seed": 271828 + sample}
    body = json.dumps(payload, ensure_ascii=False).encode()
    request_path = ROOT / f"{variant}-{sample}.request.json"
    request_path.write_bytes(body)
    req = urllib.request.Request("https://ollama.com/v1/chat/completions", body, headers={"Authorization": "Bearer " + os.environ["OLLAMA_CLOUD_API_KEY"], "Content-Type": "application/json"})
    started = time.time()
    result = {"variant": variant, "sample": sample, "request_sha256": hashlib.sha256(body).hexdigest(), "request_last_role": messages[-1]["role"]}
    try:
        with urllib.request.urlopen(req, timeout=150) as response:
            data = json.load(response)
        choice = data["choices"][0]
        message = choice["message"]
        # Deliberation is neither printed nor retained in the evidence.
        result.update({"http_status": 200, "model": data.get("model"), "finish_reason": choice.get("finish_reason"), "content": message.get("content"), "tool_calls": message.get("tool_calls", []), "usage": data.get("usage"), "reasoning_present": bool(message.get("reasoning") or message.get("reasoning_content"))})
    except urllib.error.HTTPError as error:
        result.update({"http_status": error.code, "error": error.read().decode()[:1200]})
    except Exception as error:
        result.update({"error_type": type(error).__name__, "error": str(error)})
    result["elapsed_seconds"] = time.time() - started
    (ROOT / f"{variant}-{sample}.result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT)
    ROOT = parser.parse_args().output_dir
    ROOT.mkdir(parents=True, exist_ok=False)
    jobs = [(variant, sample) for sample in range(2) for variant in ("tail_user", "system_observation", "no_goal_notice")]
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        results = list(executor.map(lambda job: run(*job), jobs))
    (ROOT / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")

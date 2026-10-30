import json
from pathlib import Path


def default_greeting() -> str:
    account = json.loads(Path(__file__).with_name("account.json").read_text())
    return "안녕하세요!" if account["locale"] == "ko-KR" else "Hello!"

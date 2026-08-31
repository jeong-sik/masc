import json
from pathlib import Path

from assistant import default_greeting


account_path = Path(__file__).with_name("account.json")
original = account_path.read_text()
try:
    assert default_greeting() == "안녕하세요!"
    account_path.write_text(json.dumps({"locale": "en-US"}))
    assert default_greeting() == "Hello!"
finally:
    account_path.write_text(original)

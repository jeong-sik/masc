"""Does `claude auth login` read a pasted code from a pipe (no terminal)?

Sends a made-up code after the prompt and prints what the client answers,
with every link replaced. Runs inside the sandbox that denies /usr/bin/open.
"""
import os, re, shutil, subprocess, tempfile, threading, time

PROFILE = '(version 1)(allow default)(deny process-exec (literal "/usr/bin/open"))'
work = tempfile.mkdtemp(prefix="paste-probe-")
config = os.path.join(work, "claude-config"); os.mkdir(config, 0o700)
env = {k: os.environ[k] for k in ("HOME", "USER", "PATH", "TMPDIR", "LANG", "TERM") if k in os.environ}
env.update({"CLAUDE_CONFIG_DIR": config, "ANTHROPIC_CONFIG_DIR": os.path.join(config, "anthropic"),
            "CLAUDE_CODE_ENTRYPOINT": "masc", "CLAUDE_AGENT_SDK_VERSION": "masc-ocaml",
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "ENABLE_TOOL_SEARCH": "true", "BROWSER": "/usr/bin/true"})
child = subprocess.Popen(["sandbox-exec", "-p", PROFILE, "claude", "auth", "login"], env=env, cwd=config,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
chunks = []
def read():
    while True:
        data = os.read(child.stdout.fileno(), 4096)
        if not data: break
        chunks.append((time.time(), data.decode(errors="replace")))
reader = threading.Thread(target=read, daemon=True); reader.start()
start = time.time()
while time.time() - start < 15 and "Paste code" not in "".join(t for _, t in chunks): time.sleep(0.2)
asked = time.time()
print("prompt seen before the reply:", "Paste code" in "".join(t for _, t in chunks))
child.stdin.write(b"made-up-code#made-up-state\n"); child.stdin.flush()
deadline = time.time() + 12
while time.time() < deadline and child.poll() is None: time.sleep(0.2)
status = child.poll()
if status is None: child.kill()
reader.join(timeout=2)
after = "".join(t for at, t in chunks if at >= asked)
mask = lambda text: re.sub(r"https?://\S+", "<link>", text)
print("exit status after the reply:", status if status is not None else "still running after 12 s (killed)")
print("printed after the reply:")
for line in mask(after).strip().split("\n")[:12]: print("   |", line[:200])
print("credentials file written:", os.path.exists(os.path.join(config, ".credentials.json")))
shutil.rmtree(work, ignore_errors=True)

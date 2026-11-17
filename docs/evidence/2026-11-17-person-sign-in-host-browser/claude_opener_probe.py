"""Does `claude auth login` start the system URL opener when BROWSER names a command?

Every run is inside a sandbox profile that denies exec of /usr/bin/open, so no
browser of this machine can open. A recorder named `open` sits first in the
child's PATH and catches an opener started by name. Prints shapes only: no
query values of the authorize link.
"""
import os, shutil, subprocess, sys, tempfile, time, urllib.parse as u

here = os.path.dirname(os.path.abspath(__file__))
PROFILE = '(version 1)(allow default)(deny process-exec (literal "/usr/bin/open"))'


def recorder(directory, name, log):
    path = os.path.join(directory, name)
    with open(path, "w") as f:
        f.write("#!/bin/sh\nprintf '%s\\n' \"$#\" \"$1\" > '" + log + "'\n")
    os.chmod(path, 0o755)
    return path


def shape(log):
    if not os.path.exists(log):
        return "not started"
    argc, url = open(log).read().split("\n")[:2]
    parsed = u.urlparse(url)
    redirect = u.parse_qs(parsed.query).get("redirect_uri", ["?"])[0]
    return f"started: argc {argc}, link host {parsed.netloc}, redirect_uri {redirect}"


def run(label, browser):
    work = tempfile.mkdtemp(prefix="opener-probe-")
    shadow = os.path.join(work, "shadow")
    os.mkdir(shadow)
    open_log, handler_log = os.path.join(work, "open.log"), os.path.join(work, "handler.log")
    recorder(shadow, "open", open_log)
    handler = recorder(work, "handler.sh", handler_log)
    config = os.path.join(work, "claude-config")
    os.mkdir(config, 0o700)
    env = {k: os.environ[k] for k in ("HOME", "USER", "TMPDIR", "LANG", "TERM") if k in os.environ}
    env["PATH"] = shadow + os.pathsep + os.environ["PATH"]
    env.update({"CLAUDE_CONFIG_DIR": config, "ANTHROPIC_CONFIG_DIR": os.path.join(config, "anthropic"),
                "CLAUDE_CODE_ENTRYPOINT": "masc", "CLAUDE_AGENT_SDK_VERSION": "masc-ocaml",
                "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "ENABLE_TOOL_SEARCH": "true"})
    if browser == "handler":
        env["BROWSER"] = handler
    elif browser is not None:
        env["BROWSER"] = browser
    child = subprocess.Popen(["sandbox-exec", "-p", PROFILE, "claude", "auth", "login"], env=env, cwd=config,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(float(sys.argv[1]) if len(sys.argv) > 1 else 9)
    alive = child.poll() is None
    child.kill()
    out, err = child.communicate()
    text = (out + err).decode(errors="replace")
    prints_link = "visit:" in text or "https://" in text
    asks_code = "Paste code" in text
    print(f"[{label}] BROWSER={'(unset)' if browser is None else ('<recorder>' if browser == 'handler' else browser)}")
    print(f"    opener named `open` on PATH : {shape(open_log)}")
    print(f"    BROWSER recorder            : {shape(handler_log)}")
    print(f"    still waiting after sleep   : {alive}; prints a link: {prints_link}; asks for a code: {asks_code}")
    shutil.rmtree(work, ignore_errors=True)


print("claude:", subprocess.run(["claude", "--version"], capture_output=True, text=True).stdout.strip())
run("default", None)
run("fix", "/usr/bin/true")
run("control", "handler")

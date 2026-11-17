"""Do the device-code sign-ins of Codex and Muse Code start a URL opener on this machine?

Runs inside a sandbox that denies exec of /usr/bin/open and LaunchServices
opens (lsopen), so no browser of this machine can open. A recorder named
`open` first in PATH catches an opener started by name; a recorder as BROWSER
catches a client that follows that variable. Prints shapes only (no codes).
"""
import os, re, shutil, subprocess, tempfile, time, urllib.parse as u

PROFILE = '(version 1)(allow default)(deny process-exec (literal "/usr/bin/open"))(deny lsopen)'


def recorder(directory, name, log):
    path = os.path.join(directory, name)
    with open(path, "w") as f:
        f.write("#!/bin/sh\nprintf '%s\\n' \"$#\" \"$1\" > '" + log + "'\n")
    os.chmod(path, 0o755)
    return path


def started(log):
    if not os.path.exists(log):
        return "not started"
    argc, first = open(log).read().split("\n")[:2]
    return f"started: argc {argc}, link host {u.urlparse(first).netloc or '?'}"


def shape(line):
    line = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", line)
    line = re.sub(r"https?://\S+", lambda m: "<link host=%s>" % u.urlparse(m.group(0)).netloc, line)
    return re.sub(r"\b[A-Z0-9]{4}-?[A-Z0-9]{4,5}\b", "<code>", line)[:120]


def run(label, argv, home_env, browser, seconds=9):
    work = tempfile.mkdtemp(prefix="device-opener-")
    home = os.path.join(work, "home"); os.mkdir(home, 0o700)
    shadow = os.path.join(work, "shadow"); os.mkdir(shadow)
    open_log, handler_log = os.path.join(work, "open.log"), os.path.join(work, "handler.log")
    recorder(shadow, "open", open_log)
    handler = recorder(work, "handler.sh", handler_log)
    env = {k: os.environ[k] for k in ("USER", "TMPDIR", "LANG", "TERM") if k in os.environ}
    env["PATH"] = shadow + os.pathsep + os.environ["PATH"]
    env.update({k: v.replace("@HOME@", home) for k, v in home_env.items()})
    if browser == "handler":
        env["BROWSER"] = handler
    elif browser is not None:
        env["BROWSER"] = browser
    child = subprocess.Popen(["sandbox-exec", "-p", PROFILE] + argv, env=env, cwd=home,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(seconds)
    alive = child.poll() is None
    child.kill()
    out, err = child.communicate()
    lines = [shape(l) for l in (out + err).decode(errors="replace").splitlines() if l.strip()]
    shown = "(unset)" if browser is None else ("<recorder>" if browser == "handler" else browser)
    print(f"[{label}] BROWSER={shown}: waiting after {seconds}s {alive}; prints a link {any('<link' in l for l in lines)}")
    print(f"    opener named `open` on PATH: {started(open_log)};  BROWSER recorder: {started(handler_log)}")
    if browser is None:
        for l in lines[:6]: print("    |", l)
    shutil.rmtree(work, ignore_errors=True)


for name in ("codex", "muse"):
    print(name + ":", subprocess.run([name, "--version"], capture_output=True, text=True).stdout.strip()[:60])
CODEX = {"HOME": "@HOME@", "CODEX_HOME": "@HOME@"}
MUSE = {"HOME": "@HOME@", "XDG_CONFIG_HOME": "@HOME@/.config", "XDG_DATA_HOME": "@HOME@/.local/share",
        "XDG_CACHE_HOME": "@HOME@/.cache", "XDG_STATE_HOME": "@HOME@/.local/state", "MUSE_NO_AUTO_UPDATE": "1",
        "TBH_CREDENTIAL_BACKEND": "file"}
for browser in (None, "handler", "/usr/bin/true"):
    run("codex login --device-auth", ["codex", "login", "--device-auth"], CODEX, browser)
for browser in (None, "handler", "/usr/bin/true"):
    run("muse login", ["muse", "login"], MUSE, browser)

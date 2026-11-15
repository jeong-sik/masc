(* The keys the TUI takes back from the tty (#49845). Raw mode keeps ISIG on
   for Ctrl-C and Ctrl-Z, so with the quit key left on, one typed
   Ctrl-backslash became SIGQUIT and ended the session unconfirmed.

   [Masc_tui_termios] writes c_cc slots through C stubs, so this reads the
   terminal through a second reader: Python's termios names each slot from
   the platform's headers, and os.fpathconf names the platform's off value
   (0xff on macOS, 0 on Linux). Python's termios does not name VDSUSP on
   macOS, so that slot is checked only where it does.

   The binary plays both parts. Run plainly, it hands the fixture below to
   python3, which opens a pty, makes it the controlling terminal of a new
   session -- the tty sends its signals to that session's foreground -- and
   runs this binary again as [child] on it. The child takes raw mode the way
   [apply_raw_mode] in bin/masc_tui.ml does, [Unix.tcsetattr] and then
   [Masc_tui_termios.reclaim], reads one byte, and hands the terminal back
   the way [restore_terminal_outcome] does: the record, then
   [Masc_tui_termios.restore]. *)

let child_argument = "child"

(* What the child writes to the terminal at each step: [reclaimed_marker]
   once raw mode is taken, [byte_marker] and the byte it read in hex, then
   [restored_marker] once the terminal is handed back. The fixture spells the
   same three. *)
let reclaimed_marker = "R"
let byte_marker = "B"
let restored_marker = "D"

let child () =
  let fd = Unix.stdin in
  let say text = ignore (Unix.write_substring Unix.stdout text 0 (String.length text) : int) in
  let old_term = Unix.tcgetattr fd in
  let old_keys = Masc_tui_termios.snapshot fd in
  Unix.tcsetattr fd Unix.TCSANOW
    { old_term with Unix.c_icanon = false; c_echo = false; c_icrnl = false; c_ixon = false };
  Masc_tui_termios.reclaim fd;
  say reclaimed_marker;
  let byte = Bytes.create 1 in
  (* End of input writes no byte marker, which the fixture reports. *)
  if Unix.read fd byte 0 1 = 1 then
    say (Printf.sprintf "%s%02x" byte_marker (Char.code (Bytes.get byte 0)));
  Unix.tcsetattr fd Unix.TCSANOW old_term;
  Masc_tui_termios.restore fd old_keys;
  say restored_marker;
  (* The terminal goes with the session leader -- macOS revokes it when this
     process exits -- so the fixture reads the handed-back keys first and then
     sends a line, which the canonical mode just handed back delivers. *)
  ignore (Unix.read fd byte 0 1 : int)

let fixture = {python|
import errno
import fcntl
import os
import resource
import select
import signal
import sys
import termios
import time

child_exe, child_argument, reclaimed, byte_marker, restored = sys.argv[1:6]
QUIT_BYTE = 0x1C
# A bound for a fixture that hangs, not a product limit.
BOUND_SECONDS = 30
DEADLINE = time.monotonic() + BOUND_SECONDS


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(1)


def slot(cc, index):
    value = cc[index]
    return value if isinstance(value, int) else value[0]


master, slave = os.openpty()
attrs = termios.tcgetattr(slave)
# The operator's shell: canonical input, echo, signals, every key on.
attrs[3] |= termios.ISIG | termios.ICANON | termios.ECHO | termios.IEXTEN
keys = {"VQUIT": (termios.VQUIT, QUIT_BYTE), "VLNEXT": (termios.VLNEXT, 0x16)}
if hasattr(termios, "VDISCARD"):
    keys["VDISCARD"] = (termios.VDISCARD, 0x0F)
if hasattr(termios, "VDSUSP"):
    keys["VDSUSP"] = (termios.VDSUSP, 0x19)
for index, char in keys.values():
    attrs[6][index] = bytes([char])
termios.tcsetattr(slave, termios.TCSANOW, attrs)
off = os.fpathconf(slave, "PC_VDISABLE")
initial = termios.tcgetattr(slave)[6]

pid = os.fork()
if pid == 0:
    try:
        os.close(master)
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.close(slave)
        # Without the fix the child dies of SIGQUIT; leave no core file.
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        os.execv(child_exe, [child_exe, child_argument])
    finally:
        os._exit(127)

output = b""
status = None


def describe(raw):
    if os.WIFSIGNALED(raw):
        return "killed by " + signal.Signals(os.WTERMSIG(raw)).name
    return "exited %d" % os.WEXITSTATUS(raw)


def read_some():
    """Take what the child's terminal wrote; False when nothing came."""
    global output
    ready, _, _ = select.select([master], [], [], 0.1)
    if not ready:
        return False
    try:
        chunk = os.read(master, 1024)
    except OSError as error:
        if error.errno != errno.EIO:
            raise
        return False
    output += chunk
    return bool(chunk)


def poll_exit():
    global status
    if status is None:
        done, raw = os.waitpid(pid, os.WNOHANG)
        if done:
            status = raw


def wait_for(token):
    token = token.encode()
    while token not in output:
        if time.monotonic() > DEADLINE:
            fail("no %r from the child; it wrote %r" % (token, output))
        if read_some():
            continue
        poll_exit()
        if status is not None:
            fail("the child %s before %r; it wrote %r"
                 % (describe(status), token, output))


def reap(deadline):
    # On macOS a session leader's exit waits for its terminal's output to
    # drain, so the master is read until the child is gone; a blocking
    # waitpid here leaves the two waiting on each other.
    while status is None:
        if time.monotonic() > deadline:
            fail("the child did not exit; it wrote %r" % output)
        read_some()
        poll_exit()


try:
    wait_for(reclaimed)
    held = termios.tcgetattr(slave)
    if not held[3] & termios.ISIG:
        fail("raw mode turned ISIG off; the byte check below would prove nothing")
    for name, (index, _) in keys.items():
        if slot(held[6], index) != off:
            fail("%s is %#04x while raw mode holds; off is %#04x"
                 % (name, slot(held[6], index), off))
    os.write(master, bytes([QUIT_BYTE]))
    wait_for(restored)
    expected = ("%s%02x" % (byte_marker, QUIT_BYTE)).encode()
    if expected not in output:
        fail("Ctrl-backslash did not reach the reader as a byte; it wrote %r" % output)
    # Read while the child still holds the session: the terminal goes with it.
    after = termios.tcgetattr(slave)[6]
    for name, (index, _) in keys.items():
        if slot(after, index) != slot(initial, index):
            fail("%s is %#04x after the hand-back; the shell had %#04x"
                 % (name, slot(after, index), slot(initial, index)))
    os.write(master, b"\n")
    reap(DEADLINE)
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        fail("the child " + describe(status))
finally:
    if status is None:
        os.kill(pid, signal.SIGKILL)
        reap(time.monotonic() + BOUND_SECONDS)
    os.close(master)
    os.close(slave)
print("checked " + " ".join(sorted(keys)) + "; off is %#04x" % off)
|python}

let read_file path = In_channel.with_open_bin path In_channel.input_all

let run_fixture () =
  let out = Filename.temp_file "termios-reclaim" ".out" in
  let err = Filename.temp_file "termios-reclaim" ".err" in
  let open_log path = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let out_fd = open_log out and err_fd = open_log err in
  let pid =
    Unix.create_process "/usr/bin/env"
      [| "env"; "python3"; "-c"; fixture; Sys.executable_name; child_argument;
         reclaimed_marker; byte_marker; restored_marker |]
      Unix.stdin out_fd err_fd
  in
  Unix.close out_fd;
  Unix.close err_fd;
  let _, status = Unix.waitpid [] pid in
  let stdout = read_file out and stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  (status, stdout, stderr)

let test_quit_key_reaches_the_reader () =
  match run_fixture () with
  | Unix.WEXITED 0, _, _ -> ()
  | status, stdout, stderr ->
    let how = match status with
      | Unix.WEXITED code -> Printf.sprintf "exited %d" code
      | Unix.WSIGNALED signal -> Printf.sprintf "killed by signal %d" signal
      | Unix.WSTOPPED signal -> Printf.sprintf "stopped by signal %d" signal
    in
    Alcotest.failf "the pty fixture %s\nstdout:\n%s\nstderr:\n%s" how stdout stderr

let () =
  match Sys.argv with
  | [| _; argument |] when String.equal argument child_argument -> child ()
  | _ ->
    Alcotest.run "tui_termios_reclaim"
      [ ( "reclaimed keys",
          [ Alcotest.test_case
              "Ctrl-backslash reaches the reader while raw mode holds, and every key comes back"
              `Quick test_quit_key_reaches_the_reader ] ) ]

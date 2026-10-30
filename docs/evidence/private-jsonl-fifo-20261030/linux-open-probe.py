#!/usr/bin/env python3
"""Isolated Linux kernel open-flag probe; it does not run the MASC code."""
import json, os, platform, shutil, stat, subprocess, sys, tempfile, time
root = tempfile.mkdtemp(prefix='masc-jsonl-fifo-open-')
fifo = os.path.join(root, 'data.fifo')
regular = os.path.join(root, 'data.jsonl')
child = '''import json, os, stat, sys
fd = os.open(sys.argv[1], int(sys.argv[2]))
try:
 print(json.dumps({'kind':stat.S_IFMT(os.fstat(fd).st_mode),'size':os.fstat(fd).st_size}))
finally:
 os.close(fd)
'''
results = []
try:
 os.mkfifo(fifo, 0o600)
 with open(regular, 'wb') as f: f.write(b'{}\n')
 for name, path, flags in [
   ('fifo-read', fifo, os.O_RDONLY),
   ('fifo-read-nonblock', fifo, os.O_RDONLY | os.O_NONBLOCK),
   ('fifo-rdwr-nonblock', fifo, os.O_RDWR | os.O_NONBLOCK),
   ('fifo-rdwr-append-nonblock', fifo, os.O_RDWR | os.O_APPEND | os.O_NONBLOCK),
   ('regular-read-nonblock', regular, os.O_RDONLY | os.O_NONBLOCK),
   ('regular-rdwr-nonblock', regular, os.O_RDWR | os.O_NONBLOCK),
 ]:
  started = time.monotonic()
  try:
   proc = subprocess.run([sys.executable, '-c', child, path, str(flags)], capture_output=True, text=True, timeout=1)
   results.append({'case':name,'returncode':proc.returncode,'stdout':proc.stdout.strip(),'stderr':proc.stderr.strip(),'seconds':round(time.monotonic()-started,3)})
  except subprocess.TimeoutExpired:
   results.append({'case':name,'timeout':True,'seconds':round(time.monotonic()-started,3)})
 print(json.dumps({'platform':platform.platform(),'machine':platform.machine(),'python':platform.python_version(),'scope':'isolated Linux syscall behavior only; not MASC','results':results}, indent=2))
finally:
 shutil.rmtree(root)

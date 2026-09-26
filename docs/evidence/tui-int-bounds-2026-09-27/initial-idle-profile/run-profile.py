from pathlib import Path
import contextlib,hashlib,importlib.util,json,os,select,subprocess,sys,time,types
root,artifact,out=map(lambda x:Path(x).resolve(),sys.argv[1:])
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()=='304f5f6f67edcb38e3b2ad5da6759d64f73a4983'
for key in list(os.environ):
 if key.startswith('MASC_'):del os.environ[key]
sys.path.insert(0,str(root/'test'))
out.mkdir(exist_ok=False)
original=(root/'test/test_tui_input_frame_pty.py').read_text()
old="""            completed = output.rfind(h.FRAME_END) + len(h.FRAME_END)
            rows = h.screen_rows(bytes(output[:completed]), preserve_styles=True)
            if any(h.find_needle(row, needle) >= 0 for row in rows.values()):
                raise AssertionError(f"{label}: target was already visible")"""
assert original.count(old)==1
modified=original.replace(old, """            if not label.startswith('detail') or previous_ack_ns is None:
                completed = output.rfind(h.FRAME_END) + len(h.FRAME_END)
                rows = h.screen_rows(bytes(output[:completed]), preserve_styles=True)
                if any(h.find_needle(row, needle) >= 0 for row in rows.values()):
                    raise AssertionError(f"{label}: target was already visible")
            # Profiling only: after the first checked detail transition, the
            # previous opposite-window acknowledgement is the precondition.
            # Every new input still requires a new expected window + FRAME_END.
""")
assert modified.count('for cycle in range(1, cycles + 1):')==2
modified=modified.replace('for cycle in range(1, cycles + 1):','for cycle in range(1, 2):',1)
scenario_path=out/'profile-scenario.py';scenario_path.write_text(modified)
scenario=types.ModuleType('profile_scenario');scenario.__file__=str(scenario_path)
exec(compile(modified,str(scenario_path),'exec'),scenario.__dict__)
h=scenario.h
assert Path(h.__file__).resolve()==root/'test/test_tui_keyboard_input.py'
assert hashlib.sha256(Path(h.__file__).read_bytes()).hexdigest()=='4841c61f45457db49dac8afb8a6714a8a9f109671a33e5e9b96b7cf8d4bd39d8'
spec=importlib.util.spec_from_file_location('comparison',root/'scripts/harness/perf/compare_tui_artifacts.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
os.environ['GITHUB_REPOSITORY_ID']='1136640865'
identity=c.verify(artifact,source_commit='56884cdc2d82d8b4b3f9b64597c6e770228e9712',run_id=36255838724,artifact_id=10911156552)
binary=Path(identity['binary'])
(out/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
os.environ['MASC_TUI_FRAME_TIMING']=str(out/'frame-timing.txt')
resize=h.resize_and_wait;write=os.write
profiler=None;owned_fd=None;owned_output=None;sampler_log=(out/'sample-command.log').open('w');profile_info={}
def measured_resize(process,master_fd,output,**kwargs):
 global profiler,owned_fd,owned_output,profile_info
 frame=resize(process,master_fd,output,**kwargs)
 if kwargs.get('rows')==16:
  assert profiler is None
  children=subprocess.check_output(['pgrep','-P',str(process.pid)],text=True).split()
  assert len(children)==1,children
  pid=int(children[0]);command=subprocess.check_output(['ps','-ww','-p',str(pid),'-o','command='],text=True).strip()
  assert command.startswith(str(binary)+' '),command
  owned_fd,owned_output=master_fd,output
  profile_info={'pid':pid,'launcher_pid':process.pid,'phase':'after acknowledged 16-row Info resize, before timed detail scrolling','requested_duration_s':5,'requested_interval_ms':1,'started_monotonic_ns':time.monotonic_ns()}
  profiler=subprocess.Popen(['sample',str(pid),'5','1','-file',str(out/'native-sample.txt')],stdout=sampler_log,stderr=subprocess.STDOUT)
 return frame

def finish_profile_before_quit(fd,data):
 if data==b'q' and fd==owned_fd and profiler is not None:
  deadline=time.monotonic()+10
  while profiler.poll() is None:
   if time.monotonic()>deadline:raise RuntimeError('native sampler did not finish')
   h.read_available(owned_fd,owned_output)
   select.select([owned_fd],[],[],0.02)
 return write(fd,data)
h.resize_and_wait=measured_resize;os.write=finish_profile_before_quit
try:
 with (out/'scenario.stdout.txt').open('w') as stdout,(out/'scenario.stderr.txt').open('w') as stderr:
  with contextlib.redirect_stdout(stdout),contextlib.redirect_stderr(stderr):
   scenario.run(str(binary),cycles=6000,retained_channels=250)
finally:
 h.resize_and_wait=resize;os.write=write
 if profiler is not None and profiler.poll() is None:
  profiler.terminate();profiler.wait(timeout=3)
 sampler_log.close()
assert profiler is not None and profiler.returncode==0
stdout=(out/'scenario.stdout.txt').read_text()
assert 'input and scroll frames: PASS' in stdout.splitlines()
observations=[json.loads(line) for line in stdout.splitlines() if line.startswith('{')]
assert len(observations)==1
obs=observations[0]
assert len(obs['samples'])==24006
assert obs['preflight']['retained_channels']['count']==250
for cycle in range(1,6001):
 expected=[('detail key down','6a'),('detail key up','6b'),('detail wheel down','1b5b3c36353b353b354d'),('detail wheel up','1b5b3c36343b353b354d')]
 got=[(s['action'],s['input_hex']) for s in obs['samples'][6+(cycle-1)*4:6+cycle*4]]
 assert got==expected,(cycle,got)

assert obs['binary_sha256']==identity['manifest']['sha256']['masc_tui.exe']==c.digest(binary)
(out/'observation.json').write_text(json.dumps(obs,indent=2)+'\n')
profile_info.update({'binary_source':identity['manifest']['commit'],'runner_sha256':c.digest(Path(__file__)),'scenario_sha256':c.digest(Path(scenario.__file__)),'helper_sha256':c.digest(Path(h.__file__)),'transitions':len(obs['samples']),'sample_exit':profiler.returncode,'scope':'Native profile only: one roster cycle followed by 6000 alternating detail cycles; first detail precondition reconstructed, later opposite-window acknowledgements replace whole-history precondition reconstruction. Each new input still awaits its new expected window and FRAME_END. Sampling perturbs timings; not comparative latency evidence. No physical display/live runtime/deployment proof.'})
profile_info['interpretation'] = 'The inherited session_resources scope in the raw receipt is inapplicable here: it includes profiler, ps and pgrep CPU. Do not interpret it as TUI-only CPU. This is a sampled diagnostic, not a latency comparison.'
(out/'profile.json').write_text(json.dumps(profile_info,indent=2)+'\n')
print(json.dumps(profile_info),flush=True)

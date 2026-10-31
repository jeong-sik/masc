"""Inject receipt-write failures around real owned Keeper/model/reader processes."""
from pathlib import Path
import argparse
import hashlib
import json
import sys

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo',type=Path,required=True)
parser.add_argument('--binary',type=Path,required=True)
parser.add_argument('--tracers',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
repo=args.repo.resolve(strict=True)
target=args.output.resolve()
target.mkdir(parents=True,exist_ok=False)
sys.path.insert(0, str(repo / "scripts/harness/perf"))
import keeper_scale_session as session
import keeper_scale_trace as trace

root = repo / "artifacts/extreme-perf-20261030"
output = target / "owned-run"
session_write, trace_write = session.write_json, trace.write_json
cleanup = session.cleanup_failed_run
observations = {}

def fail_session_write(path, value):
    if path.name == "latency-samples.json":
        raise OSError("injected primary latency receipt write failure")
    return session_write(path, value)

def fail_trace_write(path, value):
    if path.name == "receipt.json":
        raise OSError("injected secondary trace receipt write failure")
    return trace_write(path, value)

def observe_cleanup(owner, args):
    errors = cleanup(owner, args)
    observations.update(
        cleanup_errors=errors,
        server_returncode=owner['process'].poll(),
        model_thread_stopped=not owner['model_thread'].is_alive(),
        model_socket_closed=owner['model'].fileno() == -1,
        sampler_stopped=not owner['sampler'].is_alive(),
        reader_returncodes=[reader.process.poll() for reader in owner['traces'].readers],
        provider_handlers=owner['fixture'].handler_count, active_provider_requests=owner['fixture'].active)
    return errors

original_tool = session.Client.tool
def fail_enqueue(self, name, arguments, phase):
    if phase == "settlement":
        raise session.ProbeError("injected first workload failure")
    return original_tool(self, name, arguments, phase)
session.Client.tool = fail_enqueue
session.write_json = fail_session_write
trace.write_json = fail_trace_write
session.cleanup_failed_run = observe_cleanup
sys.argv = [str(session.__file__), '--binary', str(args.binary.resolve(strict=True)),
            '--repo', str(repo), '--output', str(output), '--keepers', '2',
            '--model-delay-ms', '3600000', '--settle-timeout', '120', '--tracers', str(args.tracers.resolve(strict=True))]
try:
    session.main()
except session.ProbeError as error:
    observations['original_error'] = str(error)
else:
    raise AssertionError('injected write failure incorrectly succeeded')
assert observations['original_error'] == 'injected first workload failure'
assert observations['server_returncode'] == 0
assert all(observations[k] for k in ['model_thread_stopped','model_socket_closed','sampler_stopped'])
assert observations['reader_returncodes'] == [0,0]
assert observations['provider_handlers']==0 and observations['active_provider_requests']==0
assert any(row['stage']=='trace_finish' for row in observations['cleanup_errors'])
assert any(row['stage']=='run_finalization' for row in observations['cleanup_errors'])
observations.update(verdict='PASS', scope='Injected write failures with real isolated owned processes. Not performance evidence.',
                    tested_source_sha256={Path(module.__file__).name:hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest()
                                          for module in [session,trace]})
(target/'result.json').write_text(json.dumps(observations,indent=2)+'\n')
print(json.dumps(observations))

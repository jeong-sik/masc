"""Exercise contamination and identity boundaries, without a TUI or server."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from qualify import qualify_arm


def main():
    if not __debug__:
        raise RuntimeError('Boundary validation requires assertions enabled')
    here = Path(__file__).resolve().parent
    matrix = here.parent / 'keeper-list-matched-v1'
    config = json.loads((here / 'config-v2.json').read_text())
    execution = json.loads((matrix / 'execution.json').read_text())['records'][0]
    original = matrix / 'runs' / 'owners-2-control'
    spec = config['variants']['control']
    checks = []
    with tempfile.TemporaryDirectory(prefix='keeper-matrix-boundary-') as name:
        root = Path(name)
        case = root / 'case'
        (case / 'tui-observer').mkdir(parents=True)
        files = ['cleanup.json', 'identity.json', 'owned-process.json', 'summary.json',
                 'tui-observer/observation.json', 'tui-observer/frame-timing.txt',
                 'keeper_scale_session.py', 'keeper_scale_trace.py', 'tui_observer.py']
        for filename in files:
            shutil.copyfile(original / filename, case / filename)
        assert qualify_arm(case, execution, spec)['eligible']
        mixed = dict(execution, command=list(execution['command']))
        mixed['command'][mixed['command'].index('--output')+1] = '/other-arm/owners-2-control'
        assert not qualify_arm(case, mixed, spec)['cleanup_ok']
        checks.append('internally matching receipts must bind to original execution output')

        def reject(label, filename, change, cleanup_expected):
            path = case / filename
            before = path.read_bytes() if path.exists() else None
            value = json.loads(before) if before else {}
            replacement = change(value)
            if replacement is None:
                path.unlink()
            else:
                path.write_text(json.dumps(replacement))
            actual = qualify_arm(case, execution, spec)
            assert actual['eligible'] is False, label
            assert actual['cleanup_ok'] is cleanup_expected, label
            checks.append(label)
            if before is None:
                path.unlink()
            else:
                path.write_bytes(before)

        reject('missing main cleanup', 'cleanup.json', lambda _: None, False)
        reject('unreaped server', 'cleanup.json', lambda x: dict(x, server_reaped=False), False)
        reject('provider still active', 'cleanup.json', lambda x: dict(x, active_provider_requests=1), False)
        reject('provider handler still active', 'cleanup.json', lambda x: dict(x, provider_handler_threads=1), False)
        reject('foreign cleanup base rejected', 'cleanup.json', lambda x: dict(x, base_path='/another-owned-base'), False)
        reject('HTTP sampler unknown', 'cleanup.json', lambda x: {k:v for k,v in x.items() if k != 'sampler_stopped'}, False)
        reject('boolean is not an integer count', 'cleanup.json', lambda x: dict(x, active_provider_requests=False), False)
        reject('fallback cleanup error', 'fallback-cleanup.json', lambda _: {'cleanup_errors':['failed to reap']}, False)
        reject('failure cleanup error', 'failure.json', lambda _: {'cleanup_errors':['provider thread unknown']}, False)
        reject('empty failure receipt', 'failure.json', lambda _: {}, False)
        reject('empty fallback receipt', 'fallback-cleanup.json', lambda _: {}, False)
        reject('success cannot contain a fallback receipt', 'fallback-cleanup.json',
               lambda _: {'server_reaped':True,'server_returncode':0,'model_server_stopped':True,'cleanup_errors':[]}, False)
        reject('success cannot contain a failure receipt', 'failure.json',
               lambda _: {'type':'ProbeError','message':'fixture','cleanup_errors':[]}, False)
        reject('wrong server source', 'identity.json', lambda x: dict(x, source='0'*40), True)
        reject('wrong TUI digest', 'tui-observer/observation.json', lambda x: dict(x, binary_sha256_after='0'*64), True)
        reject('workload failure stays distinct from cleanup', 'summary.json', lambda x: dict(x, succeeded_operations=0), True)
        invalid_spec = {k:None for k in spec}
        assert not qualify_arm(case, execution, invalid_spec)['next_arm_safe']
        checks.append('null expected pins rejected')
        rejected = qualify_arm(case, dict(execution, returncode=1), spec)
        assert not rejected['next_arm_safe']
        checks.append('nonzero child without final failure receipts rejected')
        (case / 'failure.json').write_text(json.dumps({'type':'ProbeError','message':'fixture','cleanup_errors':[]}))
        (case / 'fallback-cleanup.json').write_text(json.dumps({'server_reaped':True,'server_returncode':0,'model_server_stopped':True,'cleanup_errors':[], 'base_path':json.loads((case/'identity.json').read_text())['base']}))
        rejected = qualify_arm(case, dict(execution, returncode=1), spec)
        assert not rejected['eligible'] and rejected['next_arm_safe']
        checks.append('clean workload failure remains safe to continue')
        (case / 'failure.json').unlink()
        (case / 'fallback-cleanup.json').unlink()
        path = case / 'tui-observer/frame-timing.txt'
        before = path.read_bytes()
        path.write_text('')
        assert not qualify_arm(case, execution, spec)['eligible']
        checks.append('no raw list Build')
        path.write_bytes(before)
        path.write_bytes(before[:before.rfind(b'\n', 0, len(before)-1)+1])
        assert not qualify_arm(case, execution, spec)['eligible']
        checks.append('line-boundary truncated native report rejected')
        path.write_bytes(before)
        (case / 'fallback-cleanup.json').write_text('{invalid')
        assert not qualify_arm(case, execution, spec)['cleanup_ok']
        checks.append('unreadable optional cleanup receipt')
        (case / 'fallback-cleanup.json').unlink()
        # A fallback alone lacks the authoritative sampler/provider drain fields.
        shutil.copyfile(case / 'cleanup.json', root / 'main-cleanup.json')
        (case / 'cleanup.json').unlink()
        (case / 'fallback-cleanup.json').write_text(json.dumps({'server_reaped':True, 'server_returncode':0, 'model_server_stopped':True, 'cleanup_errors':[]}))
        assert not qualify_arm(case, execution, spec)['cleanup_ok']
        checks.append('fallback cannot replace main cleanup')

        # Run the actual v2 controller against an owned child fixture.
        child = root / 'child.py'
        log = root / 'children.jsonl'
        mode = root / 'mode'
        spec_file = root / 'spec.json'
        child.write_text('import pathlib,sys,json,shutil\n'
                         f'with pathlib.Path({str(log)!r}).open("a") as f: f.write("child\\n")\n'
                         'p=pathlib.Path(sys.argv[sys.argv.index("--output")+1]);p.mkdir(parents=True)\n'
                         '(p/"tui-observer").mkdir()\n'
                         f'original=pathlib.Path({str(original)!r})\n'
                         f'files={files!r}\n'
                         'for name in files: shutil.copyfile(original/name,p/name)\n'
                         f'spec=json.loads(pathlib.Path({str(spec_file)!r}).read_text())\n'
                         'identity=json.loads((p/"identity.json").read_text());identity.update(base=str(p/"owned-base"),sha256=spec["server_sha256"],runner_sha256=spec["runner_sha256"],observer_sha256=spec["observer_sha256"],runtime_fixture_sha256=spec["runtime_fixture_sha256"])\n'
                         '(p/"identity.json").write_text(json.dumps(identity))\n'
                         'owned=json.loads((p/"owned-process.json").read_text());owned.update(base=identity["base"],binary_sha256=spec["server_sha256"]);(p/"owned-process.json").write_text(json.dumps(owned))\n'
                         'cleanup=json.loads((p/"cleanup.json").read_text());cleanup["base_path"]=identity["base"];(p/"cleanup.json").write_text(json.dumps(cleanup))\n'
                         'o=json.loads((p/"tui-observer/observation.json").read_text());o.update(binary_sha256=spec["tui_sha256"],binary_sha256_after=spec["tui_sha256"],observer_source_sha256=spec["observer_sha256"])\n'
                         'for when in ("server_before","server_after"): o[when]["build"]["executable_sha256"]=spec["server_sha256"];o[when]["paths"]["effective_base_path"]=identity["base"]\n'
                         '(p/"tui-observer/observation.json").write_text(json.dumps(o))\n'
                         'for name,src in (("keeper_scale_session.py",__file__),("tui_observer.py",str(pathlib.Path(__file__).parent/"tui_observer.py")),("keeper_scale_trace.py",str(pathlib.Path(__file__).parent/"keeper_scale_trace.py"))): shutil.copyfile(src,p/name)\n'
                         f'mode=pathlib.Path({str(mode)!r}).read_text()\n'
                         'if mode=="bad": (p/"cleanup.json").write_text(json.dumps({"server_reaped":False}))\n'
                         'else:\n'
                         ' (p/"summary.json").write_text(json.dumps({"keepers":30,"messages":60,"succeeded_operations":0}))\n'
                         ' (p/"failure.json").write_text(json.dumps({"type":"ProbeError","message":"fixture failure","cleanup_errors":[]}))\n'
                         ' (p/"fallback-cleanup.json").write_text(json.dumps({"server_reaped":True,"server_returncode":0,"model_server_stopped":True,"cleanup_errors":[],"base_path":identity["base"]}))\n'
                         ' sys.exit(1)\n')
        h = hashlib.sha256(child.read_bytes()).hexdigest()
        (root/'keeper_scale_trace.py').write_bytes(child.read_bytes())
        shutil.copyfile(original/'tui_observer.py', root/'tui_observer.py')
        fixture = root/'scripts/fixtures/release-evidence/runtime.toml'
        fixture.parent.mkdir(parents=True)
        fixture.write_bytes(child.read_bytes())
        fake_spec = dict(spec, server=str(child), tui=str(child), server_sha256=h, tui_sha256=h,
                         runner_sha256=h, observer_sha256=spec['observer_sha256'], trace_sha256=h, runtime_fixture_sha256=h)
        spec_file.write_text(json.dumps(fake_spec))
        fake = dict(config, repo=str(root), variants={'control':fake_spec}, plan=[[30,'control'],[300,'control']],
                    probe={'runner':str(child),'observer':str(child),'runtime_fixture':str(child)})
        cfg = root / 'config.json'
        cfg.write_text(json.dumps(fake))
        mode.write_text('bad')
        result = subprocess.run([sys.executable, str(here/'run.py'), '--config', str(cfg),
                                 '--output', str(root/'output')], capture_output=True, text=True)
        assert result.returncode == 1 and log.read_text().splitlines() == ['child'], result.stderr
        checks.append('prospective bad-cleanup boundary prevents second child')
        log.unlink()
        mode.write_text('clean')
        result = subprocess.run([sys.executable, str(here/'run.py'), '--config', str(cfg),
                                 '--output', str(root/'clean-output')], capture_output=True, text=True)
        assert result.returncode == 1 and log.read_text().splitlines() == ['child','child'], result.stderr
        checks.append('prospective clean workload failure continues but final result fails')
        log.unlink()
        fake['plan'] = [[2,'control'],[30,'control']]
        cfg.write_text(json.dumps(fake))
        result = subprocess.run([sys.executable, str(here/'run.py'), '--config', str(cfg),
                                 '--output', str(root/'small-failure-output')], capture_output=True, text=True)
        assert result.returncode == 1 and log.read_text().splitlines() == ['child'], result.stderr
        checks.append('two-owner qualification failure prevents expansion')
    value = {'scope':'One-off resource/identity boundary validation; no UI layout, text, row-order, runtime speed or matrix rerun.',
             'passed':True, 'python_optimization':sys.flags.optimize, 'checks':checks}
    with (here / 'boundary-validation-v6.json').open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


if __name__ == '__main__':
    main()

from pathlib import Path
import os, tempfile, subprocess, json, hashlib
binary=Path('/tmp/skill-refresh-native-3cb/runtime/masc-macos-arm64')
root=Path(tempfile.mkdtemp(prefix='skill-native-3cb-'))
results=[]
def run(label,base,*args,ok=True):
 base.mkdir(exist_ok=True)
 p=subprocess.run([str(binary),*args,'--base-path',str(base)],capture_output=True,text=True,timeout=30)
 results.append(dict(label=label,args=list(args),base=str(base),exit=p.returncode,stdout=p.stdout,stderr=p.stderr))
 assert (p.returncode==0)==ok,results[-1]
 return p.stdout
try:
 base=root/'config'
 run('config-only',base,'init','--config-only')
 assert (base/'.masc/config/runtime.toml').is_file()
 assert not (base/'.masc/skills').exists()
 run('skills-only',base,'init','--skills-only')
 package=base/'.masc/skills/browser-lanes'
 assert (package/'SKILL.md').is_file()
 inspect=run('review before linking',base,'skills-refresh','browser-lanes')
 revisions={line.split(': ',1)[0]:line.split(': ',1)[1] for line in inspect.splitlines() if ': ' in line}
 resource=next(p for p in package.rglob('*') if p.is_file() and p.name!='SKILL.md')
 linked=base/'external-resource'; linked.write_bytes(resource.read_bytes()); linked.chmod(resource.stat().st_mode & 0o777)
 resource.unlink();os.link(linked,resource)
 receipt=base/'.masc/skill-packages/browser-lanes.sha256'; before=receipt.read_bytes()
 run('automatic linked resource preservation',base,'init','--skills-only')
 run('explicit linked resource rejection',base,'skills-refresh','browser-lanes','--apply','--expected-revision',revisions['installed revision'],'--expected-bundle-revision',revisions['bundled revision'],ok=False)
 assert resource.stat().st_ino==linked.stat().st_ino and receipt.read_bytes()==before
 for flags in [('--config-only','--skills-only'),('--skills-only','--config-only')]:
  fresh=root/('exclusive-'+flags[0][2:]);run('exclusive flags',fresh,'init',*flags,ok=False)
  assert not (fresh/'.masc').exists()
 for kind in ['directory','symlink']:
  fresh=root/('receipt-'+kind);fresh.mkdir();state=fresh/'.masc/skill-packages';state.mkdir(parents=True)
  receipt=state/'browser-lanes.sha256';target=fresh/'external';target.write_text('unchanged')
  if kind=='directory':receipt.mkdir()
  else:receipt.symlink_to(target)
  run('invalid '+kind+' receipt',fresh,'init','--skills-only')
  assert not (fresh/'.masc/skills/browser-lanes').exists() and target.read_text()=='unchanged'
  assert receipt.is_dir() if kind=='directory' else receipt.is_symlink()
finally:
 proof={'source_commit':'3cb88d90afcb6cf1d2a310155df3483ab7db6e05','binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'results':results}
 (root/'proof.json').write_text(json.dumps(proof,indent=2));print(root/'proof.json')

from pathlib import Path
import subprocess,json,tempfile,hashlib,sys
wd=Path(sys.argv[1]).resolve();root=Path(sys.argv[2]).resolve();out=Path(tempfile.mkdtemp(prefix='masc-metrics-boot-native-'));Path('/tmp/masc-metrics-boot-native-dir').write_text(str(out))
paths=list((root/'_build/default/lib').glob('**/*.cmx'))+list((root/'_build/default/packages').glob('**/*.cmx'))
index={p.stem[0].upper()+p.stem[1:]:p for p in paths if '/native/' in str(p)}
objects=[];visited=set();objinfo=['opam','exec','--switch=5.5.1','--','ocamlobjinfo']
def visit(name):
 if name in visited:return
 visited.add(name)
 if name not in index:return
 p=index[name];raw=subprocess.check_output(objinfo+[str(p)],text=True)
 imported=raw.split('Implementations imported:\n',1)[1].split('Clambda approximation:',1)[0]
 for line in imported.splitlines():
  words=line.split()
  if len(words)==2:visit(words[1])
 objects.append(p)
for name in ['Fs_compat_internal','Keeper_runtime_config']:visit(name)
fsdir=Path(sys.argv[3]).resolve()/'candidate'
incs=[]
for p in objects:
 for d in [p.parent,p.parent.parent/'byte']:
  if d not in incs:incs.append(d)
packages='yojson,uuidm,eio_main,mcp_protocol.eio,digestif.c,ipaddr,ptime,re,uri,cstruct,fmt,fpath,otoml,ppx_inline_test.config,ppx_inline_test.runtime-lib,ppx_deriving.show'
cmd=['opam','exec','--switch=5.5.1','--','ocamlfind','ocamlopt','-opaque','-thread','-package',packages,'-I',str(out),'-I',str(fsdir)]+[v for d in incs for v in ['-I',str(d)]]
def run(args):
 p=subprocess.run(args,cwd=out,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if p.returncode:
  (out/'failure.txt').write_text(p.stdout);raise RuntimeError(p.stdout[-3000:])
 return p.stdout
units=['lib/config/env_config_keeper_supervisor','lib/config/env_config_keeper','lib/config/keeper_runtime_setting_registry','lib/keeper_runtime/keeper_runtime_config']
for unit in units:
 for ext in ['mli','ml']:
  path=out/(Path(unit).name+'.'+ext);path.write_bytes((wd/(unit+'.'+ext)).read_bytes());run(cmd+['-c',str(path)])
source=(wd/'lib/keeper/keeper_types_support.ml').read_text();source=source[source.index('let metrics_backup_number'):]
repair=(wd/'lib/keeper/keeper_config_text.ml').read_text();repair=repair[repair.index('let utf8_repair_string'):]
(out/'rotation_support.ml').write_text('module Fs_compat = Rotation_fs_compat\nmodule Env_config = struct module KeeperMetrics = Env_config_keeper.KeeperMetrics end\n'+repair+'\n'+source);run(cmd+['-c','rotation_support.ml'])
probe=r'''let () =
 let bytes_env="MASC_KEEPER_METRICS_MAX_BYTES" and count_env="MASC_KEEPER_METRICS_MAX_ROTATED" in
 List.iter Unix.unsetenv ["MASC_CONFIG_DIR";"MASC_PARSE_WARN";bytes_env;count_env];
 let base_path=Sys.argv.(1) in
 let config_dir=Filename.concat base_path ".masc/config" in Fs_compat.mkdir_p config_dir;
 Fs_compat.save_file (Filename.concat config_dir "runtime.toml") "[metrics]\nmax_bytes=17\nmax_rotated=0\n";
 let load expected=Config_boot_overrides.reset_for_tests (); match Keeper_runtime_config.load_and_apply ~base_path with
 | Ok count when count=expected -> ()
 | Ok count -> failwith (Printf.sprintf "expected %d settings, got %d" expected count)
 | Error e->failwith(Keeper_runtime_config.load_failure_to_string e) in
 let setting key=match Keeper_runtime_setting_registry.find_by_toml_key key with Some x->x|None->failwith key in
 load 2;
 assert(Keeper_runtime_setting_registry.effective_value (setting "metrics.max_rotated")="0");
 assert(Keeper_runtime_setting_registry.effective_value (setting "metrics.max_bytes")="17");
 let path=Filename.concat base_path "auxiliary.jsonl" in
 Fs_compat.save_file path (String.make 17 'x');Fs_compat.save_file (path^".1") "old";
 Rotation_support.append_jsonl_line path (`Assoc["new",`Bool true]);
 assert(not(Sys.file_exists(path^".1")));assert(Fs_compat.load_file path="{\"new\":true}\n");
 print_endline "PASS TOML zero retention: two applied settings, matching effective values and no backups after actual append";
 Unix.putenv count_env "2"; load 1;
 assert(Keeper_runtime_setting_registry.effective_value(setting "metrics.max_rotated")="2");
 Fs_compat.save_file path (String.make 17 'y');Fs_compat.save_file (path^".1") "keep me";Fs_compat.save_file(path^".3")"excess";
 Rotation_support.append_jsonl_line path (`Null);
 assert(Fs_compat.load_file(path^".1")=String.make 17 'y');assert(Fs_compat.load_file(path^".2")="keep me");
 assert(not(Sys.file_exists(path^".3")));assert(Fs_compat.load_file path="null\n");
 print_endline "PASS env precedence: effective two backups, current rotated, prior backup shifted and excess pruned";
 Unix.unsetenv count_env;
 Fs_compat.save_file (Filename.concat config_dir "runtime.toml") "[metrics]\nmax_rotated=-1\n";
 Config_boot_overrides.reset_for_tests ();
 (match Keeper_runtime_config.load_and_apply ~base_path with Error {kind=Validate;_}->()|_->failwith "negative retention accepted");
 print_endline "PASS negative TOML retention: rejected by boot validation";
 Yojson.Safe.to_file "settings-schema.json" (Keeper_runtime_setting_registry.schema_to_yojson ())
'''
(out/'probe.ml').write_text(probe)
names={Path(p).name for p in units};linked=[out/p.name if p.stem in names else p for p in objects]
stubs=list((root/'_build/default/lib').glob('**/lib*stubs.a'))
run(cmd+['-linkpkg']+list(map(str,linked))+[str(fsdir/'rotation_fs_compat.cmx'),'rotation_support.cmx','probe.ml','-o','test_metrics_boot.exe']+[v for p in stubs for v in ['-cclib',str(p)]])
workspace=out/'workspace';workspace.mkdir()
report=run([str(out/'test_metrics_boot.exe'),str(workspace)]);(out/'results.txt').write_text(report);print(report)
files=[u+'.'+ext for u in units for ext in ['mli','ml']]+['lib/fs_compat/fs_compat.ml','lib/fs_compat/fs_compat.mli','lib/keeper/keeper_types_support.ml']
(out/'manifest.json').write_text(json.dumps({'scope':'native real boot loader and registry, exact JSONL writer source, full isolated Fs_compat and cached dependencies; temporary filesystem only; no full server','source_sha256':{p:hashlib.sha256((wd/p).read_bytes()).hexdigest() for p in files}},indent=2)+'\n');print(out)

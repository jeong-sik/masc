from pathlib import Path
import subprocess,json,tempfile,hashlib,sys
wd=Path(sys.argv[1]).resolve();root=Path(sys.argv[2]).resolve();out=Path(tempfile.mkdtemp(prefix='masc-dated-metrics-boot-'));Path('/tmp/masc-dated-metrics-boot-dir').write_text(str(out))
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
for name in ['Fs_compat_internal','Dated_jsonl','Keeper_runtime_config']:visit(name)
fsdir=Path(sys.argv[3]).resolve()
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
probe=r'''let () = Eio_main.run @@ fun env ->
 Fs_compat.set_fs (Eio.Stdenv.fs env);
 let store_env="MASC_KEEPER_METRICS_STORE_MAX_BYTES" in
 List.iter Unix.unsetenv ["MASC_CONFIG_DIR";"MASC_PARSE_WARN";store_env];
 Config_boot_overrides.reset_for_tests ();
 let base_path=Sys.argv.(1) in
 let config_dir=Filename.concat base_path ".masc/config" in Fs_compat.mkdir_p config_dir;
 let file=Filename.concat config_dir "runtime.toml" in
 let row i=`Assoc["i",`Int i] in
 let row_bytes=String.length(Yojson.Safe.to_string(row 1))+1 in
 let load expected=Config_boot_overrides.reset_for_tests ();match Keeper_runtime_config.load_and_apply ~base_path with
 | Ok n when n=expected->()|Ok n->failwith(Printf.sprintf "expected %d overrides, got %d" expected n)
 | Error e->failwith(Keeper_runtime_config.load_failure_to_string e) in
 let setting=match Keeper_runtime_setting_registry.find_by_toml_key "metrics.store_max_bytes" with
 | Some setting->setting|None->failwith "missing store setting" in
 let open_store name=Keeper_metrics_storage.create ~base_dir:(Filename.concat base_path name)
  ~max_bytes:(Env_config_keeper.KeeperMetrics.store_max_bytes ()) in
 let values s=Dated_jsonl.read_recent(Keeper_metrics_storage.read_store s)100
  |>List.map(fun j->Yojson.Safe.Util.(j|>member "i"|>to_int)) in
 load 0;assert(Keeper_runtime_setting_registry.effective_value setting="0");
 let unlimited=open_store "unlimited" in
 List.iter(fun i->Keeper_metrics_storage.append unlimited(row i))[1;2;3;4];
 assert(values unlimited=[1;2;3;4]);print_endline "PASS absent setting keeps all dated metrics";
 Fs_compat.save_file file(Printf.sprintf "[metrics]\nstore_max_bytes=%d\n"(2*row_bytes));load 1;
 assert(Keeper_runtime_setting_registry.effective_value setting=string_of_int(2*row_bytes));
 let bounded=open_store "bounded" in
 List.iter(fun i->Keeper_metrics_storage.append bounded(row i))[1;2;3;4];
 assert(values bounded=[3;4]);print_endline "PASS TOML target reaches actual dated rotation, pruning and reading";
 Unix.putenv store_env "0";load 0;assert(Keeper_runtime_setting_registry.effective_value setting="0");
 let override=open_store "override" in
 List.iter(fun i->Keeper_metrics_storage.append override(row i))[1;2;3;4];
 assert(values override=[1;2;3;4]);print_endline "PASS process environment overrides TOML and disables cleanup";
 Unix.unsetenv store_env;Fs_compat.save_file file "[metrics]\nstore_max_bytes=-1\n";
 Config_boot_overrides.reset_for_tests ();
 (match Keeper_runtime_config.load_and_apply ~base_path with Error{kind=Validate;_}->()|_->failwith "negative target accepted");
 print_endline "PASS negative TOML target is rejected at boot";
 Yojson.Safe.to_file "settings-schema.json"(Keeper_runtime_setting_registry.schema_to_yojson ())
'''
(out/'probe.ml').write_text(probe)
names={Path(p).name for p in units};linked=[out/p.name if p.stem in names else fsdir/p.name if p.stem=='dated_jsonl' else p for p in objects]
stubs=list((root/'_build/default/lib').glob('**/lib*stubs.a'))
run(cmd+['-linkpkg']+list(map(str,linked))+[str(fsdir/'keeper_metrics_storage.cmx'),'probe.ml','-o','test_metrics_boot.exe']+[v for p in stubs for v in ['-cclib',str(p)]])
workspace=out/'workspace';workspace.mkdir()
report=run([str(out/'test_metrics_boot.exe'),str(workspace)]);(out/'results.txt').write_text(report);print(report)
files=[u+'.'+ext for u in units for ext in ['mli','ml']]+['lib/dated_jsonl/dated_jsonl.ml','lib/dated_jsonl/dated_jsonl.mli','lib/keeper/keeper_metrics_storage.ml','lib/keeper/keeper_metrics_storage.mli']
(out/'manifest.json').write_text(json.dumps({'scope':'native real boot loader and registry, full dated metric storage owner and Dated_jsonl with cached lower dependencies; temporary filesystem only; no full server or Keeper factory execution','source_sha256':{p:hashlib.sha256((wd/p).read_bytes()).hexdigest() for p in files}},indent=2)+'\n');print(out)

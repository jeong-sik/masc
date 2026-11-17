import argparse,hashlib,json,os,re,subprocess,tempfile
from pathlib import Path
parser=argparse.ArgumentParser()
for option in ['repo','base','opam-prefix','build-root','typing-prefix','out']:
 parser.add_argument('--'+option,required=True)
args=parser.parse_args()
ROOT,OPAM,BUILD,OUT=[Path(value).resolve() for value in [args.repo,args.opam_prefix,args.build_root,args.out]]
OUT.mkdir(parents=True,exist_ok=False)
ENV=dict(os.environ,PATH=str(OPAM/'bin')+os.pathsep+os.environ['PATH'],GIT_NO_LAZY_FETCH='1')
hashes={}
exits={}
def source(path,before=False):
 data=subprocess.check_output(['git','-C',str(ROOT),'show',args.base+':'+path]) if before else (ROOT/path).read_bytes()
 hashes[('baseline:' if before else 'candidate:')+path]=hashlib.sha256(data).hexdigest();return data.decode()
def run(argv,label,cwd=OUT,check=True):
 done=subprocess.run(list(map(str,argv)),cwd=cwd,env=ENV,capture_output=True,text=True)
 (OUT/(label+'.stdout')).write_text(done.stdout);(OUT/(label+'.stderr')).write_text(done.stderr)
 exits[label]=done.returncode
 if check and done.returncode:raise RuntimeError(label+': '+done.stderr[-4000:])
 return done.stdout
version=run([OPAM/'bin/ocamlopt','-version'],'version').strip()
if version!='5.5.2':raise RuntimeError('expected OCaml5.5.2')
prefix_file=Path(args.typing_prefix);prefix=json.loads(prefix_file.read_text());prefix[0]=str(OPAM/'bin/ocamlopt')
typing=OUT/'actual-typing';typing.mkdir();prefix[prefix.index('-I')+1]=str(typing)
typing_checks=[]
for extension in ['mli','ml']:
 path='lib/runtime/runtime_model_input_tail_window.'+extension
 text=source(path);local=typing/Path(path).name;local.write_text(text)
 run(prefix+['-thread','-c',local.name],'typing-window-'+extension,typing)
 typing_checks.append({'path':path,'sha256':hashlib.sha256(text.encode()).hexdigest(),'exit_code':0})
testpath='test/test_runtime_model_input_tail_window.ml';testsource=source(testpath)
(typing/Path(testpath).name).write_text(testsource)
run(prefix+['-thread','-stop-after','typing','-c',Path(testpath).name],'typing-test',typing,check=False)
before_test=source(testpath,True);(typing/'baseline_test.ml').write_text(before_test)
run(prefix+['-thread','-stop-after','typing','-c','baseline_test.ml'],'typing-baseline-test',typing,check=False)
typing_checks.append({'path':testpath,'sha256':hashlib.sha256(testsource.encode()).hexdigest(),'exit_code':exits['typing-test'],'baseline_exit_code':exits['typing-baseline-test'],'stage':'typing','limit':'Existing whole test source warning4 patterns fail fatal typing; native test modules suppress only warning4.'})
probe='let before_tests=ref 0\nlet after_tests=ref 0\n'
for label,before in [('Before',True),('After',False)]:
 mli=source('lib/runtime/runtime_model_input_tail_window.mli',before)
 ml=source('lib/runtime/runtime_model_input_tail_window.ml',before)
 probe+='module '+label+':sig\n'+mli+'\nend=struct\n'+ml+'\nend\n'
for label,before,counter in [('Before',True,'before_tests'),('After',False,'after_tests')]:
 tests=source(testpath,before)
 probe+='module '+label+'_tests=struct\n[@@@warning \"-4\"]\nmodule Runtime_model_input_tail_window='+label+'\n'
 probe+='module Alcotest=struct\ninclude Alcotest\nlet run _ groups=List.iter(fun(_,tests)->List.iter(fun(_,_,test)->incr '+counter+';test())tests)groups\nend\n'+tests+'\nend\n'
regression='let test_opening_index_counts_atoms_and_defers_encoding () ='+testsource.split('let test_opening_index_counts_atoms_and_defers_encoding () =',1)[1].split(';;',1)[0]+';;\n'
probe+='module Exact_new_regression=struct\nmodule Window=After\nmodule Types=Agent_core.Types\nlet user=After_tests.user\nlet assistant=After_tests.assistant\nlet tool=After_tests.tool\nlet message=After_tests.message\nlet extra_context=After_tests.extra_context\n'+regression+'let ()=test_opening_index_counts_atoms_and_defers_encoding ()\nend\n'
cases=Path(__file__).with_name('core_cases.ml').read_text();probe+=cases
(OUT/'probe.ml').write_text(probe)
packages='digestif.c,str,base64,ipaddr,domain-name,http,cohttp,cohttp-eio,tls,tls-eio,ca-certs,ppx_inline_test.runtime-lib,ppx_inline_test.config,yojson,ptime,re,eio_main,mcp_protocol.eio,mirage-crypto-rng.unix,uuidm,otoml,ppx_deriving_yojson.runtime,ppx_deriving.runtime,alcotest'
native_flags=prefix[1:].copy();native_flags[native_flags.index('-I')+1]=str(OUT)
command=[OPAM/'bin/ocamlfind','ocamlopt','-thread','-package',packages,*native_flags]
run(command+['-c',OUT/'probe.ml'],'compile')
def imports(path,label):
 text=run([OPAM/'bin/ocamlobjinfo','-no-approx','-no-code',path],label)
 return re.findall(r'\s+(?:[0-9a-f]{32}|-{32})\s+(\S+)',text.split('Implementations imported:\n',1)[1].split('Clambda unit',1)[0])
def production(path):
 rel=path.relative_to(BUILD);return rel.parts[0] in ['lib','packages','proto','ppx_tla'] and not any(x in ['test','tests','bin'] for x in rel.parts)
objects={}
for path in sorted(BUILD.rglob('*.cmx')):
 if production(path):objects.setdefault(path.stem.lower(),path)
graph={}
def visit(name):
 key=name.lower()
 if key in graph or key not in objects:return
 path=objects[key];directory=path.parent.parent;library=directory.parent/(directory.name.removeprefix('.').removesuffix('.objs')+'.cmxa')
 if not library.is_file():raise RuntimeError('missing existing archive '+str(library))
 deps=imports(path,'objinfo-'+key);graph[key]=(library,deps)
 for dependency in deps:visit(dependency)
for name in imports(OUT/'probe.cmx','objinfo-probe'):visit(name)
dependencies={library:set() for library,_ in graph.values()}
for library,deps in graph.values():
 for dependency in deps:
  item=graph.get(dependency.lower())
  if item and item[0]!=library:dependencies[library].add(item[0])
libraries=[];active=set()
def order(library):
 if library in libraries:return
 if library in active:raise RuntimeError('archive cycle')
 active.add(library)
 for dependency in sorted(dependencies[library]):order(dependency)
 active.remove(library);libraries.append(library)
for library in sorted(dependencies):order(library)
run(command+['-linkpkg',*[x for library in libraries for x in ['-I',library.parent]],*libraries,OUT/'probe.cmx','-o',OUT/'probe'],'link')
with tempfile.TemporaryDirectory(dir=OUT) as directory:
 ENV=dict(ENV,MASC_BASE_PATH=directory,MASC_CONFIG_DIR=directory+'/config');Path(directory+'/config').mkdir()
 output=run([OUT/'probe'],'native')
receipt={'base':args.base,'compiler':version,'source_sha256':hashes,'actual_typing':typing_checks,'fatal_warnings':[4,8,32,69],
 'results':json.loads(output.strip().splitlines()[-1]),'typing_prefix_sha256':hashlib.sha256(prefix_file.read_bytes()).hexdigest(),
 'helper_sha256':{path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in [Path(__file__),Path(__file__).with_name('core_cases.ml')]},
 'probe_sha256':hashlib.sha256(probe.encode()).hexdigest(),'exact_new_regression_sha256':hashlib.sha256(regression.encode()).hexdigest(),'exact_new_regression_fatal_warnings':[4,8,32,69],'exact_new_regression_cases_executed':1,
 'archives':[{'path':str(path.relative_to(BUILD)),'sha256':hashlib.sha256(path.read_bytes()).hexdigest()} for path in libraries],
 'limits':['Complete actual baseline/candidate Window source and interfaces compiled as nested modules; existing actual focused test source executed with only Alcotest runner scheduling port.','Whole current Window ML/MLI and test typed against prebuilt dependencies; no exact-head dependency archive build receipt or full product build.','Synthetic construction-only alternating allocation/CPU/wall; full-major GC only in standalone fixture, no runtime/provider/queue/storage access.']}
(OUT/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'typing_checks':len(typing_checks),'oracle_checks':receipt['results']['oracle_checks'],'baseline_tests':receipt['results']['existing_baseline_tests'],'candidate_tests':receipt['results']['existing_candidate_tests']}))

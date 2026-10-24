from pathlib import Path
import re,subprocess,tempfile,json,hashlib
# Reproduce only the recorded pre-fix commit, never the current checkout.
BASE = 'd587bf1ffa123a05ae688cbc9fabe8e35221b206'
root = Path(__file__).resolve().parents[3]
lib = 'packages/agent_core/lib/llm_provider'
def source(name, ext):
 return subprocess.check_output(['git','show',f'{BASE}:{lib}/{name}.{ext}'],cwd=root)
with tempfile.TemporaryDirectory(prefix='masc-manifest-before-') as d:
 d=Path(d)
 for name in ['model_identifiers','capability_vocab','reasoning_effort','capability_manifest']:
  for ext in ['mli','ml']:
   text=source(name,ext).decode()
   text=re.sub(r'^let%test\b.*?^;;\n','',text,flags=re.M|re.S)
   (d/f'{name}.{ext}').write_text(text)
 (d/'probe.ml').write_text('''let () =
   let item enabled = `Assoc ["id_prefix",`String "Duplicate";"supports_tools",`Bool enabled] in
   let observe models = match Capability_manifest.of_json (`Assoc ["schema_version",`Int 1;"models",`List models]) with
     | Error detail -> `String detail
     | Ok manifest -> match Capability_manifest.lookup manifest (Model_identifiers.Model_id.of_string_exn "duplicate-v1") with
       | Some entry -> (match entry.supports_tools with Some value -> `Bool value | None -> `Null)
       | None -> `Null in
   print_endline (Yojson.Safe.to_string (`Assoc ["forward",observe [item true;item false];"reverse",observe [item false;item true]]))
 ''')
 subprocess.run(['ocamlfind','ocamlc','-package','yojson','-linkpkg','model_identifiers.mli','model_identifiers.ml','capability_vocab.mli','capability_vocab.ml','reasoning_effort.mli','reasoning_effort.ml','capability_manifest.mli','capability_manifest.ml','probe.ml','-o','probe'],cwd=d,check=True)
 result=json.loads(subprocess.check_output([str(d/'probe')],text=True))
 print(json.dumps({'base':BASE,'result':result,'sources':{name:hashlib.sha256(source(name,'ml')).hexdigest() for name in ['model_identifiers','capability_vocab','reasoning_effort','capability_manifest']}},indent=2))
 assert result == {'forward':True,'reverse':False}

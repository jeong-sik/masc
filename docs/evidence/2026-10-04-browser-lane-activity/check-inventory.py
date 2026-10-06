import hashlib,json,pathlib,shutil,subprocess,tempfile
root=pathlib.Path.cwd(); out=pathlib.Path(tempfile.mkdtemp(prefix='masc-browser-inventory-isolated-')); provenance={}
def put(name,text): (out/name).write_text(text)
def copy(path,name=None):
 p=root/path; name=name or p.name; shutil.copyfile(p,out/name); provenance[name]={'source':path,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
def extract(path,start,end):
 s=(root/path).read_text(); return s[s.index(start):s.index(end,s.index(start))]
for p in ['lib/runtime/standalone_lane.ml','lib/lane_registry/machine_lane.ml','lib/browser_lane/browser_lane_name.ml','lib/lane_registry/declaration_file.ml','lib/lane_registry/lane_id.ml','lib/shared_types/json_kind.ml','lib/core/json_util.ml','lib/tui_decode_fields.ml','lib/tui_decode_lane_inventory.ml','lib/tui_decode_lane_inventory.mli','bin/masc_tui_lane_inventory.ml','bin/masc_tui_lane_inventory.mli','test/test_tui_lane_inventory.ml']:copy(p)
put('browser_lane.ml','module Lane_name = Browser_lane_name\n')
put('shared_types.ml','module Json_kind = Json_kind\n')
put('tui_decode.ml','open Json_util\nopen Tui_decode_fields\n'+extract('lib/tui_decode.ml','type standalone_lane_status =','type standalone_lane_answer =')+extract('lib/tui_decode.ml','let standalone_lane_configuration_of_string','(* A clause, not a word.')+extract('lib/tui_decode.ml','let standalone_lane_status_of_string','let keeper_secret_status_of_string'))
put('lane_addon_types.ml',extract('lib/lane_addon/lane_addon_types.ml','type phase =','let ( let* )')+'let ( let* ) = Result.bind\n'+extract('lib/lane_addon/lane_addon_types.ml','let object_fields expected','let text name')+extract('lib/lane_addon/lane_addon_types.ml','let phase_of_json','let output_selection_to_json'))
for name,path in [('tui_decode.ml','lib/tui_decode.ml'),('lane_addon_types.ml','lib/lane_addon/lane_addon_types.ml')]:provenance[name]={'source':path,'scope':'production decoder/type and phase blocks extracted by exact source markers','source_sha256':hashlib.sha256((root/path).read_bytes()).hexdigest(),'extracted_sha256':hashlib.sha256((out/name).read_bytes()).hexdigest()}
put('masc.ml','\n'.join('module '+name+' = '+name for name in ['Standalone_lane','Machine_lane','Lane_id','Tui_decode','Lane_addon_types','Tui_decode_lane_inventory'])+'\n')
commands=[]
def run(args):
 commands.append(args);print('+ '+' '.join(args),flush=True);subprocess.run(args,cwd=out,check=True)
run(['ocamlc','-version'])
modules=['standalone_lane','machine_lane','browser_lane_name','browser_lane','declaration_file','lane_id','json_kind','shared_types','json_util','tui_decode_fields','tui_decode','lane_addon_types','tui_decode_lane_inventory','masc','masc_tui_lane_inventory','test_tui_lane_inventory']
for name in modules:
 for suffix in ['.mli','.ml']:
  if (out/(name+suffix)).exists(): run(['ocamlfind','ocamlc','-package','yojson,alcotest,ppx_enumerate','-c',name+suffix])
run(['ocamlfind','ocamlc','-package','yojson,alcotest,ppx_enumerate','-linkpkg',*[name+'.cmo' for name in modules],'-o','test.exe'])
run(['./test.exe'])
(out/'provenance.json').write_text(json.dumps({'scope':'Actual inventory source and production decoder/type extracts; namespace aliases only. Not a full Masc/TUI link or native backend run.','sources':provenance,'commands':commands},indent=2)+'\n')
print('ISOLATED_DIR='+str(out))

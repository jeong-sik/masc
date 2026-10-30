import hashlib,json,pathlib,shutil,subprocess,sys,tempfile
from datetime import datetime,timezone
root=pathlib.Path(sys.argv[1]).resolve();report=pathlib.Path(__file__).resolve().parent
scratch=pathlib.Path(tempfile.mkdtemp(prefix="masc-machine-activity-"));sources={};commands=[]
for directory in ["lib/machine_configuration","lib/runtime_toml_namespace","lib/msx_lane","lib/machine_live_publication","lib/random_id","lib/crypto_rng","lib/time_compat","lib/lane_activity"]:
 for source in sorted((root/directory).iterdir()):
  if source.suffix in [".ml",".mli"]:
   shutil.copyfile(source,scratch/source.name);sources[str(source.relative_to(root))]=hashlib.sha256(source.read_bytes()).hexdigest()
for name in ["lib/dos_lane/dos_lane.ml","lib/dos_lane/dos_lane.mli","lib/machine_checkpoint/machine_checkpoint.mli","test/test_msx_lane_activity.ml","test/test_dos_lane_activity.ml"]:
 source=root/name;shutil.copyfile(source,scratch/source.name);sources[name]=hashlib.sha256(source.read_bytes()).hexdigest()
packages="alcotest,unix,threads,yojson,base64,digestif.c,otoml,uuidm,mirage-crypto-rng.unix,mcp_protocol.eio,ppx_enumerate,ppx_deriving.show,ppx_deriving.eq,ppx_deriving_yojson,ocaml-msx.msx,ocaml-dos.dosmachine,ocaml-dos.cpu86core,ocaml-dos.core-identity"
def run(args):
 print("+ "+" ".join(args),flush=True);p=subprocess.run(args,cwd=scratch,text=True,capture_output=True)
 commands.append({"command":args,"exit_code":p.returncode});print(p.stdout,end="",flush=True);print(p.stderr,end="",flush=True)
 if p.returncode:raise subprocess.CalledProcessError(p.returncode,args)
 return p.stdout
passed=False
try:
 version=run(["ocamlc","-version"]).strip()
 if version!="5.5.1":raise RuntimeError("requires repository OCaml 5.5.1")
 run(["ocamlc","-where"])
 run(["ocamlfind","query","-format","%p %v %d","ocaml-msx.msx","ocaml-dos.dosmachine","ocaml-dos.core-identity"])
 names=sorted(p.name for p in scratch.iterdir() if p.suffix in [".ml",".mli"])
 order=run(["ocamlfind","ocamldep","-package",packages,"-sort",*names]).split()
 for name in order:run(["ocamlfind","ocamlc","-w","+32+69","-warn-error","+a","-package",packages,"-c",name])
 objects=[str(pathlib.Path(name).with_suffix(".cmo")) for name in order if name.endswith(".ml") and name not in ["dos_lane.ml","test_dos_lane_activity.ml"]]
 run(["ocamlfind","ocamlc","-package",packages,"-linkpkg",*objects,"-o","msx-test.exe"])
 run(["./msx-test.exe"]);passed=True
finally:
 (report/"owner-provenance.json").write_text(json.dumps({"checked_at":datetime.now(timezone.utc).isoformat(),"passed":passed,"source_root":str(root),"base":subprocess.check_output(["git","rev-parse","HEAD"],cwd=root,text=True).strip(),"scratch":str(scratch),"sources":sources,"commands":commands,"scope":"Actual MSX/config and dependencies compiled, linked and executed. DOS owner/test source typechecked against actual checkpoint interface and installed core, not linked/executed. No substitute product modules. No Runtime publication, HTTP, full native TUI/PTY, CI or deployment proof."},indent=2)+"\n")

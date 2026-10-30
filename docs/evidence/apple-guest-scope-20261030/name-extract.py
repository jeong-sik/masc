#!/usr/bin/env python3
"""Compile the exact guest-name implementation with small dependency stubs."""
import hashlib,json,subprocess,sys
from pathlib import Path
repo=Path(sys.argv[1]); out=Path(sys.argv[2]); out.mkdir(parents=True,exist_ok=True)
name_source=(repo/'lib/keeper/keeper_sandbox_container_name.ml').read_text()
setup_source=(repo/'lib/keeper/keeper_sandbox_runtime_setup.ml').read_text()
a=setup_source.index('let strip_trailing_slashes = Env_config_core.strip_trailing_slashes')
b=setup_source.index('\nlet sanitize_label_value',a)
hash_source=setup_source[a:b]
stub='''module Env_config_core = struct let strip_trailing_slashes s = s end
module Config_dir_resolver = struct let current_working_dir () = Sys.getcwd () end
module Keeper_sandbox_runtime_setup = struct
'''+hash_source+'''
end
module Workspace_utils = struct let safe_filename s = s end
module Keeper_types_profile_sandbox = struct
 type network_mode = Network_inherit
 let network_mode_to_string Network_inherit = "inherit"
end
module Agent_core_sha256 = struct
 let digest_string s = s
 let to_hex _ = String.make 64 '0'
end
'''
main='''
let () =
 let paths = ["/synthetic-workspaces/workspace-36434"; "/synthetic-workspaces/workspace-83774"] in
 List.iter (fun base_path ->
   let name = make (Micro_vm_persistent {keeper_name="shared"; network_mode=Keeper_types_profile_sandbox.Network_inherit; base_path}) |> to_string in
   Printf.printf "%s %s %s\\n" base_path (Keeper_sandbox_runtime_setup.base_path_hash base_path) name) paths
'''
(out/'probe.ml').write_text(stub+name_source+main)
c=subprocess.run(['ocamlc','-o','probe','probe.ml'],cwd=out,capture_output=True,text=True)
r=subprocess.run(['./probe'],cwd=out,capture_output=True,text=True) if c.returncode==0 else None
receipt={'scope':'actual extracted container-name and base-path hash functions with dependency stubs; synthetic paths only, no runtime action', 'source_sha256':hashlib.sha256(name_source.encode()).hexdigest(),'setup_source_sha256':hashlib.sha256(setup_source.encode()).hexdigest(),'compile_exit':c.returncode,'compile_stderr':c.stderr,'run_exit':None if r is None else r.returncode,'stdout':None if r is None else r.stdout}
print(json.dumps(receipt,indent=2))
sys.exit(0 if r is not None and r.returncode==0 else 1)

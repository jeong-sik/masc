"""Execute real source/contract codecs and before/after checkpoint field builders.
Core checkpoint payload dependencies are fixtures, explicitly listed in output.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

BASE = 'f9803add95065c6af4a69bba130308f402785ecd'
MODULES = ['provider_kind', 'reasoning_replay_contract', 'json_object_keys']

def sha(text):return hashlib.sha256(text.encode()).hexdigest()
def section(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]

def main():
    here=Path(__file__).resolve().parent
    root=here.parents[2]
    lib=root/'packages/agent_core/lib'
    llm=lib/'llm_provider'
    hashes={}
    with tempfile.TemporaryDirectory(prefix='masc-checkpoint-binding-') as tmp:
        tmp=Path(tmp)
        files=[]
        for module in MODULES:
            for ext in ['mli','ml']:
                name=f'{module}.{ext}';text=(llm/name).read_text()
                hashes[name]={'source_sha256':sha(text),'compiled_sha256':sha(text)}
                (tmp/name).write_text(text);files.append(name)
        for ext,start in [('mli','module Reasoning_source : sig'),('ml','module Reasoning_source = struct')]:
            text=(llm/f'types.{ext}').read_text()
            extracted=section(text,start,'\nend')+'\nend\n'
            compiled='type metadata = (string * Yojson.Safe.t) list\n'+extracted
            hashes[f'types.{ext}:Reasoning_source']={'source_sha256':sha(text),'compiled_sha256':sha(compiled)}
            (tmp/f'type_extract.{ext}').write_text(compiled);files.append(f'type_extract.{ext}')
        codec=(lib/'checkpoint_codec.ml').read_text()
        helpers=section(codec,'let provider_binding_to_json','let reasoning_effort_option_to_json')
        current=section(codec,'let checkpoint_fields_around_messages','let decode_current_json')
        old=subprocess.check_output(['git','show',f'{BASE}:packages/agent_core/lib/checkpoint_codec.ml'],cwd=root,text=True)
        before=section(old,'let checkpoint_fields_around_messages','let decode_current_json')
        for name,text in [('codec_helpers',helpers),('current_fields',current),('before_fields',before)]:
            prefix='open Type_extract\nopen Payloads\n'
            if name!='codec_helpers':prefix+='open Codec_helpers\nlet messages_field="messages"\n'
            (tmp/f'{name}.ml').write_text(prefix+text)
            hashes[name]={'source_sha256':sha(old if name=='before_fields' else codec),'compiled_sha256':sha(prefix+text)}
        for name in ['payloads.ml','fixture.ml']:
            payload=(here/name).read_bytes();(tmp/name).write_bytes(payload)
            hashes[name]={'source_sha256':hashlib.sha256(payload).hexdigest(),'compiled_sha256':hashlib.sha256(payload).hexdigest()}
        subprocess.run(['ocamlfind','ocamlc','-package','yojson,uri,digestif.c,ppx_deriving.show,ppx_deriving.eq,ppx_deriving_yojson',
            '-linkpkg',*files,'payloads.ml','codec_helpers.ml','before_fields.ml','current_fields.ml','fixture.ml','-o','fixture'],cwd=tmp,check=True)
        checks=json.loads(subprocess.check_output([str(tmp/'fixture')],text=True))
    print(json.dumps({'scope':'actual Reasoning_source module/interface and leaf modules, actual provider-binding codec helpers and checkpoint field builders with fixture checkpoint payload dependencies',
        'before_base':BASE,'sources':hashes,'checks':checks,
        'fixture_dependencies':['checkpoint record payload types','non-binding payload encoders','Error serialization envelope','metadata type alias'],
        'project_linked':False,'delta_executed':False,'pipeline_executed':False,'resume_admission_implemented':False,'provider_called':False},indent=2))
    if not all(checks.values()):raise SystemExit(1)

if __name__=='__main__':main()

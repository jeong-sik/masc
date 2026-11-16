#!/usr/bin/env python3
"""Compile real profiler/diagnostic sources; explicitly fixture HTTP/auth storage ports."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('repo', 'base', 'out', 'opam-prefix', 'cmi-prefix'):
        p.add_argument('--'+name, required=True, type=Path if name != 'base' else str)
    a = p.parse_args()
    repo, out, opam = a.repo.resolve(), a.out.resolve(), a.opam_prefix.resolve()
    if repo not in out.parents or out.relative_to(repo).parts[0] != 'artifacts':
        p.error('use a new output directory under repo/artifacts')
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, PATH=str(opam/'bin')+os.pathsep+os.environ['PATH'])

    def run(argv, label, cwd=None):
        r = subprocess.run(list(map(str, argv)), cwd=cwd or out, env=env, capture_output=True, text=True)
        (out/(label+'.stdout.txt')).write_text(r.stdout)
        (out/(label+'.stderr.txt')).write_text(r.stderr)
        if r.returncode:
            raise RuntimeError(label+': '+r.stderr[-4000:]+r.stdout[-2000:])
        return r.stdout

    hashes = {}
    def source(path, base=False):
        raw = subprocess.check_output(['git','-C',str(repo),'show',a.base+':'+path]) if base else (repo/path).read_bytes()
        hashes[('base:' if base else 'candidate:')+path] = hashlib.sha256(raw).hexdigest()
        return raw.decode()

    def extract(text, start, stop):
        return start+text.split(start,1)[1].split(stop,1)[0]

    version = run(['ocamlopt','-version'],'compiler').strip()
    if version != '5.5.2':
        raise RuntimeError('OCaml5.5.2 required')
    paths=['lib/core/heap_roots.mli','lib/core/heap_roots.ml','lib/core/alloc_profile.mli',
           'lib/core/alloc_profile.ml','test/test_alloc_profile.ml']
    for path in paths:
        (out/Path(path).name).write_text(source(path))
    baseline = source('lib/core/alloc_profile.ml',True)
    (out/'baseline_alloc_profile.ml').write_text(baseline)
    flags=['ocamlfind','ocamlopt','-g','-thread','-package','yojson,alcotest,unix,eio,httpun,uri',
           '-linkpkg','-w','+4+8+32+69','-warn-error','+4+8+32+69']
    run(flags+['heap_roots.mli','heap_roots.ml','alloc_profile.mli','alloc_profile.ml',
               'test_alloc_profile.ml','-o','core-tests'],'compile-core')
    core_output=run([out/'core-tests','--color=never'],'core-tests')

    (out/'build_identity.ml').write_text('let runtime_instance_id = "fixture-process-identity"\n')
    types=source('lib/types/types_auth.ml')
    role=extract(types,'type agent_role =','[@@deriving')
    permission=extract(types,'type permission =','[@@deriving')
    names=extract(types,'let permission_to_string =','(** Get permissions')
    permission_check=extract(types,'let has_permission role permission =','\n\n')
    (out/'masc_domain.ml').write_text(role+permission+names+permission_check+'''
let show_permission = permission_to_string
module Auth_error = struct
 type reason = Missing_token
 type t = Unauthorized of {reason:reason;message:string} | Forbidden of {agent:string;action:string}
end
type masc_error = Auth of Auth_error.t
type credential = {agent_name:string;role:agent_role}
type auth_config = {enabled:bool;require_token:bool}
''')
    # Transport/storage/encoding ports are fixtures. The actual authorization,
    # permission predicate, read quota classification and query-precondition
    # control flow are extracted below, not reimplemented here.
    (out/'http_server_eio.ml').write_text('''
type response={mutable status:Httpun.Status.t;mutable body:string;mutable headers:(string*string)list}
type request_handler=Httpun.Request.t->response->unit
module Router=struct type t=(string*request_handler)list end
module Response=struct
 let scoped=ref []
 let scoped_headers ()= !scoped
 let with_scoped_headers headers f = let old= !scoped in scoped:=headers;
   Fun.protect ~finally:(fun()->scoped:=old) f
 let json_value ?(status=`OK) ~compress:_ ~request:_ value out =
   out.status<-status;out.body<-Yojson.Safe.to_string value;out.headers<- !scoped
 let bytes ~status ~headers ~content_type:_ body out =
   out.status<-status;out.body<-body;out.headers<-headers@ !scoped
end
''')
    auth=source('lib/server/server_auth.ml')
    fixture='''
let ( let* )=Result.bind
module Auth=struct
 let load_auth_config _={Masc_domain.enabled=true;require_token=true}
 let find_credential_by_token _ ~token = match token with
  | "admin"->Ok {Masc_domain.agent_name="admin";role=Admin}
  | "worker"->Ok {Masc_domain.agent_name="worker";role=Worker}
  | _->Error(Masc_domain.Auth(Masc_domain.Auth_error.Unauthorized
       {reason=Missing_token;message="fixture missing token"}))
end
let token_bound_auth_token_from_request request =
 match Httpun.Headers.get request.Httpun.Request.headers "authorization" with
 | Some value when String.starts_with ~prefix:"Bearer " value ->
   Some(String.sub value 7 (String.length value-7))
 | Some _|None->None
module Workspace=struct
 type config={base_path:string}
 type error=Invalid_workspace_precondition|Workspace_precondition_failed
 let read_precondition_admission_header="x-fixture-precondition","matched"
 let validate_expected_workspace ~config json =
  let open Yojson.Safe.Util in
  let expected=json |>member "expected_workspace" in
  if expected |>member "base_path" |>to_string =config.base_path
    && expected |>member "masc_root" |>to_string =config.base_path^"/.masc"
  then Ok () else Error Workspace_precondition_failed
end
module Mcp_server=struct
 let workspace_config ()={Workspace.base_path="/fixture"}
end
module Http_response_payload=struct
 let accept_encoding_fields _=()
 let compress_body ~accept_encoding:_ body=body,[]
end
let public_read_cors_headers _=[]
let current_server_state ()=Some ()
let respond_not_initialized request out=Http_server_eio.Response.json_value
 ~status:`Service_unavailable ~compress:false ~request `Null out
let respond_auth_error request out =function
 | Masc_domain.Auth(Masc_domain.Auth_error.Unauthorized _)->
   Http_server_eio.Response.json_value ~status:`Unauthorized ~compress:false ~request `Null out
 | Masc_domain.Auth(Masc_domain.Auth_error.Forbidden _)->
   Http_server_eio.Response.json_value ~status:`Forbidden ~compress:false ~request `Null out
type agent_quota=Exempt_observation|Metered_operation
let quota_calls=ref []
let check_agent_rate_limit ~quota _request _out=quota_calls:=quota:: !quota_calls;Ok ()
'''
    fixture+=extract(auth,'let read_request_quota =','(** Check the per-agent rate limit')
    fixture+=extract(auth,'let authorize_token_bound_permission_request','let authorize_optional_token_bound_permission_request')
    fixture+=extract(auth,'type read_workspace_precondition =','(* HIGH-RISK-UNREVIEWED:')
    fixture+=extract(auth,'and with_token_permission_auth','let with_private_token_permission_auth').replace('and with_token_permission_auth','let with_token_permission_auth',1)
    (out/'auth_ports.ml').write_text(fixture)
    (out/'server_route.ml').write_text('''
type auth=Token_permission of Masc_domain.permission
let get (Token_permission permission) path handler routes=
 (path,Auth_ports.with_token_permission_auth ~permission handler)::routes
''')
    for ext in ('mli','ml'):
        (out/('server_diagnostics_memprof.'+ext)).write_text(source('lib/server/server_diagnostics_memprof.'+ext))
    tests=source('test/test_server_route.ml')
    api_tests=extract(tests,'let with_memprof_fixture','let test_memprof_numeric_routes_preserve_operator_read_authority')
    cases=Path(__file__).with_name('cases.ml').read_text()
    (out/'probe.ml').write_text('open Alcotest\n'+api_tests+cases)
    run(flags+['heap_roots.cmx','alloc_profile.cmx','baseline_alloc_profile.ml','build_identity.ml',
      'masc_domain.ml','http_server_eio.ml','auth_ports.ml','server_route.ml',
      'server_diagnostics_memprof.mli','server_diagnostics_memprof.ml','probe.ml','-o','probe'],'compile-probe')
    output=run([out/'probe'],'probe')
    measured=json.loads(output)
    prefix_raw=a.cmi_prefix.read_bytes();prefix=json.loads(prefix_raw)
    prefix[0]=str(opam/'bin/ocamlc')
    prefix[prefix.index('-I')+1]=str(out/'actual-typing')
    typing=out/'actual-typing';typing.mkdir()
    checks=[]
    for path in ['lib/core/alloc_profile.mli','lib/core/alloc_profile.ml',
                 'lib/server/server_diagnostics_memprof.mli','lib/server/server_diagnostics_memprof.ml',
                 'lib/server/server_routes_http_routes_dashboard.ml','test/test_alloc_profile.ml','test/test_server_route.ml']:
        args=prefix.copy()
        if '/core/' in path or path=='test/test_alloc_profile.ml':
            index=args.index('-open');assert args[index+1]=='Masc';del args[index:index+2]
        if path=='test/test_server_route.ml':
            # An unchanged cleanup wildcard has warning4 in the baseline.
            # Production/new isolated bodies retain all four fatal warnings.
            args+=['-warn-error','-4']
        s=repo/path;target=typing/(s.stem+('.cmi' if s.suffix=='.mli' else '.cmo'))
        run(args+['-thread','-c','-o',target,s],'typing-'+s.name,cwd=typing)
        checks.append({'source':path,'sha256':hashlib.sha256(s.read_bytes()).hexdigest(),'exit_code':0,
                       'fatal_warnings':[8,32,69] if path=='test/test_server_route.ml' else [4,8,32,69]})
    result={'schema':'memprof-counter-snapshot-probe.v1','base':a.base,'compiler':version,
      'source_sha256':hashes,'replay_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
      'cases_sha256':hashlib.sha256(Path(__file__).with_name('cases.ml').read_bytes()).hexdigest(),
      'core_tests_passed':int(re.search(r'(\d+) tests run',core_output).group(1)),
      'actual_cmi_prefix_sha256':hashlib.sha256(prefix_raw).hexdigest(),'actual_cmi_typing':checks,
      **measured,'limits':['Complete real Alloc_profile and Heap_roots with real Gc.Memprof and domains/threads.',
      'Complete diagnostic ML/MLI and exact pure API test bodies run with explicit HTTP, identity, credential-store, workspace-validation and response-encoding fixtures.',
      'Actual authorization function, permission predicate, read wrapper/quota and workspace query precondition control flow are source-extracted; no persistent real auth store or complete router/HTTP codec ran.',
      'Full test_server_route source is typed, but its full native executable and new integrated HTTP regression are not executed.',
      'Only full test_server_route typing leaves warning4 nonfatal for its unchanged baseline cleanup wildcard; production/isolated new bodies retain fatal4/8/32/69.',
      'Actual-CMI typing uses existing dependency artifacts; no Dune, dependency build, full link, CI or installed runtime/provider request.']}
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'core_tests':result['core_tests_passed'],'checks':measured['checks'],'typed':len(checks),'measurements':measured['measurements']}))


if __name__=='__main__':main()

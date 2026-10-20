"""Exercise actual HTTP reader bodies and response-decode wrapper without Dune.

HTTP, typed projections and the MASC pool adapter are fixtures. JSON parsing,
OCaml domains and Eio.Executor_pool are real. This is not native MASC linkage.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--before', required=True)
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[3])
args = parser.parse_args()
relative = 'bin/masc_tui_http.ml'
before = subprocess.check_output(['git', 'show', args.before + ':' + relative], cwd=args.repo, text=True)
after = (args.repo / relative).read_text()


def functions(source):
    first = source.split('let fetch_keeper_chat_history ~', 1)[1].split('let fetch_keeper_memory_journal ~', 1)[0]
    second = source.split('let fetch_keeper_memory_journal ~', 1)[1].split('(** Fetch one actual Librarian input', 1)[0]
    third = source.split('let fetch_keeper_chat_history_page ~', 1)[1].split('let fetch_keeper_memory_input ~', 1)[0]
    limit = source.split('let history_page_limit = ', 1)[1].splitlines()[0]
    return ('let fetch_keeper_chat_history ~' + first
            + 'let fetch_keeper_memory_journal ~' + second
            + 'let history_page_limit = ' + limit + '\n'
            + 'let fetch_keeper_chat_history_page ~' + third)


stubs = r'''
module Domain_pool_ref = struct
 let pool : Eio.Executor_pool.t option ref = ref None
 let submit_cpu_or_inline work = match !pool with
 | None -> work ()
 | Some pool -> Eio.Executor_pool.submit_exn pool ~weight:1. work
end
module Eio_guard = struct let with_named_switch _ work = work () end
module Masc = struct module Tui_decode = struct
 let is_success_http_status status = status >= 200 && status < 300
end end
let projection_hook = ref (fun () -> ())
module Masc_tui_keeper_chat_history = struct
 type decoded = Yojson.Safe.t
 type page = Yojson.Safe.t
 type page_error = Page_stale | Page_read_failed of string
 let decode json = !projection_hook (); match json with
 | `Null -> Error "typed fixture refusal" | json -> Ok json
 let rows_of_json = decode
 let memory_rows_of_json = decode
 let page_of_json = decode
end
let caller = ref (Domain.self ())
let response : ((int * string), string) result ref = ref (Ok (200, "[]"))
let percent_encode_path_segment value = value
let http_get ~host:_ ~port:_ ~path:_ = assert(Domain.self () = !caller); !response
let named_refusal label ~status ~body =
 assert(Domain.self () = !caller); Printf.sprintf "%s: %d %s" label status body
'''
checks = r'''
let history read () = read ~host:"fixture" ~port:0 ~keeper_name:"keeper"
let page read () = read ~host:"fixture" ~port:0 ~keeper_name:"keeper" ~cursor:None
let cases = [Ok(200,"[]");Ok(200,"{\"entries\":[]}");
 Ok(200,"null");Ok(200,"{");Ok(409,"stale");Ok(503,"refused");Error "transport"]
let cases_checked = ref 0 and worker_projections = Atomic.make 0
let check ~off_worker old fresh =
 List.iter (fun fixture ->
  response := fixture;
  projection_hook := (fun () -> assert(Domain.self () = !caller));
  let expected = old () in
  projection_hook := (fun () ->
   assert((Domain.self () <> !caller) = off_worker);
   if off_worker then Atomic.incr worker_projections);
  let actual = fresh () in assert(expected = actual); incr cases_checked
 ) cases
let all ~off_worker () =
 check ~off_worker (history Old.fetch_keeper_chat_history) (history New.fetch_keeper_chat_history);
 check ~off_worker (history Old.fetch_keeper_memory_journal) (history New.fetch_keeper_memory_journal);
 check ~off_worker (page Old.fetch_keeper_chat_history_page) (page New.fetch_keeper_chat_history_page)
exception Projection_failure
let () =
 all ~off_worker:false ();
 Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  caller := Domain.self ();
  Domain_pool_ref.pool := Some(Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env));
  all ~off_worker:true ();
  let entered, enter = Eio.Promise.create () and released, release = Eio.Promise.create () in
  response := Ok(200,"[]");
  projection_hook := (fun () -> Eio.Promise.resolve enter (Domain.self () <> !caller); Eio.Promise.await released);
  Eio.Fiber.both
   (fun () -> assert(history New.fetch_keeper_chat_history () = Ok (`List [])))
   (fun () -> assert(Eio.Promise.await entered); Eio.Promise.resolve release ());
  let attempts = Atomic.make 0 in
  projection_hook := (fun () -> Atomic.incr attempts; raise Projection_failure);
  (match history New.fetch_keeper_chat_history () with
   | _ -> failwith "projection exception swallowed"
   | exception Projection_failure -> ());
  assert(Atomic.get attempts = 1);
  Domain_pool_ref.pool := None));
 Printf.printf "equivalence_cases=%d worker_projections=%d caller_progress_while_worker_waits=PASS exception_no_replay=PASS\n%!"
  !cases_checked (Atomic.get worker_projections)
'''
wrapper = (args.repo / 'bin/masc_tui_response_decode.ml').read_text()
source = stubs + '\nmodule Masc_tui_response_decode = struct\n' + wrapper + '\nend\n'
source += '\nmodule Old = struct\n' + functions(before) + '\nend\n'
source += '\nmodule New = struct\n' + functions(after) + '\nend\n' + checks
with tempfile.TemporaryDirectory(prefix='masc-tui-reader-probe-') as directory:
    script = Path(directory) / 'probe.ml'
    script.write_text(source)
    binary = Path(directory) / 'probe'
    subprocess.run(['ocamlfind', 'ocamlopt', '-thread', '-linkpkg', '-package', 'eio_main,yojson', '-o', str(binary), str(script)], check=True)
    subprocess.run([str(binary)], check=True)

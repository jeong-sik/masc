"""Read production flow into a temporary actual-application probe.

No production files change. Real Eio/atomic slots/application arms; HTTP,
workspace checks, state/rows, merges and job registration remain fixtures from
the existing flow probe. This is not native MASC linkage or an HTTP test.
The counterfactual clear executes only in a warm first_page=false scenario.
"""
from pathlib import Path
import argparse
import hashlib
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("repo", type=Path, nargs="?", default=Path(__file__).resolve().parents[3])
args = parser.parse_args()
root = args.repo.resolve()
script = root / "docs/evidence/2026-10-20-tui-history-independent/flow_probe.py"
ns = {"__file__": str(script)}
exec(script.read_text().split("with tempfile.TemporaryDirectory", 1)[0], ns)
main = (root / "bin/masc_tui.ml").read_text()
older = "  | Keeper_chat_older_loaded (generation, keeper_name, cursor, result) ->" + main.split(
    "  | Keeper_chat_older_loaded (generation, keeper_name, cursor, result) ->", 1
)[1].split("\n(* How long one pass", 1)[0]
stubs = ns["stubs"].replace(
    "type 'a mailed =",
    " | Keeper_chat_older_loaded of int * string * string option * "
    "(Keeper_chat_history.page,Keeper_chat_history.page_error) result\ntype 'a mailed =",
)
helpers = ns["checks"].split("let ordering ", 1)[0].replace(
    "Keeper_chat_history_loaded _ | Keeper_chat_first_page_loaded _ -> failwith",
    "Keeper_chat_history_loaded _ | Keeper_chat_first_page_loaded _ | Keeper_chat_older_loaded _ -> failwith",
)
case = r'''
let () = Eio_main.run(fun _ -> Eio.Switch.run(fun sw -> current_switch:=Some sw;
 let state=fresh () in state.msg_loaded_keeper<-Some "a";
 set_keeper_chat_sources state {kcs_history=Some[{id=40;me_role=Message_history}];kcs_memory=[]};
 state.msg_older_cursor<-Some "retry-cursor";state.msg_older_exist<-true;
 let hp,hu=Eio.Promise.create () in let started=ref false in
 history_fetch:=(fun () -> started:=true;Eio.Promise.await hp);
 memory_fetch:=(fun () -> decoded ~memory:true 41);
 page_fetch:=(fun () -> failwith "warm page must not run");
 launch state;yield_until(fun () -> !started);
 let generation=state.msg_history_load_generation in
 state.msg_older_loading<-true;
 apply state ~mailbox:() (Keeper_chat_older_loaded(generation,"a",Some "retry-cursor",
   Error(Keeper_chat_history.Page_read_failed "actual older cursor refused")));
 assert(state.msg_older_error=Some "actual older cursor refused");
 assert(state.msg_older_cursor=Some "retry-cursor" && state.msg_older_exist && not state.msg_older_loading);
 Eio.Promise.resolve hu(decoded ~memory:false 42);
 yield_until(fun () -> drain state;state.msg_history_inflight=None);
 assert(state.msg_loaded_error=None && has state 40 && has state 41 && has state 42);
 if state.msg_older_error<>Some "actual older cursor refused" then failwith "aggregate erased the separate page failure";
 assert(state.msg_older_cursor=Some "retry-cursor" && state.msg_older_exist && not state.msg_older_loading);
 state.msg_older_loading<-true;
 apply state ~mailbox:() (Keeper_chat_older_loaded(generation,"a",Some "retry-cursor",
  Ok{Keeper_chat_history.decoded={rows=[{id=43;memory=false;at=0.}];dropped=0};has_more=false;next_cursor=None}));
 assert(state.msg_older_error=None && state.msg_older_cursor=None && not state.msg_older_exist && has state 43);
 print_endline "warm_history_success_preserves_actual_page_failure_and_cursor=PASS actual_page_retry_clears_error_and_advances_cursor=PASS"))
'''
base = (
    ns["header"] + ns["slots"] + stubs + ns["collect"] + ns["after_collect"]
    + ns["setter"] + ns["launch"]
    + "\nlet retire_keeper_chat_history _ _ = ()\nlet apply state ~mailbox = function\n"
)
print("source_head", subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root).decode().strip(), flush=True)
for mode in ["current_source", "proposed_warm_clear_branch"]:
    arm = ns["arm"]
    if mode != "current_source":
        before = "state.msg_loaded_error <- None;"
        assert arm.count(before) == 1
        arm = arm.replace(before, before + "\n                 state.msg_older_error <- None;", 1)
    source = base + arm + older + "\n | Workspace_scoped _ -> assert false\n" + helpers + case
    print(mode, "probe_sha256", hashlib.sha256(source.encode()).hexdigest(), flush=True)
    with tempfile.TemporaryDirectory(prefix="masc-warm-page-review-") as directory:
        work = Path(directory)
        (work / "probe.ml").write_text(source)
        built = subprocess.run(
            ["ocamlfind", "ocamlopt", "-thread", "-package", "eio_main,mtime.clock",
             "-linkpkg", "probe.ml", "-o", "probe"], cwd=work, capture_output=True, text=True
        )
        print(mode, "compile_exit", built.returncode, flush=True)
        if built.returncode:
            raise RuntimeError(built.stderr)
        ran = subprocess.run([str(work / "probe")], cwd=work, capture_output=True, text=True)
        print(mode, "run_exit", ran.returncode, ran.stdout.strip(), ran.stderr.strip(), flush=True)
        if mode == "current_source":
            assert ran.returncode == 0
        else:
            assert ran.returncode != 0 and "aggregate erased the separate page failure" in ran.stderr

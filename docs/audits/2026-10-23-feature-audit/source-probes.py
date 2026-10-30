"""Run audited OCaml source slices, not the linked server or an Eio scheduler.

The fixtures exercise reset traversal and history/mention projections. I/O,
valid-text decoding, initialization and preview bounds have explicit adapters.
The source is read from the requested Git revisions; no product source is edited.
Requires the repository's OCaml toolchain plus yojson/re. No Dune invocation.
"""

import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--before", required=True)
parser.add_argument("--after", required=True)
parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[3])
args = parser.parse_args()


def read(revision, path):
    return subprocess.check_output(["git", "-C", str(args.repo), "show", f"{revision}:{path}"], text=True)


def section(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first)]


def run(script):
    packages = [subprocess.check_output(["ocamlfind", "query", name], text=True).strip()
                for name in ("yojson", "re")]
    with tempfile.TemporaryDirectory(prefix="masc-source-probe-") as directory:
        path = Path(directory) / "probe.ml"
        path.write_text(script)
        subprocess.run(["ocaml", "-noinit", "-I", "+unix", "unix.cma", "-I", "+threads", "threads.cma",
                        "-I", packages[0], "yojson.cma", "-I", packages[1], "re.cma", str(path)], check=True)


mkdir = read(args.after, "lib/fs_compat/mkdir_memo.ml")
remove = section(read(args.after, "lib/fs_compat/fs_compat.ml"), "let remove_tree_unix ", "let remove_tree (")
reset_prelude = r'''
type config = { base_path : string };;
let masc_dir config = Filename.concat config.base_path ".masc";;
(* Initialization and scheduling adapters: enter the reset branch without booting a server. *)
let is_initialized config = Sys.file_exists (masc_dir config);;
let invalidate_initialized_cache () = ();;
module Workspace_query = struct let safe_yield () = () end;;
'''
reset_prelude += "module Mkdir_memo = struct\n" + mkdir + "\nend;;\n"
reset_prelude += "module Fs_compat = struct\n" + remove + r'''
let remove_tree = remove_tree_unix
let invalidate_mkdir_memo = Mkdir_memo.invalidate
end;;
'''
for label, revision in (("before", args.before), ("after", args.after)):
    reset = read(revision, "lib/workspace/workspace_init.ml").split("let reset config =", 1)[1]
    run(reset_prelude + "let reset config =" + reset + r'''
let () =
 let root = Filename.temp_dir "reset-boundary-" "" in
 Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
 let workspace = Filename.concat root "workspace" and outside = Filename.concat root "outside" in
 Unix.mkdir workspace 0o700; Unix.mkdir outside 0o700;
 let marker = Filename.concat outside "keep.txt" in
 Out_channel.with_open_text marker (fun oc -> output_string oc "outside workspace");
 let config = {base_path=workspace} in
 Unix.mkdir (masc_dir config) 0o700;
 Unix.symlink outside (Filename.concat (masc_dir config) "linked-directory");
 let nested = Filename.concat (masc_dir config) "nested" in
 Mkdir_memo.mkdir_p_memoized ~mkdir_p:(fun path -> Unix.mkdir path 0o700) nested;
 let returned = try ignore (reset config); true with Unix.Unix_error (Unix.ENOTDIR,_,_) -> false in
 let preserved = Sys.file_exists marker in
''' + f' assert (preserved = {str(label == "after").lower()});\n' + r'''
 if returned then begin
  Unix.mkdir (masc_dir config) 0o700;
  Mkdir_memo.mkdir_p_memoized ~mkdir_p:(fun path -> Unix.mkdir path 0o700) nested;
  assert (Sys.is_directory nested);
  Unix.symlink marker (Filename.concat (masc_dir config) "linked-file");
  Unix.symlink (Filename.concat outside "missing") (Filename.concat (masc_dir config) "dangling");
  ignore (reset config); assert (Sys.file_exists marker)
 end;
''' + f' Printf.printf "reset {label}: returned=%b external_file_preserved=%b\\n" returned preserved);;\n')

adapters = r'''
module Safe_ops = struct
 let json_string ~default key json = match Yojson.Safe.Util.member key json with `String s -> s | _ -> default
 let json_float ~default key json = match Yojson.Safe.Util.member key json with `Float f -> f | `Int i -> float_of_int i | _ -> default
end;;
module String_util = struct
 type truncation = Untouched of string | Truncated of {prefix:string;suffix:string}
 (* Fixtures fit the real preview bounds; truncation is not under test. *)
 let utf8_prefix ~max_bytes text = assert (String.length text <= max_bytes); text
 let utf8_safe ~max_bytes ~suffix:_ text = assert (String.length text <= max_bytes); Untouched text
'''
utilities = read(args.before, "lib/string_util/string_util.ml")
start = utilities.index("let contains_substring_ci")
adapters += utilities[start:utilities.index("\nlet ", start + 4)] + "\nend;;\n"
policy = section(read(args.after, "lib/keeper/keeper_types_support.ml"), "let normalize_history_source", "let keeper_decision_log_path")
adapters += "module Keeper_types_support = struct\n" + policy + "\nend;;\n"
adapters += r'''
module Keeper_types_profile = struct let take n xs = List.take n xs end;;
module Json_util = struct let float_opt_to_json = function None -> `Null | Some x -> `Float x end;;
module Keeper_context_core = struct
 (* Valid persisted text-block fixture adapter; the full message decoder is not under test. *)
 let text_of_history_jsonl_json json = Yojson.Safe.Util.(json |> member "content_blocks" |> to_list
   |> List.map (fun block -> block |> member "text" |> to_string) |> String.concat "")
end;;
let read_tail_lines_or_empty ~site:_ path ~max_bytes:_ ~max_lines:_ = In_channel.with_open_text path In_channel.input_lines;;
module Dashboard_http_helpers = struct let keeper_tail_lines_or_empty = read_tail_lines_or_empty end;;
'''
identity = read(args.after, "lib/keeper/keeper_identity.ml").split("module Keeper_id = struct", 1)[1]
adapters += "module Keeper_identity = struct\nmodule Keeper_id = struct" + identity + "\nend;;\n"
for module, path in (("Board_addressing", "lib/board_addressing/board_addressing.ml"),
                     ("Keeper_lane_mentions", "lib/keeper/keeper_lane_mentions.ml")):
    adapters += f"module {module} = struct\n" + read(args.after, path) + "\nend;;\n"
adapters += "module Keeper_text_processing = struct\n" + read(args.before, "lib/keeper/keeper_text_processing.ml") + "\nend;;\n"
adapters += "module Keeper_execution = Keeper_text_processing;;\nopen Keeper_text_processing;;\n"
fixtures = r'''
let row ~role ~source text = `Assoc ["role",`String role;"source",`String source;"ts_unix",`Float 1.;
 "content_blocks",`List [`Assoc ["type",`String "text";"text",`String text]]];;
let with_rows rows work =
 let path = Filename.temp_file "history-probe-" ".jsonl" in
 Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
 Out_channel.with_open_text path (fun oc -> List.iter (fun row -> output_string oc (Yojson.Safe.to_string row ^ "\n")) rows);
 work path);;
let content json = Yojson.Safe.Util.(json |> to_list |> List.map (fun item -> item |> member "content" |> to_string));;
'''
for label, revision in (("before", args.before), ("after", args.after)):
    script = adapters + "module Metrics = struct\n" + read(revision, "lib/dashboard/dashboard_http_keeper_metrics.ml") + "\nend;;\n"
    extra = " ~filter_fragments:true" if label == "before" else ""
    binding = "conversation,recent,counts,n,_,_" if label == "before" else "conversation,recent,counts,n"
    script += f'let summarize path = let {binding} = Metrics.keeper_history_summary_json ~all_keeper_names:["self";"alice";"art"] ~keeper_name:"self" ~history_path:path{extra} in conversation,recent,counts,n;;\n'
    status = read(revision, "lib/keeper/keeper_status_detail.ml")
    start = "         let history_filter_fragments =" if label == "before" else "         let (history_tail, history_raw_count) ="
    script += r'''
let status_projection history_path =
 let bool_default_true_of_env _ = true in
 let include_history_tail = true and tail_bytes = 10000 and tail_messages = 10 and now_ts = 2. in
 let tail_order = () in let apply_tail_order () rows = rows in
''' + section(status, start, "        (* No tool call log") + " (history_tail,history_raw_count);;\n" + fixtures
    script += r'''
let () =
 let answers = ["OK";"42";"완료";"https://example.com/or"] in
 with_rows (List.map (row ~role:"assistant" ~source:"direct_assistant") answers @
   [row ~role:"assistant" ~source:"internal_assistant" "internal"]) (fun path ->
 let conversation,_,_,_ = summarize path in let status,_ = status_projection path in
''' + (' let expected = [] in\n' if label == "before" else ' let expected = answers in\n') + r'''
 assert (content conversation = expected); assert (content status = expected);
''' + f' Printf.printf "history {label}: dashboard_visible=%d status_visible=%d\\n" (List.length (content conversation)) (List.length (content status)));;\n'
    script += r'''
let () =
 let texts = ["partial artwork report";"email@alice.com";"@alicex";"the code is `@alice`";
   "Thanks (@ALICE), @alice and @art.";"@@unknown @alice"] in
 with_rows (List.map (row ~role:"user" ~source:"direct_user") texts) (fun path ->
 let _,recent,counts,n = summarize path in let addressed = Yojson.Safe.Util.(recent |> to_list |> List.length) in
''' + f' assert (n=6 && addressed={6 if label == "before" else 1});\n' + f' Printf.printf "mentions {label}: rows=%d addressed_user_rows=%d counts=%s\\n" n addressed (Yojson.Safe.to_string counts));;\n'
    if label == "after":
        script = script.replace(" let bool_default_true_of_env _ = true in\n", "")
    run(script)

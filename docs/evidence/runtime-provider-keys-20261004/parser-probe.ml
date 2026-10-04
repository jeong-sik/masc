let fixture key = Printf.sprintf {|[providers.first]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/tmp/codex-first"
%s = "codex"
[models.sol]
api-name = "gpt-6-sol"
max-context = 272000
[models.next]
api-name = "next-sol"
max-context = 272000
[model_sets.codex]
models = ["sol", "next"]
[first.sol]
enabled = true
|} key
let () =
 List.iter (fun key ->
   match Runtime_toml.parse_string (fixture key) with
   | Ok config -> Printf.printf "%s=accepted:%s\n" key
       (String.concat "," (List.sort String.compare (List.map Runtime_schema.binding_key config.bindings)))
   | Error errors -> Printf.printf "%s=rejected:%s\n" key
       (String.concat "," (List.map (fun (e:Runtime_toml.parse_error)->e.path) errors)))
   ["model-set";"model_set";"model-sets"];
 match Runtime_toml.parse_file Sys.argv.(1) with
 | Ok config -> Printf.printf "shipped_provider_tables=accepted:%d\n" (List.length config.providers)
 | Error errors -> Printf.printf "shipped_provider_tables=rejected:%s\n"
     (String.concat "," (List.map (fun(e:Runtime_toml.parse_error)->e.path) errors))

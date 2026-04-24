(* Canonical pairs. Keep this list short and justified — each entry is a
   promise that the named subsystem is documented to honor it.

   GIT_TERMINAL_PROMPT=0 — git/libcurl credential helpers must not open
     /dev/tty. Documented at https://git-scm.com/docs/git-config under
     [core.askPass] and git-credential(1).
   GIT_ASKPASS="" — explicitly empty disables any configured askpass
     helper for this subprocess without relying on unset semantics.
   GCM_INTERACTIVE=Never — git credential manager (Microsoft) honors this
     on Linux/macOS containers to refuse interactive dialogs.
   SSH_ASKPASS="" — same rationale for SSH-over-git URLs. *)

let env : (string * string) list =
  [
    "GIT_TERMINAL_PROMPT", "0";
    "GIT_ASKPASS", "";
    "GCM_INTERACTIVE", "Never";
    "SSH_ASKPASS", "";
  ]

let env_pairs =
  List.map (fun (k, v) -> k ^ "=" ^ v) env

let docker_args =
  List.concat_map (fun (k, v) -> [ "-e"; k ^ "=" ^ v ]) env

let docker_env_args = docker_args

let key_of_entry entry =
  match String.index_opt entry '=' with
  | None -> entry
  | Some i -> String.sub entry 0 i

let inject_into_environment existing =
  let override_keys =
    let t = Hashtbl.create (List.length env) in
    List.iter (fun (k, _) -> Hashtbl.replace t k ()) env;
    t
  in
  let filtered =
    Array.to_list existing
    |> List.filter (fun e ->
         not (Hashtbl.mem override_keys (key_of_entry e)))
  in
  Array.of_list (env_pairs @ filtered)

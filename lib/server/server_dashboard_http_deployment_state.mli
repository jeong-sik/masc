val deployment_state_json :
     build:Build_identity.t
  -> server_repo_commit:string option
  -> workspace_commit:string option
  -> resolved_base_commit:string option
  -> upstream_status:Server_git_probe.upstream_status
  -> source_mismatch:bool
  -> Yojson.Safe.t

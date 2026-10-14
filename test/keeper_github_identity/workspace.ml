type config = { base_path : string }

let default_config base_path = { base_path }
let keepers_runtime_dir config = Common.keepers_runtime_dir_of_base ~base_path:config.base_path

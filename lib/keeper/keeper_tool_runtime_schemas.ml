open Masc_domain

let artifact_read = Keeper_runtime_schemas_toml.artifact_read
let fusion = Keeper_runtime_schemas_toml.fusion
let fusion_status = Keeper_runtime_schemas_toml.fusion_status
let keeper_analyze_image = Keeper_runtime_schemas_toml.keeper_analyze_image

let schemas = [ artifact_read; fusion; fusion_status; keeper_analyze_image ]

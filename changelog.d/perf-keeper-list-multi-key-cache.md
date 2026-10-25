### Changed
- Retain multiple query keys per generation in `keeper_list_cache`, reuse the already-read persisted metadata row when effective Keeper profile resolution fails in `keeper_list_row_json`, and memoize parsed Keeper `.json` and `.toml` payloads by exact file content.

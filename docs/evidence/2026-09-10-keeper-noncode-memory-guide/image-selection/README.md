# Isolated image selection and continuation failure

The operator selected the CI-verified arm64 creative image in this isolated Keeper TOML. `masc_keeper_up` returned success. A later DeepSeek runtime assignment was persisted but returned `keeper_turn_in_flight`, so it did not restart the active autonomous turn. Readback records the desired configuration, not successful tool use from that image.

The new PDF continuation operation then failed with the default Ollama Cloud runtime weekly quota. Server logs showed checkpoint turn count 58 resumed on that default runtime while a subsequent autonomous agent start used the assigned DeepSeek runtime. This old c083 binary does not prove the direct-continuation fixes under development.

No readable replacement PDF or actual Keeper container-image transition is proven by these configuration receipts. The earlier PDF remains rejected. Production configuration was not changed.

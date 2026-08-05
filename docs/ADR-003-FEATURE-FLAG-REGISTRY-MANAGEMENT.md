# ADR-003: Feature Flag Registry Management

## Decision

`lib/config/feature_flag_registry.ml` is the single source of truth for supported
boolean feature flags.

- Every supported `MASC_*` boolean flag has exactly one registry entry.
- The registry default and the config reader default must agree.
- A flag is `Experimental` while its behavior is still being evaluated and
  `Active` once it is a supported operator control.
- A flag without a runtime behavior branch is deleted from the reader, registry,
  metrics, dashboard, tests, and operator documentation in the same change.
- Removed flags do not retain compatibility readers or lifecycle tombstones.

## Verification

Before adding or changing a flag:

```bash
rg 'env_name = "MASC_YOUR_FLAG"' lib/config/feature_flag_registry.ml
rg 'get_bool.*MASC_YOUR_FLAG' lib/config
scripts/check-feature-flag-consistency.sh
```

The registry tests enforce unique environment names, known categories, current
lifecycle serialization, lookup behavior, and category partitioning.

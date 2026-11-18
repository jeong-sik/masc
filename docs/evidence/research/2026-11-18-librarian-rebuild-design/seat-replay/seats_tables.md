#### 4.1 Main matrix (Keeper turns replayed; 168 h; "pfail" = whole-ask failure share)

| Scenario | asks/h | units per answer mean (p90/max) | lag close->commit p50 / p90 / p99 / max (min) | Librarian seat wait p90 / max (s) | Librarian seat-hours per hour, by slot | share of answers by slot | generations/day (x today's 118) | Keeper-turn waits | narrowings / CLI reached |
|---|---|---|---|---|---|---|---|---|---|
| mean A no-limit pfail=0.0000 | 67.7 | 1.45 (3/14) | 9 / 15 / 21 / 30 | 0 / 134 | opencode 3.28, glm 3.1, tinker 0.99, ollama 0.24, haiku 0.12 | opencode 42%, glm 40%, tinker 13%, ollama 3%, haiku 2% | 1625 (13.8x) | GLM p90 14 s, >900 s 0; ollama p90 9 s, >900 s 0 | 0 / 0 |
| mean A no-limit pfail=0.0066 | 67.4 | 1.47 (3/25) | 9 / 16 / 23 / 36 | 0 / 135 | opencode 3.3, glm 3.1, tinker 1.02, ollama 0.24, haiku 0.12 | opencode 42%, glm 40%, tinker 13%, ollama 3%, haiku 2% | 1618 (13.7x) | GLM p90 14 s, >900 s 0; ollama p90 12 s, >900 s 0 | 0 / 0 |
| mean A strict pfail=0.0000 | 67.7 | 1.45 (3/14) | 9 / 15 / 21 / 30 | 0 / 201 | opencode 3.28, glm 3.11, tinker 0.99, ollama 0.23, haiku 0.12 | opencode 42%, glm 40%, tinker 13%, ollama 3%, haiku 2% | 1624 (13.8x) | GLM p90 12 s, >900 s 0; ollama p90 10 s, >900 s 0 | 0 / 0 |
| mean A strict pfail=0.0066 | 67.5 | 1.47 (3/25) | 9 / 16 / 23 / 39 | 0 / 185 | opencode 3.29, glm 3.11, tinker 1.01, ollama 0.24, haiku 0.12 | opencode 42%, glm 40%, tinker 13%, ollama 3%, haiku 2% | 1619 (13.7x) | GLM p90 14 s, >900 s 0; ollama p90 8 s, >900 s 0 | 0 / 0 |
| mean B no-limit pfail=0.0000 | 66.5 | 1.48 (3/16) | 9 / 16 / 23 / 41 | 78 / 513 | glm 4.28, tinker 2.23, ollama 1.09 | glm 56%, tinker 29%, ollama 14% | 1595 (13.5x) | GLM p90 108 s, >900 s 0; ollama p90 271 s, >900 s 0 | 0 / 0 |
| mean B no-limit pfail=0.0066 | 66.2 | 1.50 (3/15) | 10 / 17 / 24 / 44 | 84 / 517 | glm 4.3, tinker 2.25, ollama 1.09 | glm 56%, tinker 30%, ollama 14% | 1590 (13.5x) | GLM p90 111 s, >900 s 0; ollama p90 288 s, >900 s 0 | 0 / 0 |
| mean B strict pfail=0.0000 | 66.2 | 1.49 (3/15) | 10 / 17 / 24 / 39 | 87 / 579 | glm 4.3, tinker 2.21, ollama 1.06 | glm 57%, tinker 29%, ollama 14% | 1588 (13.5x) | GLM p90 39 s, >900 s 0; ollama p90 127 s, >900 s 0 | 0 / 0 |
| mean B strict pfail=0.0066 | 66.3 | 1.49 (3/20) | 10 / 17 / 26 / 45 | 90 / 676 | glm 4.33, tinker 2.26, ollama 1.09 | glm 57%, tinker 29%, ollama 14% | 1592 (13.5x) | GLM p90 39 s, >900 s 0; ollama p90 143 s, >900 s 0 | 0 / 0 |
| mean C no-limit pfail=0.0000 | 108.0 | 1.48 (3/29) | 10 / 19 / 59 / 149 | 1 / 4 | glm 4.31, tinker 2.25, ollama 1.05, haiku 0.01 | glm 57%, tinker 29%, ollama 14% | 1593 (13.5x) | GLM p90 38 s, >900 s 0; ollama p90 96 s, >900 s 0 | 454 / 7002 |
| mean C no-limit pfail=0.0066 | 109.1 | 1.49 (3/31) | 10 / 20 / 50 / 95 | 1 / 3 | glm 4.31, tinker 2.25, ollama 1.08, haiku 0.01 | glm 56%, tinker 30%, ollama 14% | 1597 (13.5x) | GLM p90 39 s, >900 s 0; ollama p90 98 s, >900 s 0 | 485 / 7152 |
| mean C strict pfail=0.0000 | 108.8 | 1.48 (3/30) | 10 / 19 / 55 / 137 | 1 / 3 | glm 4.31, tinker 2.23, ollama 1.06, haiku 0.01 | glm 56%, tinker 30%, ollama 14% | 1591 (13.5x) | GLM p90 33 s, >900 s 0; ollama p90 112 s, >900 s 0 | 445 / 7134 |
| mean C strict pfail=0.0066 | 111.3 | 1.49 (3/31) | 10 / 20 / 52 / 101 | 1 / 3 | glm 4.33, tinker 2.27, ollama 1.08, haiku 0.01 | glm 56%, tinker 30%, ollama 14% | 1598 (13.5x) | GLM p90 39 s, >900 s 0; ollama p90 83 s, >900 s 0 | 477 / 7511 |
| mean D no-limit pfail=0.0000 | 77.1 | 1.28 (2/20) | 5 / 13 / 20 / 27 | 0 / 38 | glm 4.26, tinker 0.35, ollama 0.02 | tinker 51%, glm 48%, ollama 1% | 1851 (15.7x) | GLM p90 38 s, >900 s 0; ollama p90 0 s, >900 s 0 | 0 / 0 |
| mean D no-limit pfail=0.0066 | 77.5 | 1.28 (2/18) | 5 / 13 / 20 / 37 | 0 / 49 | glm 4.26, tinker 0.36, ollama 0.02 | tinker 51%, glm 48%, ollama 1% | 1861 (15.8x) | GLM p90 38 s, >900 s 0; ollama p90 0 s, >900 s 0 | 0 / 0 |
| mean D strict pfail=0.0000 | 76.8 | 1.28 (2/20) | 5 / 13 / 19 / 29 | 0 / 39 | glm 4.28, tinker 0.34, ollama 0.02 | tinker 50%, glm 49%, ollama 1% | 1844 (15.6x) | GLM p90 37 s, >900 s 0; ollama p90 0 s, >900 s 0 | 0 / 0 |
| mean D strict pfail=0.0066 | 77.2 | 1.28 (2/27) | 5 / 13 / 20 / 39 | 0 / 73 | glm 4.28, tinker 0.36, ollama 0.02 | tinker 51%, glm 48%, ollama 1% | 1853 (15.7x) | GLM p90 36 s, >900 s 0; ollama p90 0 s, >900 s 0 | 0 / 0 |
| p90x1.69 A no-limit pfail=0.0000 | 91.9 | 1.81 (4/22) | 10 / 16 / 22 / 31 | 0 / 361 | opencode 3.51, glm 2.8, tinker 2.4, ollama 1.03, haiku 0.8 | opencode 33%, glm 27%, tinker 23%, ollama 10%, haiku 8% | 2206 (18.7x) | GLM p90 80 s, >900 s 0; ollama p90 3931 s, >900 s 14181 | 0 / 0 |
| p90x1.69 A no-limit pfail=0.0066 | 92.0 | 1.82 (4/22) | 10 / 16 / 24 / 52 | 0 / 353 | opencode 3.52, glm 2.82, tinker 2.45, ollama 1.04, haiku 0.81 | opencode 33%, glm 26%, tinker 23%, ollama 10%, haiku 8% | 2208 (18.7x) | GLM p90 89 s, >900 s 0; ollama p90 3931 s, >900 s 14181 | 0 / 0 |
| p90x1.69 A strict pfail=0.0000 | 92.2 | 1.80 (4/23) | 10 / 16 / 22 / 33 | 0 / 413 | opencode 3.51, glm 2.83, tinker 2.42, ollama 1.01, haiku 0.78 | opencode 33%, glm 26%, tinker 23%, ollama 10%, haiku 8% | 2212 (18.7x) | GLM p90 61 s, >900 s 0; ollama p90 3931 s, >900 s 14181 | 0 / 0 |
| p90x1.69 A strict pfail=0.0066 | 91.7 | 1.82 (4/30) | 10 / 17 / 24 / 36 | 0 / 475 | opencode 3.52, glm 2.83, tinker 2.48, ollama 1.02, haiku 0.78 | opencode 33%, glm 27%, tinker 23%, ollama 10%, haiku 7% | 2201 (18.7x) | GLM p90 62 s, >900 s 0; ollama p90 3931 s, >900 s 14181 | 0 / 0 |
| p90x1.69 B no-limit pfail=0.0000 | 80.0 | 2.08 (5/33) | 14 / 25 / 40 / 53 | 450 / 1335 | glm 3.65, tinker 3.34, ollama 2.18 | glm 40%, tinker 36%, ollama 24% | 1920 (16.3x) | GLM p90 497 s, >900 s 674; ollama p90 4332 s, >900 s 21095 | 0 / 0 |
| p90x1.69 B no-limit pfail=0.0066 | 79.8 | 2.10 (5/25) | 14 / 26 / 40 / 60 | 451 / 1369 | glm 3.65, tinker 3.34, ollama 2.19 | glm 40%, tinker 36%, ollama 24% | 1915 (16.2x) | GLM p90 505 s, >900 s 656; ollama p90 4298 s, >900 s 21748 | 0 / 0 |
| p90x1.69 B strict pfail=0.0000 | 79.0 | 2.10 (5/35) | 14 / 26 / 40 / 58 | 487 / 1576 | glm 3.63, tinker 3.31, ollama 2.16 | glm 40%, tinker 36%, ollama 24% | 1895 (16.1x) | GLM p90 110 s, >900 s 0; ollama p90 3931 s, >900 s 14297 | 0 / 0 |
| p90x1.69 B strict pfail=0.0066 | 79.8 | 2.09 (5/36) | 14 / 26 / 41 / 74 | 461 / 1712 | glm 3.64, tinker 3.33, ollama 2.14 | glm 40%, tinker 37%, ollama 24% | 1914 (16.2x) | GLM p90 107 s, >900 s 0; ollama p90 3931 s, >900 s 14282 | 0 / 0 |
| p90x1.69 C no-limit pfail=0.0000 | 394.1 | 2.08 (4/123) | 16 / 67 / 165 / 240 | 2 / 5 | glm 3.65, tinker 3.34, ollama 2.19, haiku 0.09 | glm 40%, tinker 37%, ollama 24% | 1915 (16.2x) | GLM p90 102 s, >900 s 0; ollama p90 3931 s, >900 s 15496 | 1464 / 31270 |
| p90x1.69 C no-limit pfail=0.0066 | 391.8 | 2.10 (4/185) | 16 / 83 / 215 / 300 | 2 / 5 | glm 3.64, tinker 3.32, ollama 2.16, haiku 0.09 | glm 40%, tinker 37%, ollama 24% | 1911 (16.2x) | GLM p90 106 s, >900 s 0; ollama p90 3931 s, >900 s 14357 | 1460 / 31056 |
| p90x1.69 C strict pfail=0.0000 | 386.8 | 2.10 (4/117) | 16 / 68 / 188 / 348 | 2 / 5 | glm 3.6, tinker 3.3, ollama 2.14, haiku 0.09 | glm 40%, tinker 36%, ollama 23% | 1894 (16.0x) | GLM p90 94 s, >900 s 0; ollama p90 3931 s, >900 s 14311 | 1408 / 30633 |
| p90x1.69 C strict pfail=0.0066 | 401.8 | 2.10 (4/104) | 17 / 70 / 170 / 248 | 2 / 5 | glm 3.64, tinker 3.33, ollama 2.16, haiku 0.09 | glm 39%, tinker 37%, ollama 24% | 1916 (16.2x) | GLM p90 91 s, >900 s 0; ollama p90 3931 s, >900 s 15435 | 1499 / 32034 |
| p90x1.69 D no-limit pfail=0.0000 | 130.5 | 1.27 (2/19) | 1 / 10 / 16 / 28 | 0 / 112 | glm 3.31, tinker 0.86, ollama 0.09 | tinker 74%, glm 22%, ollama 4% | 3132 (26.5x) | GLM p90 98 s, >900 s 0; ollama p90 3931 s, >900 s 14181 | 0 / 0 |
| p90x1.69 D no-limit pfail=0.0066 | 129.3 | 1.29 (2/22) | 1 / 10 / 18 / 30 | 0 / 92 | glm 3.33, tinker 0.88, ollama 0.12 | tinker 74%, glm 22%, ollama 4% | 3104 (26.3x) | GLM p90 90 s, >900 s 0; ollama p90 3931 s, >900 s 14181 | 0 / 0 |
| p90x1.69 D strict pfail=0.0000 | 129.8 | 1.28 (2/24) | 1 / 10 / 18 / 26 | 0 / 105 | glm 3.31, tinker 0.86, ollama 0.09 | tinker 74%, glm 22%, ollama 4% | 3116 (26.4x) | GLM p90 68 s, >900 s 0; ollama p90 3931 s, >900 s 14181 | 0 / 0 |
| p90x1.69 D strict pfail=0.0066 | 129.6 | 1.29 (2/29) | 1 / 10 / 18 / 32 | 0 / 142 | glm 3.34, tinker 0.87, ollama 0.1 | tinker 74%, glm 22%, ollama 4% | 3111 (26.4x) | GLM p90 86 s, >900 s 0; ollama p90 3931 s, >900 s 14181 | 0 / 0 |

Rows with L=4 are in `seats_sim.out`; §4.3 shows the run-limit effect.

#### 4.2 Fixed GLM seats held by Keeper turns (variant B, no Keeper replay, no failures)

| Scenario | asks/h | units per answer mean (p90/max) | lag close->commit p50 / p90 / p99 / max (min) | Librarian seat wait p90 / max (s) | Librarian seat-hours per hour, by slot | share of answers by slot | generations/day (x today's 118) | Keeper-turn waits | narrowings / CLI reached |
|---|---|---|---|---|---|---|---|---|---|
| mean B fixed GLM seats held by Keeper turns = 0 | 67.3 | 1.46 (3/18) | 9 / 16 / 22 / 31 | 0 / 383 | glm 5.61, tinker 1.54, ollama 0.55 | glm 73%, tinker 20%, ollama 7% | 1616 (13.7x) | not replayed | 0 / 0 |
| mean B fixed GLM seats held by Keeper turns = 2 | 66.8 | 1.47 (3/14) | 9 / 16 / 22 / 36 | 29 / 500 | glm 4.41, tinker 2.18, ollama 1.05 | glm 58%, tinker 28%, ollama 14% | 1602 (13.6x) | not replayed | 0 / 0 |
| mean B fixed GLM seats held by Keeper turns = 4 | 65.6 | 1.50 (3/16) | 10 / 17 / 25 / 37 | 143 / 674 | glm 3.0, tinker 2.74, ollama 1.77 | glm 40%, tinker 37%, ollama 24% | 1575 (13.3x) | not replayed | 0 / 0 |
| mean B fixed GLM seats held by Keeper turns = 6 | 62.6 | 1.57 (3/16) | 11 / 20 / 30 / 41 | 317 / 859 | tinker 3.17, ollama 2.57, glm 1.4 | tinker 45%, ollama 36%, glm 20% | 1502 (12.7x) | not replayed | 0 / 0 |
| p90x1.69 B fixed GLM seats held by Keeper turns = 0 | 91.1 | 1.82 (4/20) | 10 / 17 / 23 / 33 | 79 / 428 | glm 6.15, tinker 2.63, ollama 1.62 | glm 59%, tinker 25%, ollama 16% | 2185 (18.5x) | not replayed | 0 / 0 |
| p90x1.69 B fixed GLM seats held by Keeper turns = 2 | 87.9 | 1.89 (4/23) | 11 / 19 / 26 / 35 | 190 / 588 | glm 4.65, tinker 3.04, ollama 2.4 | glm 46%, tinker 30%, ollama 24% | 2109 (17.9x) | not replayed | 0 / 0 |
| p90x1.69 B fixed GLM seats held by Keeper turns = 4 | 82.8 | 2.01 (4/23) | 13 / 22 / 30 / 41 | 331 / 785 | tinker 3.39, ollama 3.03, glm 3.02 | tinker 36%, ollama 32%, glm 32% | 1987 (16.8x) | not replayed | 0 / 0 |
| p90x1.69 B fixed GLM seats held by Keeper turns = 6 | 71.9 | 2.31 (5/35) | 17 / 28 / 38 / 54 | 568 / 1214 | tinker 3.58, ollama 3.38, glm 1.26 | tinker 44%, ollama 41%, glm 15% | 1726 (14.6x) | not replayed | 0 / 0 |

#### 4.3 Run-limit sensitivity (mean arrival, no failures)

| Scenario | asks/h | lag p50 / p90 / max (min) | Keeper-turn wait at GLM p50 / p90 / max (s); >60 s; >900 s | Keeper-turn wait at ollama p50 / p90 / max (s); >60 s; >900 s |
|---|---|---|---|---|
| mean B limit=None | 66.5 | 9 / 16 / 41 | 0 / 108 / 564; 5374; 0 | 25 / 271 / 631; 18783; 0 |
| mean B limit=1 | 67.2 | 9 / 16 / 33 | 0 / 204 / 4766; 6714; 1228 | 295 / 2414 / 6217; 27885; 14843 |
| mean B limit=4 | 66.8 | 9 / 16 / 38 | 0 / 118 / 1733; 5376; 301 | 248 / 2454 / 4305; 27043; 13613 |
| mean B limit=16 | 66.6 | 9 / 16 / 35 | 0 / 47 / 339; 2642; 0 | 125 / 1857 / 2681; 25474; 9985 |
| mean B limit=64 | 66.4 | 10 / 16 / 34 | 0 / 38 / 302; 1921; 0 | 16 / 492 / 1180; 17652; 1160 |
| mean B limit=256 | 66.4 | 10 / 17 / 36 | 0 / 36 / 348; 1740; 0 | 5 / 127 / 516; 10951; 0 |
| mean B limit=strict | 66.2 | 10 / 17 / 39 | 0 / 39 / 354; 1995; 0 | 3 / 127 / 384; 11123; 0 |
| mean D limit=None | 77.1 | 5 / 13 / 27 | 0 / 38 / 443; 2019; 0 | 0 / 0 / 77; 5; 0 |
| mean D limit=1 | 77.8 | 5 / 13 / 26 | 0 / 37 / 348; 2011; 0 | 0 / 0 / 95; 69; 0 |
| mean D limit=4 | 77.0 | 5 / 13 / 27 | 0 / 39 / 302; 2117; 0 | 0 / 0 / 47; 0; 0 |
| mean D limit=16 | 77.1 | 5 / 13 / 26 | 0 / 34 / 247; 1706; 0 | 0 / 0 / 36; 0; 0 |
| mean D limit=64 | 76.8 | 5 / 13 / 29 | 0 / 37 / 214; 1782; 0 | 0 / 0 / 36; 0; 0 |
| mean D limit=256 | 76.8 | 5 / 13 / 29 | 0 / 37 / 214; 1782; 0 | 0 / 0 / 36; 0; 0 |
| mean D limit=strict | 76.8 | 5 / 13 / 29 | 0 / 37 / 214; 1782; 0 | 0 / 0 / 36; 0; 0 |

# Benchmarks

Measured on 2026-10-14 on an Intel Core i7-10870H (2.20 GHz, 8 cores), with a verified release
build of Jess at `b12612f` on l3i 2.0.2.

```sh
jess run --package <package> --package-path jpk --capability filesystem.read \
  --capability filesystem.write <package>/bench/bench.jsl <scratch folder>
```

The bench writes a load order of twenty generated mods, thirty OpenMW Lua scripts each with
requires, handlers and API calls and an `.omwscripts` per mod, then indexes, queries, opens,
reviews and graphs it through the public API. Base is `e2db2bb` (the bench's own commit); head
is `d463129`. Each side ran the whole bench four times under one lock, base first in odd rounds
and head first in even ones. Each figure is the median of the four runs, each run itself the
median of seven batches. Each workload prints a digest of its answer, and base and head printed
the same digests in every round. A difference under 5 percent is noise.

| Workload | Base | Head | Ratio |
|---|---:|---:|---:|
| index, 600 scripts in 20 mods | 363.154 ms | 360.048 ms | no change |
| query: calls into one engine package | 8.226 ms | 7.817 ms | no change |
| query: local requires | 1.285 ms | 1.258 ms | no change |
| query: the most used symbols | 210.1 µs | 208.7 µs | no change |
| open, 600 scripts in 20 mods | 691.233 ms | 359.811 ms | 1.92x |
| review, default profile | 56.021 ms | 52.883 ms | no change |
| graph | 13.132 ms | 13.089 ms | no change |

Opening a workspace matched each script a manifest declares against every source path, and
normalized every one of those paths again for every declaration: 600 declarations over 600 paths
made 360,000 normalizations of three pattern substitutions each, and that was half of `open`. The
paths are now normalized once, in the order the old walk visited them, so when several paths end
with what a manifest names the first of them is still the one chosen. Opening is 1.9 times
faster. The query and review rows that read 1.05 and 1.06 run no changed code and are noise.

What is left of `open` and all of `index` is `@jess/analysis` parsing and walking each script,
which is Jess's built-in package, not this one; the indexer's own packed stores and hash probes
were already written for the data they hold. Interning a symbol's dotted segments as spans of
the symbol, instead of substrings, measured no change and was not kept. No loop here converts to
the dialect exactly: the one-line accumulations append to lists that already hold rows, or walk a
set's keys.

## Which modules are native, and why

Jess compiles to machine code only what is marked (`--!native` on a module, `@native` on one
function), and every load pays for what is marked. A module carries `--!native` when a row below
spends its time there and the module is small (12 KB or less); a larger module carries `@native`
on the functions the row spends its time in, and nothing else.

Measured 2026-10-15 with `jess 0.1.0`, the verified release build of jess `07c38cb` on l3i
2.0.3, on the i7-10870H, the one-minute load 1.28 and 1.23 at the start of the two
sessions. In each session the bench ran alternately on this package and on a copy of it with
every module marked, three fresh runs of `bench/bench.jsl` each, every run's row the median of
its batches; a column is the median of the three, and a ratio is against the all-marked runs of
the same session. Which functions a row spends its time in comes from `jess run --profile` of
that row alone, unmarked. The load cost is a fresh `jess run --package <this package>
--package-path jpk` of a script that only requires `@openmw-install/workbench`, the two sides alternating, the
median of five each after one warm-up.

| Requiring `@openmw-install/workbench` | All marked | This state |
| --- | ---: | ---: |
| Unmarked | 0.312 s | 0.271 s |
| Final | 0.313 s | 0.276 s |

| Row | All marked (ms) | Unmarked / all marked | Final (ms) | Final / all marked |
| --- | ---: | ---: | ---: | ---: |
| index, 600 scripts in 20 mods | 309.9 | **1.196×** | 323.3 | 1.043× |
| query: calls into one engine package | 7.159 | **3.098×** | 7.564 | **1.057×** |
| query: local requires | 1.103 | **2.288×** | 1.944 | **1.761×** |
| query: the most used symbols | 0.1926 | **1.522×** | 0.2051 | **1.065×** |
| open, 600 scripts in 20 mods | 319.0 | **1.078×** | 329.5 | 1.033× |
| review, default profile | 45.80 | **1.313×** | 51.61 | **1.127×** |
| graph | 10.87 | **1.374×** | 10.84 | 0.997× |

What carries the directive (every module and function here is one a row spends its time in,
unmarked):

- Whole: `graph`, `knowledge`.
- `compact`, by function: `readValue`, `store.add`, `store.get`, `codec.encode`, `codec.decode`,
  `store.get`, `edgeLookup`, `edge`, `symbolPath`, `symbolText`, `referenceMatches`, `matches`,
  `next`, `next`, `usageRow`, `next`, `symbolRow`.
- `model`, by function: `setFrom`, `visit`, `parseManifest`, `sourceByScriptPath`.
- `review`, by function: `canProveUnknownMember`, `contextualMember`, `checkApi`, `compare`.
- Unmarked: `content`, `contract`, `init`, `link`.

Most of what this saves is `contract`, 982 KB of the engine's API contract that every load used
to compile to machine code and no row spends time in: requiring `@openmw-install/workbench` costs 0.037 s
less than all marked. The rows still above 5% are the default review (1.13x, about 6 ms of 46),
querying local requires (1.76x, 0.8 ms of 1.1), and two calls at 1.06x inside this protocol's
noise; together they cost less than one load saves.

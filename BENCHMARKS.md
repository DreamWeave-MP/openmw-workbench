# Benchmarks

Measured on 2026-10-14 on an Intel Core i7-10870H (2.20 GHz, 8 cores), with a verified release
build of Jess at `b12612f` on l3i 2.0.2.

```sh
jess run --package <package> --package-path jpk --capability filesystem.read \
  --capability filesystem.write <package>/bench/bench.luau <scratch folder>
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

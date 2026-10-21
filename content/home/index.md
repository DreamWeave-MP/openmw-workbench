+++
title = "openmw-workbench"
description = "A workbench over OpenMW data on Jess: plugins, saves, models and the VFS, queried through JessQL, in Luau."
date = 2026-10-21

[taxonomies]
tags = ["Jess", "Luau", "OpenMW"]

[extra]
sections = ["overview", "releases", "credits"]
+++

A workbench over OpenMW data on Jess: plugins, saves, models and the VFS, queried through JessQL, in Luau.

<!-- more -->

A [Jess](https://github.com/DreamWeave-MP/jess) package, `org.dreamweave.openmw-workbench`. Add it to a `jess.toml` and
`jess workspace sync` pins it from this site:

```toml
[dependencies]
"org.dreamweave.openmw-workbench" = "0.6"
```

Every release below is the package's own archive, with its content digest beside the archive's
SHA-256; `jess.lock` pins the first and checks both.

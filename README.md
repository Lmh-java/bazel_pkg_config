> [!IMPORTANT]  
> This Bazel rule repo is currently being tested. API are subject to change (July 18, 2025).

# bazel_pkg_config

Bazel rules for pkg-config tools with Bazel 8+ (Bzlmod) support and backward compatibility Bazel < 8 (WORKSPACE).
Forked from cherrry/bazel_pkg_config with Bazel 8+ specific modifications.

## Usage

### Bzlmod
```bzl
bazel_dep(name = "bazel_pkg_config", version = "master")
git_override(
    module_name = "bazel_pkg_config",
    # Replace with the lastest commit hash
    # We are also considering publishing this to Bazel Central Registry to simplify this process
    commit = "e247fb3b4007e63bb5110808df6e2c57eb518f16",
    remote = "https://github.com/Lmh-java/bazel_pkg_config.git",
)

pkg_config_extension = use_extension("@bazel_pkg_config//:pkg_config.bzl", "pkg_config_extension")
pkg_config_extension.package(
    name = "target_name",
    pkg_name = "library_to_load"
    # See pkg_config.bzl for more available options.
)
```

In your code:

```cc
#include "library_to_load/header.h"

// ...
```

In corresponding `BUILD` file:

```bzl
cc_library(
    name = "my_lib",
    deps = [
        "@target_name//:lib",
    ],
)
```

### WORKSPACE
> [!IMPORTANT]  
> WORKSPACE will be completed removed in Bazel 9 (See [Bazel Roadmap](https://bazel.build/about/roadmap#full_transition_to_bzlmod))
> Please consider migrating to Bzlmod.

Add the following in your `WORKSPACE`:

```bzl
http_archive(
    name = "bazel_pkg_config",
    strip_prefix = "bazel_pkg_config-master",
    urls = ["https://github.com/cherrry/bazel_pkg_config/archive/master.zip"],
)

load("@bazel_pkg_config//:pkg_config.bzl", "pkg_config")

pkg_config(
    name = "library_to_load",
    # See pkg_config.bzl for more available options.
)
```

Other parts remain the same with Bzlmod usage.

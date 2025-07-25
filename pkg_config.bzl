def _success(value):
    return struct(error = None, value = value)

def _error(message):
    return struct(error = message, value = None)

def _split(result, delimeter = " "):
    if result.error != None:
        return result
    return _success([arg for arg in result.value.strip().split(delimeter) if arg])

def _find_binary(ctx, binary_name):
    binary = ctx.which(binary_name)
    if binary == None:
        return _error("Unable to find binary: {}".format(binary_name))
    return _success(binary)

def _execute(ctx, binary, args):
    result = ctx.execute([binary] + args)
    if result.return_code != 0:
        return _error("Failed execute {} {}".format(binary, args))
    return _success(result.stdout)

def _pkg_config(ctx, pkg_config, pkg_name, args):
    return _execute(ctx, pkg_config, [pkg_name] + args)

def _check(ctx, pkg_config, pkg_name):
    exist = _pkg_config(ctx, pkg_config, pkg_name, ["--exists"])
    if exist.error != None:
        return _error("Package {} does not exist".format(pkg_name))

    if ctx.attr.version != "":
        version = _pkg_config(ctx, pkg_config, pkg_name, ["--exact-version", ctx.attr.version])
        if version.error != None:
            return _error("Require {} version = {}".format(pkg_name, ctx.attr.version))

    if ctx.attr.min_version != "":
        version = _pkg_config(ctx, pkg_config, pkg_name, ["--atleast-version", ctx.attr.min_version])
        if version.error != None:
            return _error("Require {} version >= {}".format(pkg_name, ctx.attr.min_version))

    if ctx.attr.max_version != "":
        version = _pkg_config(ctx, pkg_config, pkg_name, ["--max-version", ctx.attr.max_version])
        if version.error != None:
            return _error("Require {} version <= {}".format(pkg_name, ctx.attr.max_version))

    return _success(None)

def _extract_prefix(flags, prefix, strip = True):
    stripped, remain = [], []
    for arg in flags:
        if arg.startswith(prefix):
            if strip:
                stripped += [arg[len(prefix):]]
            else:
                stripped += [arg]
        else:
            remain += [arg]
    return stripped, remain

def _includes(ctx, pkg_config, pkg_name):
    includes = _split(_pkg_config(ctx, pkg_config, pkg_name, ["--cflags-only-I"]))
    if includes.error != None:
        return includes
    includes, unused = _extract_prefix(includes.value, "-I", strip = True)
    return _success(includes)

def _copts(ctx, pkg_config, pkg_name):
    return _split(_pkg_config(ctx, pkg_config, pkg_name, [
        "--cflags-only-other",
        "--libs-only-L",
        "--static",
    ]))

def _linkopts(ctx, pkg_config, pkg_name):
    return _split(_pkg_config(ctx, pkg_config, pkg_name, [
        "--libs-only-other",
        "--libs-only-l",
        "--static",
    ]))

def _ignore_opts(opts, ignore_opts):
    remain = []
    for opt in opts:
        if opt not in ignore_opts:
            remain += [opt]
    return remain

def _symlinks(ctx, basename, srcpaths):
    result = []
    root = ctx.path("")
    base = root.get_child(basename)
    rootlen = len(str(base)) - len(basename)
    for src in [ctx.path(p) for p in srcpaths]:
        dest = base.get_child(src.basename)
        if not dest.exists:
            ctx.symlink(src, dest)
        result += [str(dest)[rootlen:]]
    return result

def _deps(ctx, pkg_config, pkg_name):
    deps = _split(_pkg_config(ctx, pkg_config, pkg_name, [
        "--libs-only-L",
        "--static",
    ]))
    if deps.error != None:
        return deps
    deps, unused = _extract_prefix(deps.value, "-L", strip = True)
    result = []
    for dep in {dep: True for dep in deps}.keys():
        base = "deps_" + dep.replace("/", "_").replace(".", "_")
        result += _symlinks(ctx, base, [dep])
    return _success(result)

def _fmt_array(array):
    return ",".join(['"{}"'.format(a) for a in array])

def _fmt_glob(array):
    return _fmt_array(["{}/**/*.h".format(a) for a in array])

def _get_current_platform(ctx):
    os_name = ctx.os.name
    os_name_lower = os_name.lower()
    platform = "unknown"

    if "windows" in os_name_lower:
        platform = "windows"
    elif "mac" in os_name_lower or "darwin" in os_name_lower:
        platform = "macos"
    elif "linux" in os_name_lower:
        platform = "linux"
    elif "freebsd" in os_name_lower:
        platform = "freebsd"
    return platform

def _pkg_config_impl(ctx):
    os_name = _get_current_platform(ctx)
    pkg_name = ctx.attr.pkg_name
    if os_name in ctx.attr.skip_platforms:
        ctx.template("BUILD", Label("//:BUILD.empty.tmpl"), substitutions = {
            "%{platform}": os_name,
        }, executable = False)
        # If we should not build on current platform, then the procedure finishes here.
        # We would consider this as successful.
        message_string = "Local lib '{}' skipped on platform {} by rule configuration".format(pkg_name, os_name)
        print(message_string)
        return _success(None)

    if pkg_name == "":
        pkg_name = ctx.attr.name

    pkg_config = _find_binary(ctx, "pkg-config")
    if pkg_config.error != None:
        return pkg_config
    pkg_config = pkg_config.value

    check = _check(ctx, pkg_config, pkg_name)
    if check.error != None:
        return check

    includes = _includes(ctx, pkg_config, pkg_name)
    if includes.error != None:
        return includes
    includes = includes.value
    includes = _symlinks(ctx, "includes", includes)
    strip_include = "includes"
    if len(includes) == 1:
        strip_include = includes[0]
    if ctx.attr.strip_include != "":
        strip_include += "/" + ctx.attr.strip_include

    ignore_opts = ctx.attr.ignore_opts
    copts = _copts(ctx, pkg_config, pkg_name)
    if copts.error != None:
        return copts
    copts = _ignore_opts(copts.value, ignore_opts)

    linkopts = _linkopts(ctx, pkg_config, pkg_name)
    if linkopts.error != None:
        return linkopts
    linkopts = _ignore_opts(linkopts.value, ignore_opts)

    deps = _deps(ctx, pkg_config, pkg_name)
    if deps.error != None:
        return deps
    deps = deps.value

    include_prefix = ctx.attr.name
    if ctx.attr.include_prefix != "":
        include_prefix = ctx.attr.include_prefix + "/" + ctx.attr.name

    build = ctx.template("BUILD", Label("//:BUILD.tmpl"), substitutions = {
        "%{name}": ctx.attr.name,
        "%{hdrs}": _fmt_glob(includes),
        "%{includes}": _fmt_array(includes),
        "%{copts}": _fmt_array(copts),
        "%{extra_copts}": _fmt_array(ctx.attr.copts),
        "%{deps}": _fmt_array(deps),
        "%{extra_deps}": _fmt_array(ctx.attr.deps),
        "%{linkopts}": _fmt_array(linkopts),
        "%{extra_linkopts}": _fmt_array(ctx.attr.linkopts),
        "%{strip_include}": strip_include,
        "%{include_prefix}": include_prefix,
    }, executable = False)

_pkg_config_repository = repository_rule(
    attrs = {
        "pkg_name": attr.string(doc = "Package name for pkg-config query, default to name."),
        "include_prefix": attr.string(doc = "Additional prefix when including file, e.g. third_party. Compatible with strip_include option to produce desired include paths."),
        "strip_include": attr.string(doc = "Strip prefix when including file, e.g. libs, files not included will be invisible. Compatible with include_prefix option to produce desired include paths."),
        "version": attr.string(doc = "Exact package version."),
        "min_version": attr.string(doc = "Minimum package version."),
        "max_version": attr.string(doc = "Maximum package version."),
        "deps": attr.string_list(doc = "Dependency targets."),
        "linkopts": attr.string_list(doc = "Extra linkopts value."),
        "copts": attr.string_list(doc = "Extra copts value."),
        "ignore_opts": attr.string_list(doc = "Ignore listed opts in copts or linkopts."),
        "skip_platforms": attr.string_list(default = [], doc = "Platforms to skip (currently supports 'windows', 'linux', 'mac', 'darwin', and 'freebsd')",)
    },
    local = True,
    implementation = _pkg_config_impl,
)

# Maintain backward compatibility for WORKSPACE usage
pkg_config_repository = _pkg_config_repository

def _pkg_config_extension_impl(module_ctx):
    for module in module_ctx.modules:
        for tag in module.tags.package:
            _pkg_config_repository(
                name = tag.name,
                pkg_name = tag.pkg_name,
                include_prefix = tag.include_prefix,
                strip_include = tag.strip_include,
                version = tag.version,
                min_version = tag.min_version,
                max_version = tag.max_version,
                deps = tag.deps,
                linkopts = tag.linkopts,
                copts = tag.copts,
                ignore_opts = tag.ignore_opts,
                skip_platforms = tag.skip_platforms,
            )

pkg_config_extension = module_extension(
    implementation = _pkg_config_extension_impl,
    tag_classes = {
        "package": tag_class(attrs = {
            "name": attr.string(mandatory = True),
            "pkg_name": attr.string(default = ""),
            "include_prefix": attr.string(default = ""),
            "strip_include": attr.string(default = ""),
            "version": attr.string(default = ""),
            "min_version": attr.string(default = ""),
            "max_version": attr.string(default = ""),
            "deps": attr.string_list(default = []),
            "linkopts": attr.string_list(default = []),
            "copts": attr.string_list(default = []),
            "ignore_opts": attr.string_list(default = []),
            "skip_platforms": attr.string_list(default = []),
        }),
    }
)

import("core.base.json")
import("lib.detect.find_tool")
import("rustc_args")
import("cfg")

---@class CargoTarget
---@field name string
---@field kind string[]
---@field crate_types string[]
---@field src_path string
---@field edition string

---@class CargoResolvedDep
---@field name string
---@field pkg string
---@field dep_kinds {kind: string?, target: string?}[]

---@class CargoResolveNode
---@field id string
---@field deps CargoResolvedDep[]
---@field features string[]

---@class CargoPackage
---@field id string
---@field name string
---@field version string
---@field edition string
---@field manifest_path string
---@field targets CargoTarget[]
---@field authors string[]
---@field description? string
---@field homepage? string
---@field repository? string
---@field license? string
---@field license_file? string
---@field readme? string
---@field rust_version? string

---@class CargoBuildMessage
---@field reason string
---@field package_id string
---@field target? CargoTarget
---@field filenames? string[]
---@field features? string[]
---@field profile? {debug_assertions: boolean, test: boolean}
---@field cfgs? string[]
---@field env? string[][]
---@field out_dir? string

---@class CargoInstall
---@field dir string
---@field target? string
---@field profile string
---@field target_dir string
---@field manifest string
---@field root CargoResolveNode
---@field packages table<string, CargoPackage>
---@field nodes table<string, CargoResolveNode>
---@field unfiltered_nodes? table<string, CargoResolveNode>
---@field host_cfg? table<string, boolean>
---@field libraries table<string, CargoTarget>
---@field messages table<string, CargoBuildMessage[]>
---@field files table<string, string[]>

---@class CargoResolvedUnit
---@field package_id string
---@field cargo_target CargoTarget
---@field feature_set string[]
---@field compilation_context "host"|"target"
---@field source_path string
---@field install CargoInstall
---@field target string
---@field cfg string[]
---@field env table<string, string>
---@field proc_macro boolean
---@field artifact? string
---@field build_artifact? string
---@field deps CargoResolvedDep[]

local function contains(list, value)
    return table.contains(list or {}, value)
end

local function normalize(name)
    return (name:gsub("-", "_"))
end

local function is_proc_macro(target)
    return contains(target.kind, "proc-macro")
end

local function add_metadata(install, metadata)
    local nodes = {}
    for _, item in ipairs(metadata.packages) do
        install.packages[item.id] = item
        for _, target in ipairs(item.targets) do
            if is_proc_macro(target) or contains(target.crate_types, "lib") or
                contains(target.crate_types, "rlib") or contains(target.crate_types, "dylib") then
                local previous = install.libraries[item.id]
                assert(not previous or previous.src_path == target.src_path,
                    "multiple Rust library targets for %s", item.id)
                install.libraries[item.id] = target
            end
        end
    end
    for _, node in ipairs(metadata.resolve.nodes) do
        nodes[node.id] = node
    end
    return nodes
end

local function query_nodes(install, triple)
    local cargo = assert(find_tool("cargo"), "cargo not found")
    local argv = {"metadata", "--frozen", "--format-version", "1", "--manifest-path", install.manifest}
    if triple then table.join2(argv, "--filter-platform", triple) end
    local data = os.iorunv(cargo.program, argv, {curdir = path.directory(install.manifest)})
    local metadata = assert(json.decode(data))
    assert(metadata.resolve and metadata.resolve.root == install.root.id, "Cargo root has changed")
    return add_metadata(install, metadata)
end

local function matches_artifact(file, target)
    local filename = path.filename(file)
    local stem, ext = filename:match("^(.+)%.([^.]+)$")
    if not stem then return false end
    local dynamic = ext == "dll" or ext == "dylib" or ext == "so"
    if is_proc_macro(target) and not dynamic then return false end
    if not dynamic and ext ~= "rlib" and ext ~= "rmeta" then return false end
    stem = stem:gsub("%-%x+$", "")
    local name = normalize(target.name)
    return stem == "lib" .. name or (ext == "dll" and stem == name)
end

---@param file? string
---@return table<string, CargoBuildMessage[]>
function read_messages(file)
    local messages = {}
    if file then
        for line in assert(io.readfile(file)):gmatch("[^\r\n]+") do
            local message = assert(json.decode(line))
            if message.reason == "compiler-artifact" or message.reason == "build-script-executed" then
                local id = assert(message.package_id, "Cargo build message is missing package_id")
                messages[id] = messages[id] or {}
                table.insert(messages[id], message)
            end
        end
    end
    return messages
end

---@param dir string
---@param host string
---@param profile string
---@param messages table<string, CargoBuildMessage[]>
---@param report fun(message: string)
---@return CargoInstall
function read_install(dir, host, profile, messages, report)
    local file = path.join(dir, "metadata.txt")
    assert(os.isfile(file), "Cargo metadata is missing: %s", file)
    local saved = assert(io.load(file))
    local metadata = assert(json.decode(saved.metadata))
    local install = {
        dir = dir, profile = profile, target_dir = metadata.target_directory,
        packages = {}, libraries = {}, messages = messages, files = {}
    }
    install.nodes = add_metadata(install, metadata)
    install.root = assert(install.nodes[metadata.resolve.root], "no synthetic Cargo root in %s", file)
    install.manifest = install.packages[install.root.id].manifest_path
    local config_file = path.join(path.directory(install.manifest), ".cargo", "config.toml")
    local config = os.isfile(config_file) and io.readfile(config_file)
    install.target = config and config:match('target%s*=%s*"([^"]+)"') or nil
    if not install.target and not os.isdir(path.join(dir, "lib", "host")) then
        -- Xmake runs metadata without --filter-platform when it builds for the implicit host.
        try {
            function ()
                local nodes = query_nodes(install, host)
                local root = assert(nodes[install.root.id], "missing filtered Cargo root")
                install.nodes, install.root = nodes, root
            end,
            catch {function (err) report("cannot filter Cargo graph for " .. host .. ": " .. tostring(err)) end}
        }
    elseif not install.target then
        report("cannot identify the Cargo target for " .. dir)
    end
    return install
end

-- A host unit can be reached through a target-only dependency of the synthetic root.
-- A host-filtered metadata query may then omit the unit or its dependencies.
local function matches_platform(platform, host, host_cfg)
    if platform == nil or platform == json.null then return true end
    local expr = platform:match("^cfg%((.*)%)$")
    if not expr then return platform == host end
    local pos = 1
    local function consume(pattern)
        local first, last, value = expr:find("^%s*" .. pattern, pos)
        if first then
            pos = last + 1
            return value or true
        end
    end
    local function evaluate()
        local name = assert(consume("([%w_]+)"), "invalid Cargo cfg: %s", platform)
        if consume("=") then
            local value = assert(consume('("[^"]*")'), "invalid Cargo cfg value: %s", platform)
            return host_cfg[name .. "=" .. value] == true
        end
        if not consume("%(") then return host_cfg[name] == true end
        assert(name == "all" or name == "any" or name == "not", "invalid Cargo cfg operator: %s", name)
        local count, matched = 0, 0
        while not consume("%)") do
            if evaluate() then matched = matched + 1 end
            count = count + 1
            if not consume(",") then
                assert(consume("%)"), "invalid Cargo cfg: %s", platform)
                break
            end
        end
        if name == "not" then
            assert(count == 1, "invalid Cargo cfg: %s", platform)
            return matched == 0
        end
        return name == "all" and matched == count or name == "any" and matched > 0
    end
    local matched = evaluate()
    assert(consume("$"), "invalid Cargo cfg: %s", platform)
    return matched
end

---@param install CargoInstall
---@param context "host"|"target"
---@param host string
---@param report fun(message: string)
---@param id string
---@return CargoResolveNode?
local function node_for(install, context, host, report, id)
    if context ~= "host" or not install.target or install.target == host then return install.nodes[id] end
    if not install.unfiltered_nodes then
        install.unfiltered_nodes = try {
            function () return query_nodes(install) end,
            catch {function (err) report("cannot resolve Cargo host graph for " .. host .. ": " .. tostring(err)) end}
        } or {}
    end
    local node = install.unfiltered_nodes[id]
    if not node then return install.nodes[id] end
    if not install.host_cfg then
        install.host_cfg = try {
            function ()
                local rustc = assert(find_tool("rustc"), "rustc not found for Cargo host cfg")
                local output = os.iorunv(rustc.program, {"--print=cfg", "--target=" .. host},
                    {curdir = path.directory(install.manifest)})
                local flags = {}
                for line in output:gmatch("[^\r\n]+") do flags[line] = true end
                return flags
            end,
            catch {function (err) report("cannot query Cargo host cfg for " .. host .. ": " .. tostring(err)) end}
        }
        if not install.host_cfg then return install.nodes[id] end
    end
    local deps = {}
    for _, dep in ipairs(node.deps) do
        local kinds = {}
        for _, kind in ipairs(dep.dep_kinds) do
            if matches_platform(kind.target, host, install.host_cfg) then table.insert(kinds, kind) end
        end
        if #kinds > 0 then table.insert(deps, {name = dep.name, pkg = dep.pkg, dep_kinds = kinds}) end
    end
    return {id = id, deps = deps, features = node.features}
end

---@param lib string
---@return string?
function install_dir(lib)
    lib = rustc_args.absolute(lib)
    if path.filename(lib) == "host" then lib = path.directory(lib) end
    if path.filename(lib) == "lib" then
        local dir = path.directory(lib)
        if os.isfile(path.join(dir, "metadata.txt")) then return dir end
    end
end

---@param node CargoResolveNode
---@return CargoResolvedDep[]
function normal_deps(node)
    local deps = {}
    for _, dep in ipairs(node.deps) do
        assert(type(dep.name) == "string" and dep.name ~= "", "missing Cargo import name in %s", node.id)
        for _, kind in ipairs(dep.dep_kinds) do
            if kind.kind == nil or kind.kind == json.null or kind.kind == "normal" then
                table.insert(deps, dep)
                break
            end
        end
    end
    return deps
end

local function libdir(install, context)
    local dir = path.join(install.dir, "lib")
    return install.target and context == "host" and path.join(dir, "host") or dir
end

local function installed_files(install, context)
    local dir = libdir(install, context)
    if not install.files[dir] then
        install.files[dir] = os.files(path.join(dir, "*"))
    end
    return install.files[dir]
end

---@param file string
---@return string
function artifact_key(file)
    return rustc_args.path_key(path.join(path.directory(file), path.basename(file)))
end

local function cargo_profile_dir(install, context)
    if install.target and context == "target" then
        return path.join(install.target_dir, install.target, install.profile)
    end
    return path.join(install.target_dir, install.profile)
end

local function artifacts(install, id, context)
    local results = {}
    local target = install.libraries[id]
    local depsdir = rustc_args.path_key(path.join(cargo_profile_dir(install, context), "deps"))
    for _, message in ipairs(install.messages[id] or {}) do
        if message.reason == "compiler-artifact" and message.target and
            rustc_args.path_key(message.target.src_path) == rustc_args.path_key(target.src_path) and
            not (message.profile and message.profile.test) then
            for _, file in ipairs(message.filenames or {}) do
                if rustc_args.path_key(path.directory(file)) == depsdir and matches_artifact(file, target) then
                    local installed = path.join(libdir(install, context), path.filename(file))
                    table.insert(results, {file = installed, message = message})
                end
            end
        end
    end
    return results
end

local function ids_matching_artifact(install, artifact)
    local ids = {}
    for id, target in pairs(install.libraries) do
        if id ~= install.root.id and matches_artifact(artifact, target) then
            table.insert(ids, id)
        end
    end
    return ids
end

---@param install CargoInstall
---@param artifact string
---@return string? package_id
---@return string? error
function resolve_extern(install, artifact)
    local dir = rustc_args.path_key(path.directory(artifact))
    local key = rustc_args.path_key(artifact)
    local direct = {}
    for _, dep in ipairs(normal_deps(install.root)) do direct[dep.pkg] = true end
    local possible, recorded = {}, {}
    for _, id in ipairs(ids_matching_artifact(install, artifact)) do
        local context = is_proc_macro(install.libraries[id]) and "host" or "target"
        if rustc_args.path_key(libdir(install, context)) == dir then
            table.insert(possible, id)
            for _, record in ipairs(artifacts(install, id, context)) do
                if rustc_args.path_key(record.file) == key then recorded[id] = true end
            end
        end
    end
    local ids = table.orderkeys(recorded)
    if #ids == 0 then ids = possible end
    if #ids ~= 1 then
        return nil, #ids > 1 and "multiple Cargo package IDs match the artifact" or
            "no Cargo library target matches the artifact"
    end
    if not direct[ids[1]] then return nil, "artifact is not a direct normal dependency of the Cargo root" end
    if #possible == 1 and not recorded[ids[1]] then
        local target = install.libraries[ids[1]]
        local context = is_proc_macro(target) and "host" or "target"
        for _, candidate in ipairs(installed_files(install, context)) do
            if artifact_key(candidate) ~= artifact_key(artifact) and matches_artifact(candidate, target) then
                return nil, "multiple installed Cargo artifacts match the library target"
            end
        end
    end
    return ids[1]
end

---@param install CargoInstall
---@param artifact string
---@return boolean
function owns(install, artifact)
    local dir = rustc_args.path_key(path.directory(artifact))
    return dir == rustc_args.path_key(libdir(install, "target")) or
        dir == rustc_args.path_key(libdir(install, "host"))
end

local function build_script(install, id, context, artifact)
    local profile_dir = rustc_args.path_key(path.join(cargo_profile_dir(install, context), "build")) .. "/"
    local matches = {}
    for _, message in ipairs(install.messages[id] or {}) do
        if message.reason == "build-script-executed" and message.out_dir and
            rustc_args.path_key(message.out_dir):startswith(profile_dir) then
            matches[message.out_dir] = message
        end
    end
    local dirs = table.orderkeys(matches)
    if #dirs <= 1 then return matches[dirs[1]] end
    -- Cargo dep-info records the actual OUT_DIR when the crate reads it via env!.
    if artifact then
        local depfile = path.join(cargo_profile_dir(install, context), "deps", path.basename(artifact)
            :gsub("^lib", "") .. ".d")
        if os.isfile(depfile) then
            for line in assert(io.readfile(depfile)):gmatch("[^\r\n]+") do
                local dir = line:match("^# env%-dep:OUT_DIR=(.*)$")
                if dir and matches[dir] then return matches[dir] end
            end
        end
    end
end

---@param install CargoInstall
---@param id string
---@param context "host"|"target"
---@param host string
---@param artifact? string
---@param report fun(message: string)
---@return CargoResolvedUnit?
function unit(install, id, context, host, artifact, report)
    local target = install.libraries[id]
    if target and is_proc_macro(target) then context = "host" end
    local node = node_for(install, context, host, report, id)
    target = install.libraries[id]
    local pkg = install.packages[id]
    if not (target and pkg) then
        report("missing Cargo library target for " .. id)
        return
    end
    if not os.isfile(target.src_path) then
        report("Cargo crate root is missing: " .. target.src_path)
        return
    end
    local proc_macro = is_proc_macro(target)
    if not node then
        report("missing Cargo resolve node for " .. id .. " (" .. context .. ")")
        return
    end
    local records, build = artifacts(install, id, context)
    local selected = artifact
    for _, record in ipairs(records) do
        if not selected or artifact_key(record.file) == artifact_key(selected) then
            if build and build ~= record.message then
                report("multiple Cargo compilation units match " .. id .. " (" .. context .. ")")
                build, artifact = nil, selected
                break
            end
            build, artifact = record.message, record.file
        end
    end
    if proc_macro and (not artifact or not os.isfile(artifact)) then
        artifact = nil
        local possible = {}
        for _, file in ipairs(installed_files(install, context)) do
            if matches_artifact(file, target) then
                local ids = ids_matching_artifact(install, file)
                if #ids == 1 and ids[1] == id then
                    local stem = artifact_key(file)
                    possible[stem] = possible[stem] or file
                end
            end
        end
        local stems = table.orderkeys(possible)
        if #stems == 1 then
            artifact = possible[stems[1]]
        else
            report("cannot identify a unique proc-macro artifact for " .. id .. " (" .. context .. ")")
        end
    end

    local feature_set = build and build.features or node.features
    local cfgs = {}
    for _, feature in ipairs(feature_set) do
        table.insert(cfgs, "feature=" .. assert(json.encode(feature)))
    end
    if build and build.profile and build.profile.debug_assertions then
        table.insert(cfgs, "debug_assertions")
    end
    local env = {
        CARGO_MANIFEST_DIR = path.directory(pkg.manifest_path), CARGO_MANIFEST_PATH = pkg.manifest_path,
        CARGO_PKG_NAME = pkg.name, CARGO_PKG_VERSION = pkg.version, CARGO_CRATE_NAME = normalize(target.name)
    }
    local major, minor, patch, pre = pkg.version:match("^(%d+)%.(%d+)%.(%d+)%-?([^+]*)")
    env.CARGO_PKG_VERSION_MAJOR = major
    env.CARGO_PKG_VERSION_MINOR = minor
    env.CARGO_PKG_VERSION_PATCH = patch
    env.CARGO_PKG_VERSION_PRE = pre
    env.CARGO_PKG_AUTHORS = table.concat(pkg.authors or {}, ":")
    for _, field in ipairs({"description", "homepage", "repository", "license", "license_file", "readme", "rust_version"}) do
        env["CARGO_PKG_" .. field:upper()] = type(pkg[field]) == "string" and pkg[field] or ""
    end
    local script = build and build_script(install, id, context, artifact)
    if script then
        cfgs = cfg.merge(cfgs, script.cfgs or {})
        for _, pair in ipairs(script.env or {}) do env[pair[1]] = pair[2] end
        env.OUT_DIR = script.out_dir
        if not os.isdir(env.OUT_DIR) then report("Cargo OUT_DIR is missing: " .. env.OUT_DIR) end
    else
        for _, item in ipairs(pkg.targets) do
            if contains(item.kind, "custom-build") then
                report("missing unambiguous Cargo build-script output for " .. id .. " (" .. context .. ")")
                break
            end
        end
    end
    return {
        package_id = id, cargo_target = target, feature_set = feature_set, compilation_context = context,
        source_path = target.src_path, install = install, target = context == "host" and host or (install.target or host),
        cfg = cfgs, env = env, proc_macro = proc_macro, artifact = artifact,
        build_artifact = build and artifact_key(artifact) or nil, deps = normal_deps(node)
    }
end

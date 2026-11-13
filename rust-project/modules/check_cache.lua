import("core.base.json")
import("rustc_args")

local compiler_versions = {}
local external_digests = {}

local function digest(value)
    return hash.uuid(assert(json.encode(value)))
end

local function compiler_version(program, cwd)
    local key = digest({program, os.getenv("PATH") or "", os.getenv("RUSTUP_TOOLCHAIN") or "",
                        os.getenv("RUSTUP_HOME") or ""})
    if not compiler_versions[key] then
        compiler_versions[key] = os.iorunv(program, {"-vV"}, {curdir = cwd})
    end
    return compiler_versions[key]
end

local function file_digest(file)
    if not os.isfile(file) then return false end
    return hash.xxhash128(file)
end

local function file_digests(files)
    local result = {}
    for _, file in ipairs(files) do result[file] = file_digest(file) end
    return result
end

local function external_files(unit, files, replaced)
    for _, ext in ipairs(unit.args.externs) do
        if ext.artifact and not replaced[rustc_args.path_key(ext.artifact)] then
            table.insert(files, ext.artifact)
        end
    end
    if unit.args.target and unit.args.target:endswith(".json") then
        table.insert(files, unit.args.target)
    end
    local dirs = unit.link and table.join(unit.args.search_dirs, unit.args.native_dirs) or unit.args.search_dirs
    for _, dir in ipairs(dirs) do
        for _, file in ipairs(os.files(path.join(dir, "*"))) do
            local ext = path.extension(file):lower()
            if (ext == ".rlib" or ext == ".rmeta" or ext == ".so" or ext == ".dll" or ext == ".dylib"
                or ext == ".a" or ext == ".lib") and not replaced[rustc_args.path_key(file)] then
                table.insert(files, file)
            end
        end
    end
    return files
end

local function external_fingerprints(files)
    local result = {}
    for _, file in ipairs(files) do
        local mtime, size = os.mtime(file), os.filesize(file)
        local cached = external_digests[file]
        if not cached or cached.mtime ~= mtime or cached.size ~= size then
            cached = {mtime = mtime, size = size, digest = file_digest(file)}
            external_digests[file] = cached
        end
        result[file] = cached.digest
    end
    return result
end

local function read_depinfo(depfile, cwd)
    local data = io.readfile(depfile)
    local files, env = {}, {}
    -- Rustc emits a phony rule for each input. These retain spaces and Windows drive letters.
    for line in data:gmatch("[^\r\n]+") do
        local name = line:match("^# env%-dep:([^=]+)")
        if name then
            local unescaped = name:gsub("\\(.)", {n = "\n", r = "\r", ["\\"] = "\\"})
            table.insert(env, unescaped)
        elseif line:endswith(":") then
            local file = line:sub(1, -2):gsub("\\ ", " ")
            table.insert(files, rustc_args.absolute(file, cwd))
        end
    end
    return files, env
end

local function env_digests(names)
    local result = {}
    for _, name in ipairs(names) do
        local value = os.getenv(name)
        result[name] = value and digest({value}) or false
    end
    return result
end

local function same(left, right)
    for key, value in pairs(left) do
        if right[key] ~= value then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function replay(diagnostics)
    io.stderr:write(io.readfile(diagnostics))
    io.flush(io.stderr)
end

function compile(unit, cwd, output, artifact, argv, revisions, external, replaced)
    local diagnostics = path.join(output, "diagnostics.jsonl")
    local depfile = path.join(output, "inputs.d")
    local statefile = path.join(output, "fingerprint.json")
    local state = os.isfile(statefile) and try {
        function () return json.decode(io.readfile(statefile)) end
    }
    local package_env = {}
    for name, value in table.orderpairs(unit.target:pkgenvs() or {}) do
        table.insert(package_env, {name, value})
    end
    local command = digest({1, unit.program, compiler_version(unit.program, cwd), argv, revisions, package_env,
                            os.getenv("RUSTC_BOOTSTRAP") or false, os.getenv("PATH") or false,
                            os.getenv("LIB") or false, os.getenv("LIBRARY_PATH") or false, os.getenv("SDKROOT") or false})
    local root = rustc_args.absolute(unit.root, cwd)
    local known = {root}
    if type(state) == "table" and type(state.sources) == "table" then
        table.join2(known, table.orderkeys(state.sources))
    end
    local previous = file_digests(known)
    local inputs = external_fingerprints(external_files(unit, external, replaced))
    if type(state) == "table" and state.command == command and type(state.revision) == "string"
        and type(state.sources) == "table" and type(state.external) == "table" and type(state.env) == "table"
        and os.isfile(artifact) and os.isfile(diagnostics)
        and same(state.sources, previous) and same(state.external, inputs)
        and same(state.env, env_digests(table.orderkeys(state.env))) then
        replay(diagnostics)
        return artifact, state.revision
    end

    os.mkdir(output)
    if os.isfile(statefile) then os.rm(statefile) end
    os.tryrm(artifact)
    os.tryrm(depfile)
    os.tryrm(diagnostics)
    local started = os.time()
    local status, err = os.execv(unit.program, argv, {curdir = cwd, stderr = diagnostics, try = true})
    if os.isfile(diagnostics) then replay(diagnostics) end
    assert(status ~= nil, "%s: could not run rustc: %s", unit.target:fullname(), err or "unknown error")
    if status ~= 0 then return false end
    assert(os.isfile(artifact), "%s: rustc did not produce a check artifact", unit.target:fullname())
    local revision = hash.uuid4()
    if os.isfile(depfile) then
        local files, env = read_depinfo(depfile, cwd)
        local sources = file_digests(files)
        local stable = sources[root]
        for file, value in pairs(sources) do
            if not value or (previous[file] ~= nil and previous[file] ~= value) or os.mtime(file) > started then
                stable = false
                break
            end
        end
        if stable and same(inputs, external_fingerprints(external)) then
            io.writefile(statefile, assert(json.encode({command = command, sources = sources, external = inputs,
                         env = env_digests(env), revision = revision})))
        end
    end
    return artifact, revision
end

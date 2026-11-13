import("rustc_args")
import("xmake_crates")
import("check_cache")

local replaced = {
    ["-o"] = true, ["--out-dir"] = true, ["--emit"] = true,
    ["--error-format"] = true, ["--json"] = true, ["--color"] = true
}

local function check_argv(argv, root, cwd, output, artifact, link, artifacts, depdirs)
    local emit = link and "link" or "metadata"
    local depfile = path.relative(path.join(output, "inputs.d"), cwd)
    local result = {"--error-format=json", "--emit=" .. emit .. ",dep-info=" .. depfile, "-o", artifact,
                    "-C", "incremental=" .. path.join(output, "incremental")}
    for _, dir in ipairs(depdirs) do
        table.insert(result, "-Ldependency=" .. dir)
    end

    local index = 1
    while index < #argv do
        local token = argv[index]
        local flag, value = token:match("^(%-%-[%w%-]+)=(.*)$")
        if not flag then flag, value = token:match("^(%-[oC])(.+)$") end
        flag = flag or token
        if replaced[flag] or flag == "--extern" or flag == "-C" or flag == "--codegen" then
            if not value then
                index = index + 1
                value = assert(argv[index], "missing value for rustc %s", flag)
            end
            if flag == "--extern" then
                local name, file = value:match("^([^=]+)=(.+)$")
                local artifact = file and artifacts[rustc_args.path_key(rustc_args.absolute(file, cwd))]
                table.join2(result, flag, artifact and (name .. "=" .. artifact) or value)
            elseif not replaced[flag] and not value:startswith("incremental=") then
                table.join2(result, flag, value)
            end
        else
            assert(token ~= "--", "rustc -- argument separator is unsupported")
            table.insert(result, token)
        end
        index = index + 1
    end
    table.insert(result, rustc_args.absolute(root, cwd))
    return result
end

local function with_package_env(target, run)
    local envs = target:pkgenvs()
    local oldenvs = envs and os.addenvs(envs)
    return try {
        run,
        finally {
            function (ok, err)
                if oldenvs then os.setenvs(oldenvs) end
                if not ok then raise(err) end
            end
        }
    }
end

local function check_target(unit, cwd, output, artifacts, depdirs, revisions, external)
    local target = unit.target
    local name = unit.args.name or path.basename(unit.root):gsub("-", "_")
    local filename = unit.link and path.filename(target:targetfile()) or "lib" .. name .. ".rmeta"
    local artifact = path.join(output, filename)
    local argv = check_argv(unit.argv, unit.root, cwd, output, artifact, unit.link, artifacts, depdirs)
    return with_package_env(target, function ()
        return check_cache.compile(unit, cwd, output, artifact, argv, revisions, external, artifacts)
    end)
end

function run(targets, cwd, cache)
    local units, ordered = {}, {}
    for _, target in table.orderpairs(targets) do
        local batch = target:is_enabled() and target:sourcebatches()["rust.build"]
        if batch then
            local program, argv = with_package_env(target, function ()
                return xmake_crates.buildargv(target, batch)
            end)
            units[target] = {target = target, program = program, argv = argv, root = batch.sourcefiles[1],
                             args = rustc_args.parse(argv, cwd)}
        end
    end
    local function enqueue(unit)
        if unit and not unit.queued then
            unit.queued = true
            table.insert(ordered, unit)
        end
    end
    for _, target in table.orderpairs(targets) do
        local unit = units[target]
        if unit and not unit.queued then
            for _, dep in ipairs(target:orderdeps()) do
                enqueue(units[dep])
            end
            enqueue(unit)
        end
    end
    -- A proc-macro is loaded by rustc, so its Rust dependencies also need codegen.
    for _, unit in ipairs(ordered) do
        if unit.args.proc_macro then
            unit.link = true
            for _, dep in ipairs(unit.target:orderdeps()) do
                if units[dep] then units[dep].link = true end
            end
        end
    end

    local success = true
    for _, unit in ipairs(ordered) do
        local artifacts, depdirs, revisions, external, blocked = {}, {}, {}, {}, false
        for _, dep in ipairs(unit.target:orderdeps()) do
            local dependency = units[dep]
            if dependency then
                if not dependency.artifact then
                    blocked = true
                    break
                end
                artifacts[rustc_args.path_key(rustc_args.absolute(dep:targetfile(), cwd))] = dependency.artifact
                table.insert(depdirs, path.directory(dependency.artifact))
                table.insert(revisions, dependency.revision)
            elseif dep:is_static() or dep:is_shared() then
                table.insert(external, rustc_args.absolute(dep:targetfile(), cwd))
            end
        end
        if not blocked then
            local output = path.join(cache, hash.uuid(unit.target:fullname()))
            unit.artifact, unit.revision = check_target(unit, cwd, output, artifacts, depdirs, revisions, external)
            if not unit.artifact then success = false end
        end
    end
    return success
end

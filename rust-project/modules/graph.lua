import("rustc_args")
import("cargo_crates")

---@class RustProjectDep
---@field crate integer Zero-based crate index
---@field name string

---@class RustProjectCrate
---@field display_name string
---@field root_module string
---@field edition string
---@field target string
---@field cfg string[]
---@field deps RustProjectDep[]
---@field env? table<string, string>
---@field is_workspace_member boolean
---@field is_proc_macro boolean
---@field proc_macro_dylib_path? string

---@class RustProject
---@field sysroot? string
---@field sysroot_src? string
---@field crates RustProjectCrate[]

---@class CrateGraphBuilder
---@field project RustProject
---@field report fun(message: string)
---@field xmake_artifacts table<string, integer[]>
---@field cargo_ids table<string, integer>
---@field cargo_installs table<string, CargoInstall|false>
---@field messages table<string, CargoBuildMessage[]>
local builder = {}

---@param report fun(message: string)
---@param messages table<string, CargoBuildMessage[]>
---@return CrateGraphBuilder
function new(report, messages)
    return table.join(builder, {
        project = {crates = {}}, report = report, xmake_artifacts = {}, cargo_ids = {},
        cargo_installs = {}, messages = messages
    }, builder)
end

local function normalize(name)
    return (name:gsub("-", "_"))
end

local function add_edge(graph, crate, name, id)
    for _, dep in ipairs(crate.deps) do
        if dep.name == name then
            if dep.crate ~= id then
                graph.report(crate.display_name .. ": conflicting extern name " .. name)
            end
            return
        end
    end
    table.insert(crate.deps, {name = name, crate = id})
end

---@param unit XmakeRustUnit
function builder:add_xmake_unit(unit)
    local sysroot = unit.toolchain.sysroot
    if not self.project.sysroot then
        self.project.sysroot = sysroot
        local src = path.join(sysroot, "lib", "rustlib", "src", "rust", "library")
        if os.isdir(src) then self.project.sysroot_src = src end
    elseif rustc_args.path_key(self.project.sysroot) ~= rustc_args.path_key(sysroot) then
        self.report(unit.target:fullname() .. ": rust-project.json supports a single sysroot")
    end
    local args = unit.args
    local crate = {
        display_name = args.name or normalize(unit.target:basename()), root_module = unit.crate_root,
        edition = args.edition, target = args.target or unit.toolchain.host, cfg = unit.cfg,
        deps = {}, is_workspace_member = true, is_proc_macro = args.proc_macro
    }
    if args.proc_macro then
        if os.isfile(unit.artifact) then
            crate.proc_macro_dylib_path = unit.artifact
        else
            self.report("Xmake proc-macro artifact is missing: " .. unit.artifact)
        end
    end
    local key = rustc_args.path_key(unit.artifact)
    local ids = self.xmake_artifacts[key] or {}
    table.insert(ids, #self.project.crates)
    self.xmake_artifacts[key] = ids
    table.insert(self.project.crates, crate)
end

---@param unit XmakeRustUnit
---@return CargoInstall[]
function builder:import_cargo_metadata(unit)
    local installs, dirs = {}, {}
    for _, pkg in ipairs(unit.target:orderpkgs()) do
        for _, lib in ipairs(table.wrap(pkg:get("frameworkdirs"))) do
            local dir = cargo_crates.install_dir(lib)
            if dir then
                local debug = pkg:requireconf("configs", "debug") or pkg:requireconf("configs", "asan")
                dirs[dir] = debug and "debug" or "release"
            end
        end
    end
    for _, lib in ipairs(unit.args.search_dirs) do
        local dir = cargo_crates.install_dir(lib)
        if dir and not dirs[dir] then dirs[dir] = "release" end
    end
    for _, ext in ipairs(unit.args.externs) do
        if ext.artifact then
            local dir = cargo_crates.install_dir(path.directory(ext.artifact))
            if dir and not dirs[dir] then dirs[dir] = "release" end
        end
    end
    for _, dir in ipairs(table.orderkeys(dirs)) do
        local key = rustc_args.path_key(dir) .. "\0" .. unit.toolchain.host
        if self.cargo_installs[key] == nil then
            self.cargo_installs[key] = try {
                function ()
                    return cargo_crates.read_install(dir, unit.toolchain.host, dirs[dir], self.messages, self.report)
                end,
                catch {function (err) self.report(tostring(err)) end}
            } or false
        end
        local install = self.cargo_installs[key]
        if install then table.insert(installs, install) end
    end
    return installs
end

local function import_cargo_unit(graph, install, id, context, host, artifact)
    local unit = cargo_crates.unit(install, id, context, host, artifact, graph.report)
    if not unit then return end
    local key = table.concat({rustc_args.path_key(install.dir), id, unit.compilation_context, unit.target,
        unit.build_artifact or ""}, "\0")
    if graph.cargo_ids[key] then return graph.cargo_ids[key] end
    local crate = {
        display_name = normalize(unit.cargo_target.name), root_module = unit.source_path,
        edition = unit.cargo_target.edition or install.packages[id].edition, target = unit.target,
        cfg = unit.cfg, deps = {}, env = unit.env, is_workspace_member = false, is_proc_macro = unit.proc_macro,
        proc_macro_dylib_path = unit.proc_macro and unit.artifact or nil
    }
    local index = #graph.project.crates
    graph.cargo_ids[key] = index
    table.insert(graph.project.crates, crate)
    for _, dep in ipairs(unit.deps) do
        local dep_index = import_cargo_unit(graph, install, dep.pkg, unit.compilation_context, host)
        if dep_index then
            add_edge(graph, crate, dep.name, dep_index)
        else
            graph.report(format("%s: unresolved Cargo import %s (%s)", id, dep.name, dep.pkg))
        end
    end
    return index
end

local function extern_candidates(graph, ext, dirs)
    if ext.artifact then return {ext.artifact} end
    local files, seen = {}, {}
    for _, dir in ipairs(dirs) do
        for _, file in ipairs(os.files(path.join(dir, "*"))) do
            local base = path.basename(file):gsub("%-%x+$", "")
            local key = rustc_args.path_key(file)
            local extname = file:match("%.([^%.]+)$")
            if (base == "lib" .. ext.name or base == ext.name) and
                table.contains({"rlib", "rmeta", "so", "dylib", "dll"}, extname) and
                not seen[key] then
                table.insert(files, file)
                seen[key] = true
            end
        end
        for key in pairs(graph.xmake_artifacts) do
            if rustc_args.path_key(path.directory(key)) == rustc_args.path_key(dir) and
                (path.basename(key) == "lib" .. ext.name or path.basename(key) == ext.name) and not seen[key] then
                table.insert(files, key)
                seen[key] = true
            end
        end
    end
    return files
end

---@param unit XmakeRustUnit
---@param index integer Lua array index
function builder:resolve_extern_artifacts(unit, index)
    local installs = self:import_cargo_metadata(unit)
    local crate = self.project.crates[index]
    for _, ext in ipairs(unit.args.externs) do
        local files = extern_candidates(self, ext, unit.args.search_dirs)
        local choices, detail = {}, nil
        for _, file in ipairs(files) do
            local ids = self.xmake_artifacts[rustc_args.path_key(file)] or {}
            for _, id in ipairs(ids) do
                choices["xmake:" .. id] = {id = id}
            end
            for _, install in ipairs(installs) do
                if cargo_crates.owns(install, file) then
                    local id, problem = cargo_crates.resolve_extern(install, file)
                    if id then
                        local key = install.dir .. "\0" .. id .. "\0" .. cargo_crates.artifact_key(file)
                        choices[key] = {install = install, package = id, file = file}
                    else
                        detail = problem
                    end
                end
            end
        end
        local keys = table.orderkeys(choices)
        if #keys == 1 and not detail then
            local choice = choices[keys[1]]
            local id = choice.id or import_cargo_unit(self, choice.install, choice.package, "target",
                unit.toolchain.host, choice.file)
            if id then add_edge(self, crate, ext.name, id) end
        else
            self.report(format("%s: unresolved --extern %s%s (%s)", unit.target:fullname(), ext.name,
                ext.artifact and ("=" .. ext.artifact) or "",
                detail or (#keys > 1 and "ambiguous artifact" or "no matching Xmake or Cargo artifact")))
        end
    end
end

function builder:validate()
    local crates, visiting, complete = self.project.crates, {}, {}
    local function visit(index)
        if complete[index] then return end
        assert(not visiting[index], "cycle in crate graph at %s", crates[index].display_name)
        visiting[index] = true
        local crate = crates[index]
        assert(os.isfile(crate.root_module), "crate root is missing: %s", crate.root_module)
        assert(table.contains({"2015", "2018", "2021", "2024"}, crate.edition),
            "unsupported Rust edition for %s: %s", crate.display_name, tostring(crate.edition))
        table.sort(crate.deps, function (a, b) return a.name < b.name end)
        for _, dep in ipairs(crate.deps) do
            assert(crates[dep.crate + 1], "invalid crate index for %s", dep.name)
            visit(dep.crate + 1)
        end
        visiting[index], complete[index] = nil, true
    end
    for index = 1, #crates do visit(index) end
end

---@return RustProject
function builder:emit_rust_project()
    return self.project
end

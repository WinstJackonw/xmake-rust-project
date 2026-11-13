import("core.base.json")

local cfg_cache = {}
local toolchain_cache = {}

---@class RustToolchain
---@field sysroot string
---@field host string

local function query(program, argv, cwd)
    return os.iorunv(program, argv, {curdir = cwd})
end

local function query_key(unit, argv)
    return assert(json.encode({unit.rustc_program, unit.cwd, argv, unit.target:pkgenvs() or false}))
end

---@param unit XmakeRustUnit
---@return RustToolchain
function toolchain(unit)
    local args = unit.args
    local key = query_key(unit, args.sysroot or false)
    if not toolchain_cache[key] then
        local sysroot_args = {"--print=sysroot"}
        if args.sysroot then
            table.insert(sysroot_args, "--sysroot=" .. args.sysroot)
        end
        local sysroot = query(unit.rustc_program, sysroot_args, unit.cwd):trim()
        assert(sysroot ~= "", "rustc returned an empty sysroot")
        local version = query(unit.rustc_program, {"-vV"}, unit.cwd)
        local host = assert(version:match("host:%s+([^%s]+)"), "rustc -vV did not report a host")
        toolchain_cache[key] = {sysroot = path.absolute(sysroot, unit.cwd), host = host}
    end
    return toolchain_cache[key]
end

---@param ... string[]
---@return string[]
function merge(...)
    local result, seen = {}, {}
    for _, list in ipairs({...}) do
        for _, value in ipairs(list) do
            if not seen[value] then
                seen[value] = true
                table.insert(result, value)
            end
        end
    end
    table.sort(result)
    return result
end

---@param unit XmakeRustUnit
---@return string[]
function for_xmake(unit)
    local args = unit.args
    local argv = {"--print=cfg", "--edition=" .. args.edition}
    if args.target then table.insert(argv, "--target=" .. args.target) end
    if args.sysroot then table.insert(argv, "--sysroot=" .. args.sysroot) end
    if args.proc_macro then table.insert(argv, "--crate-type=proc-macro") end
    if args.test then table.insert(argv, "--test") end
    table.join2(argv, args.probe_args)
    for _, value in ipairs(args.cfg) do
        table.insert(argv, "--cfg=" .. value)
    end
    local key = query_key(unit, argv)
    if not cfg_cache[key] then
        local cfgs = {}
        for line in query(unit.rustc_program, argv, unit.cwd):gmatch("[^\r\n]+") do
            table.insert(cfgs, line)
        end
        cfg_cache[key] = merge(cfgs)
    end
    return cfg_cache[key]
end

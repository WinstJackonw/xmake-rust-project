import("core.tool.compiler")
import("rustc_args")
import("cfg")

---@class XmakeRustUnit
---@field rustc_program string
---@field rustc_argv string[]
---@field crate_root string
---@field target table Xmake target instance
---@field cwd string
---@field artifact string
---@field args RustcArgs
---@field toolchain RustToolchain
---@field cfg string[]

function buildargv(target, batch)
    assert(#batch.sourcefiles == 1, "%s: expected exactly one Rust crate root", target:fullname())
    local comp = assert(compiler.load(batch.sourcekind, {target = target}))
    return comp:buildargv(batch.sourcefiles, target:targetfile(), {target = target})
end

---@param targets table<string, table>
---@return XmakeRustUnit[]
function collect(targets)
    local units = {}
    local cwd = os.projectdir()
    for _, name in ipairs(table.orderkeys(targets)) do
        local target = targets[name]
        local batch = target:is_enabled() and target:sourcebatches()["rust.build"]
        if batch then
            local envs = target:pkgenvs()
            local oldenvs = envs and os.addenvs(envs)
            local unit = try {
                function ()
                    local program, argv = buildargv(target, batch)
                    local result = {
                        rustc_program = program, rustc_argv = argv, target = target, cwd = cwd,
                        crate_root = rustc_args.absolute(batch.sourcefiles[1], cwd),
                        artifact = rustc_args.absolute(target:targetfile(), cwd), args = rustc_args.parse(argv, cwd)
                    }
                    result.toolchain = cfg.toolchain(result)
                    result.cfg = cfg.for_xmake(result)
                    return result
                end,
                finally {
                    function (ok, err)
                        if oldenvs then os.setenvs(oldenvs) end
                        if not ok then raise("%s: %s", name, err) end
                    end
                }
            }
            table.insert(units, unit)
        end
    end
    return units
end

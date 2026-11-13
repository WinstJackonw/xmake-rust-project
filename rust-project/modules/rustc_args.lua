---@class RustExtern
---@field name string
---@field artifact? string

---@class RustcArgs
---@field edition string
---@field target? string
---@field sysroot? string
---@field name? string
---@field cfg string[]
---@field externs RustExtern[]
---@field search_dirs string[]
---@field native_dirs string[]
---@field probe_args string[]
---@field proc_macro boolean
---@field test boolean

local value_options = {
    ["--edition"] = "edition", ["--target"] = "target", ["--sysroot"] = "sysroot",
    ["--crate-name"] = "name", ["--cfg"] = "cfg", ["--extern"] = "externs",
    ["--crate-type"] = "crate_type", ["-L"] = "search_dirs", ["-C"] = "codegen",
    ["-Z"] = "unstable", ["--codegen"] = "codegen"
}

local codegen_cfg = {
    ["target-cpu"] = true, ["target-feature"] = true, panic = true, ["opt-level"] = true,
    ["debug-assertions"] = true, ["overflow-checks"] = true, ["relocation-model"] = true
}

local unstable_cfg = {
    ["unstable-options"] = true, sanitizer = true, ["sanitizer-cfi-generalize-pointers"] = true,
    ["sanitizer-cfi-normalize-integers"] = true, ["fmt-debug"] = true
}

---@param file string
---@param cwd? string
---@return string
function absolute(file, cwd)
    return path.translate(path.absolute(file, cwd))
end

---@param file string
---@return string
function path_key(file)
    local normalized = absolute(file):gsub("\\", "/")
    return is_host("windows") and normalized:lower() or normalized
end

---@param argv string[]
---@param cwd string
---@return RustcArgs
function parse(argv, cwd)
    local args = {
        edition = "2015", cfg = {}, externs = {}, search_dirs = {}, native_dirs = {}, probe_args = {},
        proc_macro = false, test = false
    }
    local index = 1
    while index <= #argv do
        local token = argv[index]
        if token == "--" then
            break
        end
        assert(token:sub(1, 1) ~= "@", "rustc response files are unsupported: %s", token)
        local flag, value = token:match("^(%-%-[%w%-]+)=(.*)$")
        if not flag then
            flag, value = token:match("^(%-[CLZ])(.+)$")
        end
        flag = flag or token
        local kind = value_options[flag]
        if kind then
            if value == nil then
                index = index + 1
                value = assert(argv[index], "missing value for rustc %s", flag)
            end
            if kind == "cfg" then
                table.insert(args.cfg, value)
            elseif kind == "externs" then
                local name, artifact = value:match("^([^=]+)=(.+)$")
                name = (name or value):match("[^:]+$")
                assert(name and not name:find("=", 1, true), "invalid --extern: %s", value)
                table.insert(args.externs, {name = name, artifact = artifact and absolute(artifact, cwd)})
            elseif kind == "search_dirs" then
                local scope, dir = value:match("^([%w_]+)=(.*)$")
                if not scope or scope == "dependency" or scope == "crate" or scope == "all" then
                    table.insert(args.search_dirs, absolute(dir or value, cwd))
                elseif scope == "native" or scope == "framework" then
                    table.insert(args.native_dirs, absolute(dir, cwd))
                end
            elseif kind == "crate_type" then
                for crate_type in value:gmatch("[^,]+") do
                    args.proc_macro = args.proc_macro or crate_type == "proc-macro"
                end
            elseif kind == "codegen" or kind == "unstable" then
                local supported = kind == "codegen" and codegen_cfg or unstable_cfg
                if supported[value:match("^[^=]+")] then
                    table.insert(args.probe_args, (kind == "codegen" and "-C" or "-Z") .. value)
                end
            else
                if kind == "sysroot" or (kind == "target" and value:endswith(".json")) then
                    value = absolute(value, cwd)
                end
                args[kind] = value
            end
        elseif token == "--test" then
            args.test = true
        elseif token == "-O" or token == "-g" then
            table.insert(args.probe_args, token)
        end
        index = index + 1
    end
    return args
end

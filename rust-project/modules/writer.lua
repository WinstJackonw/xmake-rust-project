import("core.base.json")

---@param project RustProject
---@param file string
function write(project, file)
    json.mark_as_array(project.crates)
    for _, crate in ipairs(project.crates) do
        json.mark_as_array(crate.deps)
        json.mark_as_array(crate.cfg)
    end
    local content = assert(json.encode(project, {pretty = true}))
    assert(not os.isdir(file), "output path is a directory: %s", file)
    os.mkdir(path.directory(file))
    local temporary = file .. "." .. path.filename(os.tmpfile())
    try {
        function ()
            io.writefile(temporary, content .. "\n")
            os.mv(temporary, file)
        end,
        catch {
            function (err)
                os.tryrm(temporary)
                raise(err)
            end
        }
    }
end

import("core.base.option")
import("core.base.task")
import("core.project.project")
import("modules.cargo_crates")
import("modules.graph")
import("modules.writer")
import("modules.xmake_crates")

local function generate()
    task.run("config", {}, {loadonly = true})
    local units = xmake_crates.collect(project.targets())
    local issues = {}
    local function report(message)
        issues[message] = true
    end
    local messages = option.get("cargo-messages")
    local builder = graph.new(report, cargo_crates.read_messages(messages and path.absolute(messages, os.projectdir())))
    for _, unit in ipairs(units) do builder:add_xmake_unit(unit) end
    for index, unit in ipairs(units) do builder:resolve_extern_artifacts(unit, index) end
    builder:validate()
    local warnings = table.orderkeys(issues)
    for _, message in ipairs(warnings) do wprint("%s", message) end
    assert(not option.get("strict") or #warnings == 0, "could not resolve all Rust crate data")
    local output = path.absolute(option.get("output") or "rust-project.json", os.projectdir())
    writer.write(builder:emit_rust_project(), output)
    print("Generated %s", output)
end

function main()
    local previous = os.getenv("XMAKE_IN_PROJECT_GENERATOR")
    os.setenv("XMAKE_IN_PROJECT_GENERATOR", "true")
    try {
        generate,
        finally {
            function (ok, err)
                os.setenv("XMAKE_IN_PROJECT_GENERATOR", previous)
                if not ok then raise(err) end
            end
        }
    }
end

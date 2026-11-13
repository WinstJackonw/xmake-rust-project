import("core.project.config")
import("core.base.task")
import("core.project.project")
import("modules.check_crates")

function main()
    local previous = os.getenv("XMAKE_IN_PROJECT_GENERATOR")
    os.setenv("XMAKE_IN_PROJECT_GENERATOR", "true")
    local lock
    local failed
    try {
        function ()
            task.run("config", {}, {loadonly = true})
            local cache = path.absolute(path.join(config.directory(), "rust-project-check"), os.projectdir())
            os.mkdir(cache)
            lock = io.openlock(path.join(cache, "check.lock"))
            lock:lock()
            local profile = path.join(config.plat(), config.arch(), config.mode() or "release")
            failed = not check_crates.run(project.targets(), os.projectdir(), path.join(cache, profile))
        end,
        finally {
            function (ok, err)
                os.setenv("XMAKE_IN_PROJECT_GENERATOR", previous)
                if lock then lock:close() end
                if not ok then raise(err) end
            end
        }
    }
    if failed then os.exit(1) end
end

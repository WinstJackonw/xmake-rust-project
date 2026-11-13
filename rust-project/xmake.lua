task("rust-project")
    set_category("plugin")
    on_run("main")
    set_menu {
        usage = "xmake rust-project [options]",
        description = "Generate rust-project.json for the configured Xmake targets",
        options = {
            {nil, "output", "kv", "rust-project.json", "Output project file"},
            {nil, "strict", "k", nil, "Fail on unresolved crate dependencies or missing build data"},
            {nil, "cargo-messages", "kv", nil, "Optional Cargo build JSON lines from the package cache"}
        }
    }

task("rust-project-check")
    set_category("plugin")
    on_run("check")
    set_menu {
        usage = "xmake rust-project-check [options]",
        description = "Emit Rust compiler JSON diagnostics for the configured Xmake targets",
        options = {}
    }

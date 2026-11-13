# xmake-rust-project

为 Xmake 管理的 Rust 工程生成 rust-analyzer 所需的 `rust-project.json`。插件使用 Xmake 3.1 的 Rust rule 和 Cargo package 安装记录。

## 使用

```sh
xmake plugin --install /path/to/xmake-rust-project/rust-project
```

也可以把 `rust-project/` 放进项目的 `plugins/`，并在项目的 `xmake.lua` 中添加 `add_plugindirs("plugins")`。

```sh
xmake f -m debug
xmake rust-project
xmake rust-project --strict --output=ide/rust-project.json
```

输出路径相对于 Xmake 项目根目录。默认模式会报告无法解析的依赖或缺失的构建信息，并写出已解析的图。`--strict` 会在写入前退出。生成任务复用 Xmake 配置流程，配置阶段可能安装所需的第三方包。

如果工程同时有 `Cargo.toml`，可在编辑器中显式选择生成文件。关闭 rust-analyzer 自动附加的 `test` cfg 后，测试上下文由 Xmake 的 rustc 参数决定。

```json
{
    "rust-analyzer.linkedProjects": ["rust-project.json"],
    "rust-analyzer.cfg.setTest": false
}
```

## 保存时检查

Xmake 自带的 `xmake check syntax` 目前只检查 C/C++ 目标。安装此插件后，在使用 Xmake 的工程根目录打开编辑器，并添加以下工作区设置。命令也可以在工程根目录直接运行。

```json
{
    "rust-analyzer.linkedProjects": ["rust-project.json"],
    "rust-analyzer.cfg.setTest": false,
    "rust-analyzer.check.overrideCommand": ["xmake", "rust-project-check", "-q"]
}
```

每次检查按依赖顺序处理当前配置下所有启用的 `rust.build` 目标，并将 rustc 的 JSON 诊断交给 rust-analyzer。普通 crate 仅生成 metadata。proc-macro 及其项目内 Rust 依赖会生成可链接的产物。

检查产物、诊断和 rustc 增量缓存保存在 Xmake 配置目录的 `rust-project-check/` 下，按目标平台、架构和模式存放。输入未变时复用上次成功检查的产物并重放诊断。源码、依赖、编译参数或 rustc 记录的环境变量变化时，会重新检查受影响的 crate。可在检查停止后删除该目录来清空缓存。

检查会加载 Xmake 配置和包环境。若工程的自定义构建步骤会生成源码或准备其他输入，需要先运行这些步骤。

## Cargo 构建信息

插件以 `resolve.root` 和 `resolve.nodes[].deps` 为入口读取安装时保存的 Cargo metadata。Xmake crate 的依赖名取自 rustc 的 `--extern`，Cargo crate 的依赖名取自 `deps[].name`，包括重命名和自定义库名。普通 Cargo 库只要有可用的源码和 metadata，就能保留在依赖图里。proc-macro 展开还需要宿主机动态库。

可以传入与当前安装匹配的 Cargo 构建消息。比如在 Xmake 为 Cargo 包生成的缓存 `source/` 目录中，用安装该包时的工具链、环境、目标和 profile 运行以下命令。debug 包省略 `--release`。

```sh
cargo build --release --message-format=json > /path/to/cargo-build.jsonl
```

然后在 Xmake 项目目录运行：

```sh
xmake rust-project --strict --cargo-messages=/path/to/cargo-build.jsonl
```

消息可提供产物所属包 ID、实际 features、profile 的 `debug_assertions`，以及 `build.rs` 的 cfg、环境变量和 `OUT_DIR`。仅有 metadata 时，features 来自解析节点。同名产物、分开的宿主与目标编译单元，以及由构建脚本生成的数据，可能需要构建消息才能确定。生成器会报告无法唯一关联的产物。

## 分析边界

Xmake crate 的参数来自 `compiler:buildargv()`。生成器用实际 rustc 和相关参数查询内置 cfg，并继承目标的包环境。自定义构建步骤设置的进程环境及 rustc response file 暂未覆盖。rust-analyzer 会把自身查询的 target cfg 与项目文件中的 cfg 合并，因此项目文件无法移除 rust-analyzer 自己启用的内置 cfg。每份项目 JSON 使用一个 sysroot。

交叉编译时，插件从 Xmake 缓存中的 synthetic manifest 运行 `cargo metadata --frozen`，并按宿主机 cfg 过滤 proc-macro 及其依赖的边。若缓存无法提供这份解析图，生成器会报告缺失的构建信息。Cargo 构建消息用于补充产物和编译信息，依赖边始终来自 Cargo metadata。

参考 [rust-analyzer 项目文件格式](https://rust-analyzer.github.io/book/non_cargo_based_projects.html) 和 [Cargo 构建消息格式](https://doc.rust-lang.org/cargo/reference/external-tools.html)。

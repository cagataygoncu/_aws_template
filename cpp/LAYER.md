# C++ language layer

C++ source, CMake build, devcontainer, and editor settings for an AWS service.

When `bootstrap.sh cpp <project_name>` runs, this folder is merged with
`_base/` to produce a working project skeleton.

Structure:
- `src/`            — application code (entry point: `main.cpp`)
- `tests/unit/`     — C++ unit tests (CTest)
- `CMakeLists.txt`  — build configuration
- `.gdbinit`        — gdb startup hooks
- `.devcontainer/`  — C++ devcontainer (clang/gcc + cmake)
- `.vscode/`        — VS Code settings incl. `c_cpp_properties.json`

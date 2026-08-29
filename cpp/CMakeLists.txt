cmake_minimum_required(VERSION 3.13)
project(cpp_sample)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wfatal-errors")
set(CMAKE_BUILD_TYPE Debug)
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -g3")

find_library(NATS_LIB nats PATHS /usr/local/lib)
find_path(NATS_INCLUDE nats.h PATHS /usr/local/include)

find_package(AWSSDK REQUIRED COMPONENTS s3 dynamodb secretsmanager)

find_package(glfw3 REQUIRED)
find_package(OpenGL REQUIRED)

message("find_package")
message("${CMAKE_PREFIX_PATH}")
message("${NATS_INCLUDE}")
message("${NATS_LIB}")
message("NATS include: ${NATS_INCLUDE_DIR}")
message("NATS lib: ${NATS_LIBRARY}")
message("${AWSSDK_LINK_LIBRARIES}")
message("Done")

add_executable(cpp_sample ./src/main.cpp)

add_library(imgui STATIC
    /Users/cgoncu/Dropbox/my/dev/imgui/imgui.cpp
    /Users/cgoncu/Dropbox/my/dev/imgui/imgui_demo.cpp
    /Users/cgoncu/Dropbox/my/dev/imgui/imgui_draw.cpp
    /Users/cgoncu/Dropbox/my/dev/imgui/imgui_tables.cpp
    /Users/cgoncu/Dropbox/my/dev/imgui/imgui_widgets.cpp
    /Users/cgoncu/Dropbox/my/dev/imgui/backends/imgui_impl_glfw.cpp
    /Users/cgoncu/Dropbox/my/dev/imgui/backends/imgui_impl_opengl3.cpp
)

target_include_directories(imgui PUBLIC
    /Users/cgoncu/Dropbox/my/dev/imgui
    /Users/cgoncu/Dropbox/my/dev/imgui/backends
)

target_link_libraries(cpp_sample PRIVATE
    ${NATS_LIB}
    ${AWSSDK_LINK_LIBRARIES}
    imgui glfw OpenGL::GL
)

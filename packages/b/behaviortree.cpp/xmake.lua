package("behaviortree.cpp")
    set_homepage("https://www.behaviortree.dev/")
    set_description("Behavior Trees Library in C++. Batteries included.")
    set_license("MIT")

    add_urls("https://github.com/BehaviorTree/BehaviorTree.CPP/archive/refs/tags/v$(version).tar.gz",
             "https://github.com/BehaviorTree/BehaviorTree.CPP.git")

    add_versions("4.9.0", "74a22cf46d7cd423d7065616528cfd68bcd925b3fc2b819a99413cdd3334c02a")

    add_configs("groot2_interface", {
        description = "Enable Groot2 publisher interface. Requires ZeroMQ.",
        default = true,
        type = "boolean"
    })
    add_configs("sqlite_logging", {
        description = "Enable SQLite-based logging.",
        default = true,
        type = "boolean"
    })
    add_configs("tools", {
        description = "Build command-line tools.",
        default = false,
        type = "boolean"
    })
    add_configs("vendored", {
        description = "Use vendored third-party libraries.",
        default = false,
        type = "boolean"
    })

    if is_plat("linux", "bsd") then
        add_syslinks("pthread", "dl")
    end

    add_deps("cmake")

    on_load(function (package)
        if not package:config("vendored") then
            package:add("deps", "tinyxml2")
            package:add("deps", "minitrace")
        end
        if package:config("groot2_interface") then
            package:add("deps", "zeromq")
        end
        if package:config("sqlite_logging") then
            package:add("deps", "sqlite3")
        end
    end)

    on_install(function (package)
        -- patch missing <vector> include for NDK 22 libc++ compatibility
        io.replace("include/behaviortree_cpp/utils/polymorphic_cast_registry.hpp",
            "#pragma once",
            "#pragma once\n#include <vector>",
            {plain = true})

        local configs = {
            "-Dament_cmake_FOUND=FALSE",
            "-DBUILD_TESTING=OFF",
            "-DBTCPP_EXAMPLES=OFF",
            "-DUSE_VENDORED_FLATBUFFERS=ON",
            "-DUSE_VENDORED_MINICORO=ON",
            "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"),
            "-DBUILD_SHARED_LIBS=" .. (package:config("shared") and "ON" or "OFF"),
            "-DBTCPP_SHARED_LIBS=" .. (package:config("shared") and "ON" or "OFF"),
            "-DBTCPP_GROOT_INTERFACE=" .. (package:config("groot2_interface") and "ON" or "OFF"),
            "-DBTCPP_SQLITE_LOGGING=" .. (package:config("sqlite_logging") and "ON" or "OFF"),
            "-DBTCPP_BUILD_TOOLS=" .. (package:config("tools") and "ON" or "OFF"),
            "-DUSE_VENDORED_MINITRACE=" .. (package:config("vendored") and "ON" or "OFF"),
            "-DUSE_VENDORED_TINYXML2=" .. (package:config("vendored") and "ON" or "OFF"),
            -- Always use the vendored cppzmq (header-only).
            -- Its CMakeLists.txt requires a `libzmq-static` or `libzmq` CMake
            -- target; we create that via CMAKE_PROJECT_INCLUDE below.
            "-DUSE_VENDORED_CPPZMQ=ON",
        }

        if package:config("groot2_interface") then
            local zeromq = package:dep("zeromq")
            if zeromq then
                local fetchinfo = zeromq:fetch()
                if fetchinfo then
                    local includedirs = fetchinfo.sysincludedirs or fetchinfo.includedirs
                    local libfiles = fetchinfo.libfiles

                    local zmq_include = (includedirs and #includedirs > 0) and includedirs[1] or ""
                    local zmq_libfile = (libfiles and #libfiles > 0) and libfiles[1] or ""

                    if zmq_include ~= "" then
                        table.insert(configs, "-DZeroMQ_INCLUDE_DIRS=" .. zmq_include)
                        table.insert(configs, "-DZeroMQ_INCLUDE_DIR=" .. zmq_include)
                    end
                    if zmq_libfile ~= "" then
                        -- ZeroMQ_FOUND=TRUE makes FindZeroMQ.cmake take its
                        -- early-exit branch: sets ZeroMQ_LIBRARIES=ZeroMQ_LIBRARY
                        -- (full path) and skips find_library(), avoiding any
                        -- bare -lzmq/-llibzmq flag on the final link line.
                        table.insert(configs, "-DZeroMQ_FOUND=TRUE")
                        table.insert(configs, "-DZeroMQ_LIBRARIES=" .. zmq_libfile)
                        table.insert(configs, "-DZeroMQ_LIBRARY=" .. zmq_libfile)
                    end

                    -- 3rdparty/cppzmq/CMakeLists.txt calls find_package(ZeroMQ)
                    -- then checks `if(TARGET libzmq-static)` / `elseif(TARGET
                    -- libzmq)` and fatals if neither exists.  FindZeroMQ.cmake's
                    -- early-exit path (triggered by ZeroMQ_FOUND=TRUE above)
                    -- never creates those targets.  We write a small CMake file
                    -- and pass it via CMAKE_PROJECT_INCLUDE, which CMake runs
                    -- once right after the top-level project() call and before
                    -- any add_subdirectory(), so the target is globally visible
                    -- when cppzmq's CMakeLists.txt runs.
                    --
                    -- The init file is written into the source tree so its path
                    -- is guaranteed free of spaces and CMake-unsafe characters.
                    if zmq_libfile ~= "" then
                        local zmq_libfile_cmake = zmq_libfile:gsub("\\", "/")
                        local zmq_include_cmake = zmq_include:gsub("\\", "/")

                        -- Write next to CMakeLists.txt so the path is simple.
                        local init_file = "btcpp_zmq_targets.cmake"
                        io.writefile(init_file, string.format([[
# Auto-generated by the xmake behaviortree.cpp package.
# Creates the imported target required by 3rdparty/cppzmq/CMakeLists.txt.
if(NOT TARGET libzmq-static)
    add_library(libzmq-static STATIC IMPORTED GLOBAL)
    set_target_properties(libzmq-static PROPERTIES
        IMPORTED_LOCATION "%s"
        INTERFACE_INCLUDE_DIRECTORIES "%s"
        IMPORTED_LINK_INTERFACE_LANGUAGES "CXX"
    )
endif()
if(NOT TARGET libzmq)
    add_library(libzmq ALIAS libzmq-static)
endif()
]], zmq_libfile_cmake, zmq_include_cmake))

                        table.insert(configs, "-DCMAKE_PROJECT_INCLUDE=" ..
                            path.absolute(init_file):gsub("\\", "/"))
                    end
                end
            end
        end

        import("package.tools.cmake").install(package, configs)
    end)

    on_test(function (package)
        assert(package:check_cxxsnippets({test = [[
            #include <behaviortree_cpp/bt_factory.h>
            #include <behaviortree_cpp/action_node.h>

            class DummyAction : public BT::SyncActionNode {
            public:
                DummyAction(const std::string& name, const BT::NodeConfig& config)
                    : BT::SyncActionNode(name, config) {}
                static BT::PortsList providedPorts() { return {}; }
                BT::NodeStatus tick() override { return BT::NodeStatus::SUCCESS; }
            };

            void test() {
                BT::BehaviorTreeFactory factory;
                factory.registerNodeType<DummyAction>("DummyAction");
                const std::string xml = R"(
                    <root BTCPP_format="4">
                        <BehaviorTree ID="MainTree">
                            <Action ID="DummyAction"/>
                        </BehaviorTree>
                    </root>
                )";
                auto tree = factory.createTreeFromText(xml);
                tree.tickWhileRunning();
            }
        ]]}, {configs = {languages = "c++17"}}))
    end)
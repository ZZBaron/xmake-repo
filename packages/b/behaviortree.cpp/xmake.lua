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

    -- BT.CPP uses dlopen on Unix for plugin loading
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
            if not package:config("vendored") then
                package:add("deps", "cppzmq")
            end
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
            -- Block ament/ROS2 auto-detection
            "-Dament_cmake_FOUND=FALSE",
            "-DBUILD_TESTING=OFF",
            "-DBTCPP_EXAMPLES=OFF",
            "-DUSE_VENDORED_FLATBUFFERS=ON", -- vendored flatbuffers only includes base.h
            "-DUSE_VENDORED_MINICORO=ON",
            "-DCMAKE_BUILD_TYPE=" .. (package:is_debug() and "Debug" or "Release"),
            "-DBUILD_SHARED_LIBS=" .. (package:config("shared") and "ON" or "OFF"),
            "-DBTCPP_SHARED_LIBS=" .. (package:config("shared") and "ON" or "OFF"),
            "-DBTCPP_GROOT_INTERFACE=" .. (package:config("groot2_interface") and "ON" or "OFF"),
            "-DBTCPP_SQLITE_LOGGING=" .. (package:config("sqlite_logging") and "ON" or "OFF"),
            "-DBTCPP_BUILD_TOOLS=" .. (package:config("tools") and "ON" or "OFF"),
            "-DUSE_VENDORED_MINITRACE=" .. (package:config("vendored") and "ON" or "OFF"),
            "-DUSE_VENDORED_TINYXML2=" .. (package:config("vendored") and "ON" or "OFF"),
            "-DUSE_VENDORED_CPPZMQ=" .. (package:config("vendored") and "ON" or "OFF")
        }

        -- cppzmq's bundled cppzmqConfig.cmake calls find_package(ZeroMQ REQUIRED)
        -- using its own FindZeroMQ.cmake, which won't find xmake's package cache
        -- on its own (especially on Windows where pkg-config is absent).
        -- CMAKE_PREFIX_PATH makes all find_* calls search under that prefix,
        -- and ZeroMQ_ROOT is the direct hint FindZeroMQ.cmake checks.
        if package:config("groot2_interface") then
            local zeromq = package:dep("zeromq")
            if zeromq then
                local installdir = zeromq:installdir()
                if installdir then
                    table.insert(configs, "-DCMAKE_PREFIX_PATH=" .. installdir)
                    table.insert(configs, "-DZeroMQ_ROOT=" .. installdir)
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
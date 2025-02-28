// NOTE: unfortunately switching to the 'prefix-less' functions in
// zimgui.h isn't that easy because some Dear ImGui functions collide
// with Win32 function (Set/GetCursorPos and Set/GetWindowPos).
const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const opt_with_docking = b.option(bool, "with_docking", "Uses the docking branch of (c)ImGui") orelse false;

    // these are the files to use for docking-enabled
    const docking_cpp_files = &.{
        "src-docking/cimgui.cpp",
        "src-docking/imgui_demo.cpp",
        "src-docking/imgui_draw.cpp",
        "src-docking/imgui_tables.cpp",
        "src-docking/imgui_widgets.cpp",
        "src-docking/imgui.cpp",
    };
    const docking_h_file = "src-docking/cimgui.h";
    const docking_internal_h_file = "src-docking/imgui_internal.h"; // internal Docking builder API needed in some cases

    // these are the files to use for no docking (default / standard)
    const non_docking_cpp_files = &.{
        "src/cimgui.cpp",
        "src/imgui_demo.cpp",
        "src/imgui_draw.cpp",
        "src/imgui_tables.cpp",
        "src/imgui_widgets.cpp",
        "src/imgui.cpp",
    };
    const non_docking_h_file = "src/cimgui.h";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_cimgui = b.addStaticLibrary(.{
        .name = "cimgui_clib",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_cimgui.linkLibCpp();

    lib_cimgui.addCSourceFiles(.{
        .files = if (opt_with_docking) docking_cpp_files else non_docking_cpp_files,
    });

    // make cimgui available as artifact, this allows to inject
    // the Emscripten sysroot include path in another build.zig
    b.installArtifact(lib_cimgui);

    // translate-c the cimgui.h file
    // NOTE: running this step with the host target is intended to avoid
    // any Emscripten header search path shenanigans
    const c_translation_main_api = b.addTranslateC(.{
        .root_source_file = b.path(if (opt_with_docking) docking_h_file else non_docking_h_file),
        .target = b.graph.host,
        .optimize = optimize,
    });

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Rename the translated cimgui.h output to cimgui.zig
    const cimgui_main_api_zig_file = b.addWriteFiles();
    _ = cimgui_main_api_zig_file.addCopyFile(c_translation_main_api.getOutput(), "cimgui.zig");

    // Create a combined Zig file that potentially combines C header translations by referencing / importing each of them
    const api_combining_zig_content = if (opt_with_docking)
        "pub const cimgui = @import(\"cimgui.zig\");\n" ++
            "pub const imgui_internal = @import(\"imgui_internal.zig\");"
    else
        "pub const cimgui = @import(\"cimgui.zig\");";

    const api_combining_zig_file = b.addWriteFiles();
    const api_combining_zig_file_path = api_combining_zig_file.add("root.zig", api_combining_zig_content);
    api_combining_zig_file.step.dependOn(&cimgui_main_api_zig_file.step); // Add dependency for cimgui.zig file creation

    // If docking is enabled, translate the additional c header (imgui_internal.h) to zig
    var cimgui_internal_api_zig_file: ?*std.Build.Step.WriteFile = null;
    var cimgui_internal_api_zig_file_path: ?std.Build.LazyPath = null;
    if (opt_with_docking) {
        const translate_internal = b.addTranslateC(.{
            .root_source_file = b.path(docking_internal_h_file),
            .target = b.graph.host,
            .optimize = optimize,
        });

        // Rename the translated imgui_internal.h output to imgui_internal.zig
        cimgui_internal_api_zig_file = b.addWriteFiles();
        cimgui_internal_api_zig_file_path = cimgui_internal_api_zig_file.?.addCopyFile(translate_internal.getOutput(), "imgui_internal.zig");
        api_combining_zig_file.step.dependOn(&cimgui_internal_api_zig_file.?.step);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // build cimgui as importable zig module
    const main_importable_module = b.addModule("cimgui", .{
        .root_source_file = api_combining_zig_file_path,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    main_importable_module.linkLibrary(lib_cimgui);

    // add internal Dear ImGUI API when using docking as well
    if (opt_with_docking) {
        const internal_module = b.createModule(.{
            .root_source_file = cimgui_internal_api_zig_file_path.?,
        });
        main_importable_module.addImport("imgui_internal", internal_module);
    }
}

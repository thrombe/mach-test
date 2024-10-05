const std = @import("std");

const mach = @import("mach");

// using wgpu instead of mach.gpu for better lsp results
const gpu = mach.wgpu;

// The global list of Mach modules registered for use in our application.
pub const modules = .{
    mach.Core,
    App,
    Renderer,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator = gpa.allocator();

const config = .{
    .paths = .{
        .toys = "./toys",
        .shadertoys = "./toys/shadertoy",
        .zhadertoys = "./toys/zhadertoy",
        .playground = "./shaders",
    },
};

const Renderer = struct {
    pub const name = .renderer;
    pub const systems = .{
        .init = .{ .handler = init },
        .deinit = .{ .handler = deinit },
        .tick = .{ .handler = tick },
        .render_frame = .{ .handler = render_frame },
        .update_shaders = .{ .handler = update_shaders },
    };
    pub const Mod = mach.Mod(@This());

    const StateUniform = extern struct {
        render_width: u32,
        render_height: u32,
        display_width: u32,
        display_height: u32,
        windowless: u32 = 0,
        time: f32 = 0.0,
        cursor_x: f32 = 0.0,
        cursor_y: f32 = 0.0,
        scroll: f32 = 0.0,

        mouse_left: u32 = 0,
        mouse_right: u32 = 0,
        mouse_middle: u32 = 0,
    };
    // uniform bind group offset must be 256-byte aligned
    const uniform_offset = 256;

    const IBuffer = struct {
        ptr: *anyopaque,
        vtable: *const struct {
            update: *const fn (any_self: *anyopaque, encoder: *gpu.CommandEncoder) void,
            deinit: *const fn (any_self: *anyopaque, alloc: std.mem.Allocator) void,
            bindEntry: *const fn (any_self: *anyopaque, binding: u32) gpu.BindGroup.Entry,
        },

        fn bindEntry(self: *@This(), binding: u32) gpu.BindGroup.Entry {
            return self.vtable.bindEntry(self.ptr, binding);
        }
        fn update(self: *@This(), encoder: *gpu.CommandEncoder) void {
            self.vtable.update(self.ptr, encoder);
        }
        fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            self.vtable.deinit(self.ptr, alloc);
        }
    };
    fn Buffer(typ: anytype) type {
        return struct {
            val: typ,
            buffer: *gpu.Buffer,
            label: [*:0]const u8,

            fn new(comptime nam: []const u8, val: typ, alloc: std.mem.Allocator, device: *gpu.Device) !*@This() {
                const label = nam ++ ".init";
                const buffer = device.createBuffer(&.{
                    .label = label ++ " uniform buffer",
                    .usage = .{ .copy_dst = true, .uniform = true },
                    .size = @sizeOf(typ) * uniform_offset, // HUH: why is this size*uniform_offset? it should be the next multiple of uniform_offset
                    .mapped_at_creation = .false,
                });
                const buff = try alloc.create(@This());
                buff.* = .{
                    .val = val,
                    .buffer = buffer,
                    .label = label,
                };
                return buff;
            }
            fn bindEntry(self: *@This(), binding: u32) gpu.BindGroup.Entry {
                return gpu.BindGroup.Entry.buffer(binding, self.buffer, 0, @sizeOf(typ));
            }
            fn update(self: *@This(), encoder: *gpu.CommandEncoder) void {
                encoder.writeBuffer(self.buffer, 0, &[_]typ{self.val});
            }
            fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
                self.buffer.release();
                alloc.destroy(self);
            }
            fn interface(self: *@This()) IBuffer {
                return .{
                    .ptr = self,
                    .vtable = &.{
                        .update = @ptrCast(&update),
                        .deinit = @ptrCast(&@This().deinit),
                        .bindEntry = @ptrCast(&bindEntry),
                    },
                };
            }
        };
    }
    const Binding = struct {
        label: [*:0]const u8,
        group: ?*gpu.BindGroup = null,
        layout: ?*gpu.BindGroupLayout = null,
        buffers: std.ArrayListUnmanaged(IBuffer) = .{},

        fn add(self: *@This(), buffer: anytype, alloc: std.mem.Allocator) !void {
            const itf: IBuffer = buffer.interface();
            try self.buffers.append(alloc, itf);
        }
        fn init(self: *@This(), label: [*:0]const u8, device: *gpu.Device, alloc: std.mem.Allocator) !void {
            var layout_entries = std.ArrayListUnmanaged(gpu.BindGroupLayout.Entry){};
            defer layout_entries.deinit(alloc);
            var bind_group_entries = std.ArrayListUnmanaged(gpu.BindGroup.Entry){};
            defer bind_group_entries.deinit(alloc);

            for (self.buffers.items, 0..) |*buf, i| {
                const bind_group_layout_entry = gpu.BindGroupLayout.Entry.buffer(
                    @intCast(i),
                    .{
                        .vertex = true,
                        .fragment = true,
                        .compute = true,
                    },
                    .uniform,
                    true,
                    0,
                );
                try layout_entries.append(alloc, bind_group_layout_entry);

                try bind_group_entries.append(alloc, buf.bindEntry(@intCast(i)));
            }

            const bind_group_layout = device.createBindGroupLayout(
                &gpu.BindGroupLayout.Descriptor.init(.{
                    .label = label,
                    .entries = layout_entries.items,
                }),
            );

            const bind_group = device.createBindGroup(
                &gpu.BindGroup.Descriptor.init(.{
                    .label = label,
                    .layout = bind_group_layout,
                    .entries = bind_group_entries.items,
                }),
            );
            self.group = bind_group;
            self.layout = bind_group_layout;
        }
        fn update(self: *@This(), encoder: *gpu.CommandEncoder) void {
            for (self.buffers.items) |*buf| {
                buf.update(encoder);
            }
        }
        fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            if (self.layout) |layout| {
                layout.release();
            }
            if (self.group) |group| {
                group.release();
            }
            for (self.buffers.items) |*buf| {
                buf.deinit(alloc);
            }
            self.buffers.deinit(alloc);
        }
    };

    const Vec3 = extern struct {
        x: f32,
        y: f32,
        z: f32,
        w: f32 = 0.0,
    };
    const ShadertoyUniforms = struct {
        time: *Buffer(f32),
        resolution: *Buffer(Vec3),
    };

    timer: mach.Timer,
    toyman: Shadertoy.ToyMan,

    pipeline: *gpu.RenderPipeline,
    binding: Binding,
    buffer: *Buffer(StateUniform),
    st_buffers: ShadertoyUniforms,

    fn deinit(self_mod: *Mod) !void {
        const self: *@This() = self_mod.state();
        self.pipeline.release();
        self.binding.deinit(allocator);
        self.toyman.deinit();

        // buffer's interface is already in self.binding
        // self.buffer.deinit(allocator);
        // self.st_buffers.time.deinit(allocator);
        // self.st_buffers.resolution.deinit(allocator);
    }

    fn init(
        core_mod: *mach.Core.Mod,
        self_mod: *Mod,
    ) !void {
        const core: *mach.Core = core_mod.state();
        const device = core.device;

        const height = core_mod.get(core.main_window, .height).?;
        const width = core_mod.get(core.main_window, .width).?;
        const state = .{
            .render_width = width,
            .render_height = height,
            .display_width = height,
            .display_height = width,
        };
        const buffer = try Buffer(StateUniform).new(@tagName(name) ++ "custom state", state, allocator, device);
        const st_buffers = ShadertoyUniforms{
            .time = try Buffer(f32).new(@tagName(name) ++ " time", 0.0, allocator, device),
            .resolution = try Buffer(Vec3).new(@tagName(name) ++ " resolution", Vec3{
                .x = @floatFromInt(width),
                .y = @floatFromInt(height),
                .z = 0.0,
            }, allocator, device),
        };

        var binding = Binding{ .label = buffer.label };
        try binding.add(buffer, allocator);
        try binding.add(st_buffers.time, allocator);
        try binding.add(st_buffers.resolution, allocator);
        try binding.init(@tagName(name), device, allocator);

        const shader_module = device.createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));
        defer shader_module.release();
        const frag_shader_module = shader_module;
        const vertex_shader_module = shader_module;

        const color_target = gpu.ColorTargetState{
            .format = core_mod.get(core.main_window, .framebuffer_format).?,
            .blend = &gpu.BlendState{},
            .write_mask = gpu.ColorWriteMaskFlags.all,
        };
        const fragment = gpu.FragmentState.init(.{
            .module = frag_shader_module,
            .entry_point = "frag_main",
            .targets = &.{color_target},
        });
        const vertex = gpu.VertexState{
            .module = vertex_shader_module,
            .entry_point = "vert_main",
        };

        const bind_group_layouts = [_]*gpu.BindGroupLayout{binding.layout.?};
        const pipeline_layout = device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
            .label = binding.label,
            .bind_group_layouts = &bind_group_layouts,
        }));
        defer pipeline_layout.release();
        const pipeline = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
            .label = binding.label,
            .fragment = &fragment,
            .layout = pipeline_layout,
            .vertex = vertex,
        });

        const man = try Shadertoy.ToyMan.init();
        self_mod.init(.{
            .timer = try mach.Timer.start(),
            .toyman = man,

            .binding = binding,
            .buffer = buffer,
            .st_buffers = st_buffers,
            .pipeline = pipeline,
        });
    }

    fn render_frame(
        self_mod: *Mod,
        core_mod: *mach.Core.Mod,
    ) !void {
        const self: *@This() = self_mod.state();
        const core: *mach.Core = core_mod.state();
        const device: *gpu.Device = core.device;

        const back_buffer_view = mach.core.swap_chain.getCurrentTextureView().?;
        defer back_buffer_view.release();

        const label = @tagName(name) ++ ".render_frame";
        const encoder = device.createCommandEncoder(&.{ .label = label });
        defer encoder.release();

        self.binding.update(encoder);

        const color_attachments = [_]gpu.RenderPassColorAttachment{.{
            .view = back_buffer_view,
            .clear_value = gpu.Color{
                .r = 40.0 / 255.0,
                .g = 40.0 / 255.0,
                .b = 40.0 / 255.0,
                .a = 1,
            },
            .load_op = .clear,
            .store_op = .store,
        }};
        const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
            .label = label,
            .color_attachments = &color_attachments,
        }));
        defer render_pass.release();

        render_pass.setPipeline(self.pipeline);
        render_pass.setBindGroup(0, self.binding.group.?, &.{ 0, 0, 0 });
        render_pass.draw(6, 1, 0, 0);
        render_pass.end();

        var command = encoder.finish(&.{ .label = label });
        defer command.release();
        core.queue.submit(&[_]*gpu.CommandBuffer{command});

        core_mod.schedule(.present_frame);
    }

    fn update_shaders(
        core_mod: *mach.Core.Mod,
        self_mod: *Mod,
    ) !void {
        const core: *mach.Core = core_mod.state();
        const device = core.device;
        const self: *@This() = self_mod.state();

        std.debug.print("updating shaders!\n", .{});

        var definitions = std.ArrayList([]const u8).init(allocator);
        defer {
            for (definitions.items) |def| {
                allocator.free(def);
            }
            definitions.deinit();
        }
        if (self.toyman.active_toy.has_common) {
            try definitions.append(try allocator.dupe(u8, "ZHADER_COMMON"));
        }

        var compiler = Glslc.Compiler{ .opt = .fast };
        compiler.stage = .vertex;
        // _ = compiler.dump_assembly(allocator, vert);
        const vertex_bytes = compiler.compile(
            allocator,
            &.{ .path = .{
                .main = "./shaders/vert.glsl",
                .include = &[_][]const u8{config.paths.playground},
                .definitions = definitions.items,
            } },
            .spirv,
        ) catch |e| {
            std.debug.print("{any}\n", .{e});
            return;
        };
        defer allocator.free(vertex_bytes);
        const vertex_shader_module = device.createShaderModule(&gpu.ShaderModule.Descriptor{
            .next_in_chain = .{ .spirv_descriptor = &.{
                .code_size = @intCast(vertex_bytes.len),
                .code = vertex_bytes.ptr,
            } },
            .label = "vert.glsl",
        });
        defer vertex_shader_module.release();

        compiler.stage = .fragment;
        // _ = compiler.dump_assembly(allocator, frag);
        const frag_bytes = compiler.compile(
            allocator,
            &.{ .path = .{
                .main = "./shaders/frag.glsl",
                .include = &[_][]const u8{config.paths.playground},
                .definitions = definitions.items,
            } },
            .spirv,
        ) catch |e| {
            std.debug.print("{any}\n", .{e});
            return;
        };
        defer allocator.free(frag_bytes);
        const frag_shader_module = device.createShaderModule(&gpu.ShaderModule.Descriptor{
            .next_in_chain = .{ .spirv_descriptor = &.{
                .code_size = @intCast(frag_bytes.len),
                .code = frag_bytes.ptr,
            } },
            .label = "frag.glsl",
        });
        defer frag_shader_module.release();

        const color_target = gpu.ColorTargetState{
            .format = core_mod.get(core.main_window, .framebuffer_format).?,
            .blend = &gpu.BlendState{},
            .write_mask = gpu.ColorWriteMaskFlags.all,
        };
        const fragment = gpu.FragmentState.init(.{
            .module = frag_shader_module,
            .entry_point = "main",
            .targets = &.{color_target},
        });
        const vertex = gpu.VertexState{
            .module = vertex_shader_module,
            .entry_point = "main",
        };

        const bind_group_layouts = [_]*gpu.BindGroupLayout{self.binding.layout.?};
        const pipeline_layout = device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
            .label = self.binding.label,
            .bind_group_layouts = &bind_group_layouts,
        }));
        defer pipeline_layout.release();
        const pipeline = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
            .label = self.binding.label,
            .fragment = &fragment,
            .layout = pipeline_layout,
            .vertex = vertex,
        });
        self.pipeline.release();
        self.pipeline = pipeline;
    }

    fn tick(self_mod: *Mod, core_mod: *mach.Core.Mod) !void {
        defer self_mod.schedule(.render_frame);

        const self: *@This() = self_mod.state();
        if (self.toyman.shader_fuse.unfuse()) {
            self_mod.schedule(.update_shaders);
        }

        var state = &self.buffer.val;
        state.time += self.timer.lap();
        self.st_buffers.time.val = state.time;

        var iter = mach.core.pollEvents();
        while (iter.next()) |event| {
            switch (event) {
                .mouse_motion => |pos| {
                    state.cursor_x = @floatCast(pos.pos.x);
                    state.cursor_y = @floatCast(pos.pos.y);
                },
                .mouse_press => |button| {
                    switch (button.button) {
                        .left => {
                            state.mouse_left = 1;
                        },
                        .right => {
                            state.mouse_right = 1;
                        },
                        .middle => {
                            state.mouse_middle = 1;
                        },
                        else => {},
                    }
                },
                .mouse_release => |button| {
                    switch (button.button) {
                        .left => {
                            state.mouse_left = 0;
                        },
                        .right => {
                            state.mouse_right = 0;
                        },
                        .middle => {
                            state.mouse_middle = 0;
                        },
                        else => {},
                    }
                },
                .mouse_scroll => |del| {
                    state.scroll += del.yoffset;
                },
                .key_press => |ev| {
                    switch (ev.key) {
                        .escape => {
                            core_mod.schedule(.exit);
                        },
                        .one => {
                            try self.toyman.load_shadertoy("4td3zj");
                        },
                        .two => {
                            try self.toyman.load_shadertoy("4t3SzN");
                        },
                        .zero => {
                            try self.toyman.load_zhadertoy("new");
                        },
                        else => {},
                    }
                },
                .key_release => |ev| {
                    switch (ev.key) {
                        else => {},
                    }
                },
                .framebuffer_resize => |sze| {
                    state.render_height = sze.height;
                    state.render_width = sze.width;
                    state.display_height = sze.height;
                    state.display_width = sze.width;
                },
                .close => core_mod.schedule(.exit),
                else => {},
            }
        }
    }
};

const App = struct {
    pub const name = .app;
    pub const systems = .{
        .init = .{ .handler = init },
        .deinit = .{ .handler = deinit },
        .tick = .{ .handler = tick },
    };
    pub const Mod = mach.Mod(@This());

    fn init(
        self_mod: *Mod,
        core_mod: *mach.Core.Mod,
        renderer_mod: *Renderer.Mod,
    ) !void {
        core_mod.schedule(.init);
        defer core_mod.schedule(.start);

        // NOTE: core should be initialized before renderer
        renderer_mod.schedule(.init);

        self_mod.init(.{});
    }

    fn deinit(core_mod: *mach.Core.Mod, renderer_mod: *Renderer.Mod) !void {
        renderer_mod.schedule(.deinit);
        core_mod.schedule(.deinit);
    }

    fn tick(
        renderer_mod: *Renderer.Mod,
    ) !void {
        renderer_mod.schedule(.tick);

        // NOOOO: can't poll events in multiple systems (it consumes)
        // var iter = mach.core.pollEvents();
    }
};

pub fn main() !void {
    // try Glslang.testfn();
    // try Dawn.testfn();
    // try Shaderc.testfn();
    // try Glslc.testfn();
    // try Shadertoy.testfn();
    // try FsFuse.testfn();
    // if (true) {
    //     return;
    // }

    try mach.core.initModule();
    while (try mach.core.tick()) {}

    // no defer cuz we don't want to print leaks when we error out
    _ = gpa.deinit();
}

const JsonHelpers = struct {
    const StringBool = enum {
        true,
        false,

        pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            switch (try source.nextAlloc(alloc, options.allocate orelse .alloc_if_needed)) {
                .string, .allocated_string => |field| {
                    if (std.mem.eql(u8, field, "true")) {
                        return .true;
                    } else if (std.mem.eql(u8, field, "false")) {
                        return .false;
                    } else {
                        return error.InvalidEnumTag;
                    }
                },
                else => |token| {
                    std.debug.print("{any}\n", .{token});
                    return error.UnexpectedToken;
                },
            }
        }
    };

    fn parseUnionAsStringWithUnknown(t: type, alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !t {
        switch (try source.nextAlloc(alloc, options.allocate orelse .alloc_if_needed)) {
            .string, .allocated_string => |field| {
                inline for (@typeInfo(t).Union.fields) |typ| {
                    comptime if (std.meta.stringToEnum(std.meta.Tag(t), typ.name).? == .unknown) {
                        continue;
                    };

                    if (std.mem.eql(u8, field, typ.name)) {
                        return @unionInit(t, typ.name, {});
                    }
                }
                return .{ .unknown = field };
            },
            else => return error.UnexpectedToken,
        }
    }

    fn parseEnumAsString(t: type, alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !t {
        @setEvalBranchQuota(2000);
        switch (try source.nextAlloc(alloc, options.allocate orelse .alloc_if_needed)) {
            .string, .allocated_string => |field| {
                inline for (@typeInfo(t).Enum.fields) |typ| {
                    if (std.mem.eql(u8, field, typ.name)) {
                        return comptime std.meta.stringToEnum(t, typ.name).?;
                    }
                }
                std.debug.print("unknown type: {s}\n", .{field});
                return error.InvalidEnumTag;
            },
            else => |token| {
                std.debug.print("{any}\n", .{token});
                return error.UnexpectedToken;
            },
        }
    }
};

const Shadertoy = struct {
    // https://www.shadertoy.com/howto
    const base = "https://www.shadertoy.com";
    const api_base = base ++ "/api/v1";
    const key = "BdHjRn";
    const json_parse_ops = .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    };

    fn testfn() !void {
        return try testfn2();
    }

    fn testfn2() !void {
        const cwd = std.fs.cwd();
        const id = "4td3zj";
        const toys = "./toys/shadertoy";

        var cache = try Cached.init(toys);
        defer cache.deinit();
        var toy = try cache.shader(id);
        defer toy.deinit();
        const cwd_real = try cwd.realpathAlloc(allocator, "./");
        defer allocator.free(cwd_real);
        var man = try ToyMan.init(try std.fs.path.join(allocator, &[_][]const u8{ cwd_real, "shaders" }));
        defer man.deinit();

        const target = try cwd.realpathAlloc(allocator, toys ++ "/" ++ id);
        defer allocator.free(target);
        var ptoy = try man.prepare_toy(&toy.value, target);
        defer ptoy.deinit();
    }

    fn testfn1() !void {
        var cache = try Cached.init("./toys/shadertoy");
        defer cache.deinit();
        // const toy = try cache.shader("4t3SzN");
        const toy = try cache.shader("lXjczd");
        defer toy.deinit();
        // const toy = try Toy.from_file("./toys/new.json");
        // defer toy.deinit();

        std.debug.print("{s}\n", .{toy.value.Shader.renderpass[0].code});
    }

    const ToyMan = struct {
        // path where the toy should be simlinked
        playground: []const u8,
        shader_fuse: FsFuse,
        shader_cache: Shadertoy.Cached,
        active_toy: ActiveToy,

        const vert_glsl = @embedFile("./vert.glsl");
        const frag_glsl = @embedFile("./frag.glsl");

        fn init() !@This() {
            const cwd_real = try std.fs.cwd().realpathAlloc(allocator, "./");
            defer allocator.free(cwd_real);
            const playground = try std.fs.path.join(allocator, &[_][]const u8{ cwd_real, "shaders" });

            const fuse = try FsFuse.init(config.paths.playground);
            // TODO: fuse() + default self.active_toy won't work cuz of things like has_common
            fuse.ctx.trigger.fuse();
            const cache = try Shadertoy.Cached.init(config.paths.shadertoys);

            return .{
                .playground = playground,
                .shader_fuse = fuse,
                .shader_cache = cache,
                .active_toy = .{
                    .has_common = false,
                    .buffers = try allocator.alloc(ActiveToy.Buffer, 0),
                },
            };
        }

        fn deinit(self: *@This()) void {
            self.shader_fuse.deinit();
            self.shader_cache.deinit();
            self.active_toy.deinit();
            allocator.free(self.playground);
        }

        fn load_shadertoy(self: *@This(), id: []const u8) !void {
            var toy = try self.shader_cache.shader(id);
            defer toy.deinit();

            const path = try std.fs.path.join(allocator, &[_][]const u8{ config.paths.shadertoys, id });
            defer allocator.free(path);
            const target = try std.fs.cwd().realpathAlloc(allocator, path);
            defer allocator.free(target);

            const active = try prepare_toy(self.playground, &toy.value, target);
            self.active_toy.deinit();
            self.active_toy = active;

            try self.shader_fuse.restart(config.paths.playground);
            self.shader_fuse.ctx.trigger.fuse();
        }

        fn load_zhadertoy(self: *@This(), id: []const u8) !void {
            const path = try std.fs.path.join(allocator, &[_][]const u8{ config.paths.zhadertoys, id });
            defer allocator.free(path);
            const target = try std.fs.cwd().realpathAlloc(allocator, path);
            defer allocator.free(target);

            const toypath = try std.fs.path.join(allocator, &[_][]const u8{ path, "toy.json" });
            defer allocator.free(toypath);
            var toy = try Shadertoy.Toy.from_file(toypath);
            defer toy.deinit();

            const active = try prepare_toy(self.playground, &toy.value, target);
            self.active_toy.deinit();
            self.active_toy = active;

            try self.shader_fuse.restart(config.paths.playground);
            self.shader_fuse.ctx.trigger.fuse();
        }

        // file naming:
        //   - virt.glsl: vertex shader entry point (not available on shadertoy)
        //   - frag.glsl: fragment shader entry point (not available on shadertoy)
        //   - common.glsl
        //   - image.glsl
        //   - sound.glsl
        //   - cube.glsl
        //   - buffer1A.glsl: where the '1' represents execution order of the buffers
        //       (shadertoy buffers ABCD can be in any order, but they execute in the order they are defined in)
        fn prepare_toy(playground: []const u8, toy: *Toy, dir_path: []const u8) !ActiveToy {
            var dir = try std.fs.openDirAbsolute(dir_path, .{ .no_follow = true });
            defer dir.close();

            // testing if frag exists to figure out if we need to prep or load the toy
            const prep = blk: {
                dir.access("frag.glsl", .{}) catch break :blk true;
                break :blk false;
            };

            var has_common: bool = false;
            var buffers = std.ArrayList(ActiveToy.Buffer).init(allocator);
            errdefer buffers.deinit();

            for (toy.Shader.renderpass) |pass| {
                switch (pass.type) {
                    .common => {
                        has_common = true;

                        if (!prep) {
                            continue;
                        }

                        var buf = try dir.createFile("common.glsl", .{});
                        defer buf.close();

                        try buf.writeAll(pass.code);
                    },
                    .buffer => {
                        const name = try std.fmt.allocPrint(
                            allocator,
                            "buffer{d}{c}.glsl",
                            .{ buffers.items.len + 1, pass.name[pass.name.len - 1] },
                        );

                        if (prep) {
                            var buf = try dir.createFile(name, .{});
                            defer buf.close();

                            try buf.writeAll(pass.code);
                        }

                        try buffers.append(.{
                            .name = name,
                        });
                    },
                    .image => {
                        if (!prep) {
                            continue;
                        }

                        var buf = try dir.createFile("image.glsl", .{});
                        defer buf.close();

                        try buf.writeAll(pass.code);
                    },
                    else => {
                        std.debug.print("unimplemented renderpass type: {any}\n", .{pass.type});
                    },
                }
            }

            if (prep) {
                var vert = try dir.createFile("vert.glsl", .{});
                defer vert.close();
                try vert.writeAll(vert_glsl);

                var frag = try dir.createFile("frag.glsl", .{});
                defer frag.close();
                try frag.writeAll(frag_glsl);
            }

            // ignore if path does not exist.
            dir.deleteFile(playground) catch |e| {
                switch (e) {
                    error.FileNotFound => {},
                    else => {
                        return e;
                    },
                }
            };
            try std.fs.symLinkAbsolute(
                dir_path,
                playground,
                .{ .is_directory = true },
            );

            return .{
                .has_common = has_common,
                .buffers = try buffers.toOwnedSlice(),
            };
        }
    };

    const ActiveToy = struct {
        has_common: bool,
        buffers: []Buffer,

        const Buffer = struct {
            name: []const u8,

            fn deinit(self: *@This()) void {
                allocator.free(self.name);
            }
        };

        fn deinit(self: *@This()) void {
            for (self.buffers) |*buf| buf.deinit();
            allocator.free(self.buffers);
        }
    };

    const Toy = struct {
        const Json = std.json.Parsed(@This());

        Shader: struct {
            info: struct {
                id: []const u8,
                name: []const u8,
                username: []const u8,
                description: []const u8,
            },

            // passes execute in the order they are defined. outputs from one pass may go
            // as inputs to next pass if defined
            renderpass: []struct {
                inputs: []struct {
                    id: u32,
                    src: []const u8,
                    channel: u2, // 0..=3
                    published: u32, // 1?
                    sampler: struct {
                        filter: enum {
                            nearest,
                            linear,
                            mipmap, // default ctype: volume, cubemap, texture

                            pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                                return try JsonHelpers.parseEnumAsString(@This(), alloc, source, options);
                            }
                        },
                        wrap: enum {
                            clamp,
                            repeat, // default ctype: texture, volume

                            pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                                return try JsonHelpers.parseEnumAsString(@This(), alloc, source, options);
                            }
                        },
                        vflip: JsonHelpers.StringBool, // default ctype: cubemap is false
                        srgb: JsonHelpers.StringBool, // default all false
                        internal: enum {
                            byte,

                            pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                                return try JsonHelpers.parseEnumAsString(@This(), alloc, source, options);
                            }
                        },
                    },
                    ctype: enum {
                        texture,
                        cubemap,
                        buffer,
                        volume,
                        mic,
                        webcam,
                        video,
                        music,
                        keyboard,

                        pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                            return try JsonHelpers.parseEnumAsString(@This(), alloc, source, options);
                        }
                    },
                },
                outputs: []struct {
                    id: u32,

                    // idk what this is. always seems to be 0??
                    channel: u32,
                },
                code: []const u8,
                name: []const u8,
                description: []const u8,

                // passes in order: buffer, buffer, buffer, buffer, cubemap, image, sound
                type: enum {
                    // shared by all shaders
                    common,

                    // - [Shadertoy Tutorial](https://inspirnathan.com/posts/62-shadertoy-tutorial-part-15)
                    // if buffer A uses buffer A as input, last frame's buffer A goes in
                    buffer,

                    cubemap,

                    // this is displayed on screen
                    image,

                    sound,

                    pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                        return try JsonHelpers.parseEnumAsString(@This(), alloc, source, options);
                    }
                },
            },
        },

        fn from_json(json: []const u8) !Json {
            const toy = std.json.parseFromSlice(@This(), allocator, json, json_parse_ops) catch |e| {
                const err = std.json.parseFromSlice(struct { Error: []const u8 }, allocator, json, json_parse_ops) catch {
                    return e;
                };
                defer err.deinit();
                std.debug.print("shadertoy error: {s}\n", .{err.value.Error});
                return error.ShaderNotAccessible;
            };
            return toy;
        }

        fn from_file(path: []const u8) !Json {
            const rpath = try std.fs.realpathAlloc(allocator, path);
            defer allocator.free(rpath);
            const file = try std.fs.openFileAbsolute(rpath, .{});
            defer file.close();
            const bytes = try file.readToEndAlloc(allocator, 10 * 1000 * 1000);
            defer allocator.free(bytes);
            return try from_json(bytes);
        }
    };

    const Cached = struct {
        cache_dir: []const u8,

        fn init(cache_dir: []const u8) !@This() {
            const cache = try std.fs.realpathAlloc(allocator, cache_dir);
            var res = try std.fs.cwd().openDir(cache, .{});
            defer res.close();
            return .{
                .cache_dir = cache,
            };
        }
        fn deinit(self: *@This()) void {
            allocator.free(self.cache_dir);
        }
        fn shader(self: *@This(), id: []const u8) !Toy.Json {
            const dir = try std.fs.path.join(allocator, &[_][]const u8{
                self.cache_dir,
                id,
            });
            defer allocator.free(dir);
            const path = try std.fs.path.join(allocator, &[_][]const u8{
                dir,
                "toy.json",
            });
            defer allocator.free(path);

            const cwd = std.fs.cwd();
            var file = cwd.openFile(path, .{}) catch {
                const json = try get_shader_json(id);
                defer allocator.free(json);
                try cwd.makePath(dir);
                const file = try cwd.createFile(path, .{});
                defer file.close();

                const value = try std.json.parseFromSlice(
                    std.json.Value,
                    allocator,
                    json,
                    json_parse_ops,
                );
                defer value.deinit();

                try std.json.stringify(
                    &value.value,
                    .{ .whitespace = .indent_4 },
                    file.writer(),
                );

                return try Toy.from_json(json);
            };
            defer file.close();
            const bytes = try file.readToEndAlloc(allocator, 10 * 1000 * 1000);
            defer allocator.free(bytes);
            return try Toy.from_json(bytes);
        }
    };

    fn get_shader_json(id: []const u8) ![]const u8 {
        const url = try std.fmt.allocPrintZ(allocator, api_base ++ "/shaders/{s}?key=" ++ key, .{id});
        defer allocator.free(url);
        const body = try Curl.get(url);
        return body;
    }

    fn get_shader(id: []const u8) !Toy.Json {
        const body = try get_shader_json(id);
        defer allocator.free(body);

        const toy = try Toy.from_json(body);
        return toy;
    }

    fn query_shaders(query: []const u8) !void {
        const encoded = try encode(query);
        defer allocator.free(encoded);

        // sort by: name, love, popular (default), newest, hot
        // const url = try std.fmt.allocPrint(allocator, api_base ++ "/shaders/query/{s}?sort=newest&from=0&num=25&key=" ++ key, .{encoded});
        // defer allocator.free(url);
    }

    fn get_media(hash: []const u8) !void {
        const url = try std.fmt.allocPrint(allocator, base ++ "/media/a/{s}", .{hash});
        defer allocator.free(url);
    }

    fn get(url: []const u8) ![]const u8 {
        std.debug.print("{s}\n", .{url});
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();
        const uri = try std.Uri.parse(url);
        const buf = try allocator.alloc(u8, 1024 * 8);
        defer allocator.free(buf);
        var req = try client.open(.GET, uri, .{
            .server_header_buffer = buf,
            .headers = .{
                .user_agent = .{
                    // hello website. i am actuall firefox. no cap.
                    .override = "Mozilla/5.0 (X11; Linux x86_64; rv:127.0) Gecko/20100101 Firefox/127.0",
                },
            },
        });
        defer req.deinit();
        try req.send();
        // try req.finish();
        // try req.write();
        try req.wait();

        var body = std.ArrayList(u8).init(allocator);
        try req.reader().readAllArrayList(&body, 1000 * 1000);
        return try body.toOwnedSlice();
    }

    fn encode(str: []const u8) ![]const u8 {
        const al = std.ArrayList(u8).init(allocator);
        std.Uri.Component.percentEncode(al.writer(), str, struct {
            fn isValidChar(c: u8) bool {
                return switch (c) {
                    0, '%', ':' => false,
                    else => true,
                };
            }
        }.isValidChar);
        return try al.toOwnedSlice();
    }
};

const Curl = struct {
    // - [HTTP Get - Zig cookbook](https://cookbook.ziglang.cc/05-01-http-get.html)
    // - [libcurl - API](https://curl.se/libcurl/c/)
    const c = @cImport({
        @cInclude("curl/curl.h");
    });
    const user_agent = "Mozilla/5.0 (X11; Linux x86_64; rv:127.0) Gecko/20100101 Firefox/127.0";

    fn write_callback(ptr: [*]const u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.C) usize {
        const total_size = size * nmemb;

        const body: *std.ArrayList(u8) = @ptrCast(@alignCast(userdata));
        body.appendSlice(ptr[0..total_size]) catch unreachable;

        return total_size;
    }

    fn get(url: [:0]const u8) ![]u8 {
        var ok = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
        if (ok != c.CURLE_OK) {
            return error.CurlIsNotOkay;
        }
        const curl = c.curl_easy_init() orelse return error.CurlInitFailed;
        defer c.curl_easy_cleanup(curl);

        var body = std.ArrayList(u8).init(allocator);

        const headers = c.curl_slist_append(null, "user-agent: " ++ user_agent);
        defer c.curl_slist_free_all(headers);

        ok = c.curl_easy_setopt(curl, c.CURLOPT_URL, url.ptr);
        if (ok != c.CURLE_OK) {
            return error.CurlSetOptFailed;
        }
        ok = c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, write_callback);
        if (ok != c.CURLE_OK) {
            return error.CurlSetOptFailed;
        }
        ok = c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &body);
        if (ok != c.CURLE_OK) {
            return error.CurlSetOptFailed;
        }
        ok = c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, headers);
        if (ok != c.CURLE_OK) {
            return error.CurlSetOptFailed;
        }

        ok = c.curl_easy_perform(curl);
        if (ok != c.CURLE_OK) {
            return error.CurlRequestFailed;
        }

        return body.toOwnedSlice();
    }
};

const FsFuse = struct {
    // - [emcrisostomo/fswatch](https://github.com/emcrisostomo/fswatch?tab=readme-ov-file#libfswatch)
    // - [libfswatch/c/libfswatch.h Reference](http://emcrisostomo.github.io/fswatch/doc/1.17.1/libfswatch.html/libfswatch_8h.html#ae465ef0618fb1dc6d8b70dee68359ea6)
    const c = @cImport({
        @cInclude("libfswatch/c/libfswatch.h");
    });

    const Ctx = struct {
        handle: c.FSW_HANDLE,
        trigger: Fuse,
        path: [:0]const u8,
    };

    ctx: *Ctx,
    thread: std.Thread,

    fn testfn() !void {
        var watch = try init("./shaders");
        defer watch.deinit();

        std.time.sleep(std.time.ns_per_s * 10);
    }

    fn init(path: [:0]const u8) !@This() {
        const rpath = try std.fs.cwd().realpathAlloc(allocator, path);
        defer allocator.free(rpath);
        const pathZ = try allocator.dupeZ(u8, rpath);

        const watch = try start(pathZ);
        return watch;
    }

    fn deinit(self: @This()) void {
        _ = c.fsw_stop_monitor(self.ctx.handle);
        _ = c.fsw_destroy_session(self.ctx.handle);
        self.thread.join();
        allocator.free(self.ctx.path);
        allocator.destroy(self.ctx);
    }

    fn unfuse(self: *@This()) bool {
        return self.ctx.trigger.unfuse();
    }

    fn check(self: *@This()) bool {
        return self.ctx.trigger.check();
    }

    fn restart(self: *@This(), path: [:0]const u8) !void {
        self.deinit();
        self.* = try init(path);
    }

    fn start(path: [:0]const u8) !@This() {
        const ok = c.fsw_init_library();
        if (ok != c.FSW_OK) {
            return error.CouldNotCreateFsWatcher;
        }

        const ctxt = try allocator.create(Ctx);
        ctxt.* = .{
            .trigger = .{},
            .handle = null,
            .path = path,
        };

        const Callbacks = struct {
            fn spawn(ctx: *Ctx) !void {
                ctx.handle = c.fsw_init_session(c.filter_include) orelse return error.CouldNotInitFsWatcher;
                var oke = c.fsw_add_path(ctx.handle, ctx.path.ptr);
                if (oke != c.FSW_OK) {
                    return error.PathAdditionFailed;
                }

                oke = c.fsw_set_recursive(ctx.handle, true);
                if (oke != c.FSW_OK) {
                    return error.FswSetFailed;
                }
                oke = c.fsw_set_latency(ctx.handle, 1.0);
                if (oke != c.FSW_OK) {
                    return error.FswSetFailed;
                }
                oke = c.fsw_set_callback(ctx.handle, @ptrCast(&event_callback), ctx);
                if (oke != c.FSW_OK) {
                    return error.FswSetFailed;
                }

                std.debug.print("starting monitor\n", .{});
                oke = c.fsw_start_monitor(ctx.handle);
                if (oke != c.FSW_OK) {
                    return error.CouldNotStartWatcher;
                }
            }
            fn event_callback(events: [*c]const c.fsw_cevent, num: c_uint, ctx: ?*Ctx) callconv(.C) void {
                var flags = c.NoOp;
                // flags |= c.Created;
                flags |= c.Updated;
                // flags |= c.Removed;
                // flags |= c.Renamed;
                // flags |= c.OwnerModified;
                // flags |= c.AttributeModified;
                // flags |= c.MovedFrom;
                // flags |= c.MovedTo;

                var valid = false;
                for (events[0..@intCast(num)]) |event| {
                    for (event.flags[0..event.flags_num]) |f| {
                        if (flags & @as(c_int, @intCast(f)) == 0) {
                            continue;
                        }
                        const name = c.fsw_get_event_flag_name(f);
                        std.debug.print("Path: {s}\n", .{event.path});
                        std.debug.print("Event Type: {s}\n", .{std.mem.span(name)});
                        valid = true;
                    }
                }

                if (valid) {
                    ctx.?.trigger.fuse();
                }
            }
        };

        const t = try std.Thread.spawn(.{ .allocator = allocator }, Callbacks.spawn, .{ctxt});
        return .{
            .ctx = ctxt,
            .thread = t,
        };
    }
};

const Fuse = struct {
    fused: std.atomic.Value(bool) = .{ .raw = false },

    fn fuse(self: *@This()) void {
        self.fused.store(true, .release);
    }
    fn unfuse(self: *@This()) bool {
        const res = self.fused.swap(false, .release);
        return res;
    }
    fn check(self: *@This()) bool {
        return self.fused.load(.acquire);
    }
};

const Glslc = struct {
    fn testfn() !void {
        const compiler = Compiler{
            .opt = .fast,
            .stage = .fragment,
        };
        const shader: []const u8 = @embedFile("frag.glsl");
        const bytes = try compiler.compile(allocator, &.{
            .code = shader,
            .definitions = &[_][]const u8{},
        }, .assembly);
        defer allocator.free(bytes);

        std.debug.print("{s}\n", .{bytes});
    }

    const Compiler = struct {
        opt: enum {
            none,
            small,
            fast,
        } = .none,
        lang: enum {
            glsl,
            hlsl,
        } = .glsl,
        stage: enum {
            vertex,
            fragment,
            compute,
        } = .fragment,
        const OutputType = enum {
            assembly,
            spirv,
        };
        const Code = union(enum) {
            code: struct {
                src: []const u8,
                definitions: []const []const u8,
            },
            path: struct {
                main: []const u8,
                include: []const []const u8,
                definitions: []const []const u8,
            },
        };

        fn dump_assembly(self: @This(), alloc: std.mem.Allocator, code: []const u8) !void {
            // std.debug.print("{s}\n", .{code});
            const bytes = try self.compile(alloc, &.{
                .code = code,
                .definitions = &[_][]const u8{},
            }, .assembly);
            defer alloc.free(bytes);
            std.debug.print("{s}\n", .{bytes});
        }

        fn compile(self: @This(), alloc: std.mem.Allocator, code: *const Code, comptime output_type: OutputType) !(switch (output_type) {
            .spirv => []u32,
            .assembly => []u8,
        }) {
            var args = std.ArrayList([]const u8).init(alloc);
            defer {
                for (args.items) |arg| {
                    alloc.free(arg);
                }
                args.deinit();
            }
            try args.append(try alloc.dupe(u8, "glslc"));
            try args.append(try alloc.dupe(u8, switch (self.stage) {
                .fragment => "-fshader-stage=fragment",
                .vertex => "-fshader-stage=vertex",
                .compute => "-fshader-stage=compute",
            }));
            try args.append(try alloc.dupe(u8, switch (self.lang) {
                .glsl => "-xglsl",
                .hlsl => "-xhlsl",
            }));
            try args.append(try alloc.dupe(u8, switch (self.opt) {
                .fast => "-O",
                .small => "-Os",
                .none => "-O0",
            }));
            if (output_type == .assembly) {
                try args.append(try alloc.dupe(u8, "-S"));
            }
            try args.append(try alloc.dupe(u8, "-o-"));
            switch (code.*) {
                .code => |src| {
                    for (src.definitions) |def| {
                        try args.append(try std.fmt.allocPrint(alloc, "-D{s}", .{def}));
                    }
                    try args.append(try alloc.dupe(u8, "-"));
                },
                .path => |paths| {
                    for (paths.definitions) |def| {
                        try args.append(try std.fmt.allocPrint(alloc, "-D{s}", .{def}));
                    }
                    for (paths.include) |inc| {
                        try args.append(try alloc.dupe(u8, "-I"));
                        try args.append(try alloc.dupe(u8, inc));
                    }
                    try args.append(try alloc.dupe(u8, paths.main));
                },
            }

            var child = std.process.Child.init(args.items, alloc);
            child.stdin_behavior = .Pipe;
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;

            try child.spawn();

            const stdin = child.stdin orelse return error.NoStdin;
            child.stdin = null;
            const stdout = child.stdout orelse return error.NoStdout;
            child.stdout = null;
            const stderr = child.stderr orelse return error.NoStderr;
            child.stderr = null;
            defer stdout.close();
            defer stderr.close();

            switch (code.*) {
                .code => |src| {
                    try stdin.writeAll(src.src);
                },
                .path => {},
            }
            stdin.close();

            const err = try child.wait();
            errdefer {
                const msg = stderr.readToEndAlloc(alloc, 1000 * 1000) catch unreachable;
                std.debug.print("{s}\n", .{msg});
                alloc.free(msg);
            }
            switch (err) {
                .Exited => |e| {
                    if (e != 0) {
                        std.debug.print("exited with code: {}\n", .{e});
                        return error.GlslcErroredOut;
                    }
                },
                // .Signal => |code| {},
                // .Stopped => |code| {},
                // .Unknown => |code| {},
                else => |e| {
                    std.debug.print("exited with code: {}\n", .{e});
                    return error.GlslcErroredOut;
                },
            }

            const bytes = try stdout.readToEndAllocOptions(
                alloc,
                1000 * 1000,
                null,
                4,
                null,
            );
            return switch (output_type) {
                .spirv => std.mem.bytesAsSlice(u32, bytes),
                .assembly => bytes,
            };
        }
    };
};

const Shaderc = struct {
    const C = @cImport({
        @cInclude("shaderc/shaderc.h");
    });

    const Shader = struct {
        result: *C.struct_shaderc_compilation_result,

        fn deinit(self: *@This()) void {
            C.shaderc_result_release(self.result);
        }

        /// owned by Shader
        fn bytes(self: *@This()) []const u32 {
            const len = C.shaderc_result_get_length(self.result);
            const res = C.shaderc_result_get_bytes(self.result)[0..len];
            // alignment guranteed when it is spirv
            return @ptrCast(@alignCast(res));
        }
    };

    fn testfn() !void {
        const shader = @embedFile("frag.glsl");
        // std.debug.print("{s}\n", .{shader.ptr[0..shader.len]});

        const compiler = C.shaderc_compiler_initialize() orelse return error.CouldNotInitShaderc;
        defer C.shaderc_compiler_release(compiler);

        const options = C.shaderc_compile_options_initialize() orelse return error.CouldNotInitShaderc;
        defer C.shaderc_compile_options_release(options);

        C.shaderc_compile_options_set_optimization_level(options, C.shaderc_optimization_level_performance);
        C.shaderc_compile_options_set_source_language(options, C.shaderc_source_language_glsl);
        // C.shaderc_compile_options_set_vulkan_rules_relaxed(options, true);

        const result = C.shaderc_compile_into_spv_assembly(
            compiler,
            shader.ptr,
            shader.len,
            C.shaderc_glsl_fragment_shader,
            "frag.glsl",
            "main",
            options,
        ) orelse return error.CouldNotCompileShader;
        errdefer C.shaderc_result_release(result);

        const status = C.shaderc_result_get_compilation_status(result);
        if (status != C.shaderc_compilation_status_success) {
            const msg = C.shaderc_result_get_error_message(result);
            const err = std.mem.span(msg);
            std.debug.print("{s}\n", .{err});
            return error.CouldNotCompileShader;
        }

        const len = C.shaderc_result_get_length(result);
        const bytes = C.shaderc_result_get_bytes(result)[0..len];
        std.debug.print("{s}\n", .{bytes});
    }
};

const Dawn = struct {
    const C = @cImport({
        @cInclude("dawn/webgpu.h");
    });

    fn testfn() !void {}
};

const Glslang = struct {
    const C = @cImport({
        @cInclude("glslang/Include/glslang_c_interface.h");
        @cInclude("glslang/Public/resource_limits_c.h");
        @cInclude("stdio.h");
        @cInclude("stdlib.h");
        @cInclude("stdint.h");
        @cInclude("stdbool.h");
    });

    const SpirVBinary = struct {
        words: ?*C.u_int32_t, // SPIR-V words
        size: usize, // number of words in SPIR-V binary
    };

    fn testfn() !void {
        const shader = @embedFile("shader.glsl");
        const bin = try compileShaderToSPIRV_Vulkan(
            C.GLSLANG_STAGE_VERTEX_MASK | C.GLSLANG_STAGE_FRAGMENT_MASK | C.GLSLANG_STAGE_COMPUTE_MASK,
            shader.ptr,
        );
        _ = bin;
    }

    fn compileShaderToSPIRV_Vulkan(stage: C.glslang_stage_t, shaderSource: [*c]const u8) !SpirVBinary {
        const input = C.glslang_input_t{
            .language = C.GLSLANG_SOURCE_GLSL,
            .stage = stage,
            .client = C.GLSLANG_CLIENT_VULKAN,
            .client_version = C.GLSLANG_TARGET_VULKAN_1_2,
            .target_language = C.GLSLANG_TARGET_SPV,
            .target_language_version = C.GLSLANG_TARGET_SPV_1_5,
            .code = shaderSource,
            .default_version = 100,
            .default_profile = C.GLSLANG_NO_PROFILE,
            .force_default_version_and_profile = C.false,
            .forward_compatible = C.false,
            .messages = C.GLSLANG_MSG_DEFAULT_BIT,
            .resource = C.glslang_default_resource(),
        };

        const shader = C.glslang_shader_create(&input);

        var bin = SpirVBinary{
            .words = null,
            .size = 0,
        };
        if (C.glslang_shader_preprocess(shader, &input) == C.false) {
            _ = C.printf("GLSL preprocessing failed\n");
            _ = C.printf("%s\n", C.glslang_shader_get_info_log(shader));
            _ = C.printf("%s\n", C.glslang_shader_get_info_debug_log(shader));
            _ = C.printf("%s\n", input.code);
            C.glslang_shader_delete(shader);
            return bin;
        }

        if (C.glslang_shader_parse(shader, &input) == C.false) {
            _ = C.printf("GLSL parsing failed\n");
            _ = C.printf("%s\n", C.glslang_shader_get_info_log(shader));
            _ = C.printf("%s\n", C.glslang_shader_get_info_debug_log(shader));
            _ = C.printf("%s\n", C.glslang_shader_get_preprocessed_code(shader));
            C.glslang_shader_delete(shader);
            return bin;
        }

        const program = C.glslang_program_create();
        C.glslang_program_add_shader(program, shader);

        if (C.glslang_program_link(program, C.GLSLANG_MSG_SPV_RULES_BIT | C.GLSLANG_MSG_VULKAN_RULES_BIT) == C.false) {
            _ = C.printf("GLSL linking failed\n");
            _ = C.printf("%s\n", C.glslang_program_get_info_log(program));
            _ = C.printf("%s\n", C.glslang_program_get_info_debug_log(program));
            C.glslang_program_delete(program);
            C.glslang_shader_delete(shader);
            return bin;
        }

        C.glslang_program_SPIRV_generate(program, stage);

        bin.size = C.glslang_program_SPIRV_get_size(program);
        bin.words = @ptrCast(@alignCast(C.malloc(bin.size * @sizeOf(C.u_int32_t))));
        C.glslang_program_SPIRV_get(program, bin.words);

        const spirv_messages = @as(?[*c]const u8, C.glslang_program_SPIRV_get_messages(program));
        if (spirv_messages) |msg| {
            _ = C.printf("%s\n", msg);
        }

        C.glslang_program_delete(program);
        C.glslang_shader_delete(shader);

        return bin;
    }
};

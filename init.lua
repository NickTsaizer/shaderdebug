local uv = vim.uv
local ffi = require("ffi")

ffi.cdef([[
typedef unsigned char uint8_t;
typedef int int32_t;
typedef unsigned int uint32_t;
]])

local M = {}
local preview_ns = vim.api.nvim_create_namespace("shaderdebug-preview")

local default_config = {
    api = "auto",
    auto_preview = false,
    debounce_ms = 180,
    image_size = 512,
    preview = {
        buffer_name = "ShaderDebug Preview",
        split_command = "rightbelow vsplit",
        width_fraction = 0.35,
        top_padding_lines = 8,
        image_gap_lines = 1,
    },
    cache_dir = vim.fn.stdpath("cache") .. "/shaderdebug",
    runner_source = vim.fn.stdpath("config") .. "/lua/shaderdebug/renderer.c",
    runner_binary = vim.fn.stdpath("cache") .. "/shaderdebug/shaderdebug_renderer",
    slangc = vim.fn.exepath("slangc") ~= "" and vim.fn.exepath("slangc") or "slangc",
    glslang_validator = vim.fn.exepath("glslangValidator") ~= "" and vim.fn.exepath("glslangValidator") or "glslangValidator",
    ffmpeg = vim.fn.exepath("ffmpeg") ~= "" and vim.fn.exepath("ffmpeg") or "ffmpeg",
    slang_profile = "sm_6_5",
}

local config = vim.deepcopy(default_config)

local state = {
    auto_enabled = false,
    timer = nil,
    pending_request = nil,
    active_process = nil,
    render_request_id = 0,
    preview_buf = nil,
    preview_win = nil,
    preview_actions = {},
    preview_context = nil,
    preview_text_line_count = 0,
    image = nil,
    augroup = nil,
    last_result = nil,
    input_overrides = {},
    input_editors = {},
}

local disable_auto_preview
local show_preview
local start_preview_job

local debug_helpers = table.concat({
    "",
    "float4 __shaderdebug_toColor(float value) { return float4(value, value, value, 1.0); }",
    "float4 __shaderdebug_toColor(float2 value) { return float4(value.x, value.y, 0.0, 1.0); }",
    "float4 __shaderdebug_toColor(float3 value) { return float4(value, 1.0); }",
    "float4 __shaderdebug_toColor(float4 value) { return value; }",
    "float4 __shaderdebug_toColor(int value) { float f = clamp(float(value) / 255.0, 0.0, 1.0); return float4(f, f, f, 1.0); }",
    "float4 __shaderdebug_toColor(int2 value) { return float4(clamp(float2(value) / 255.0, 0.0, 1.0), 0.0, 1.0); }",
    "float4 __shaderdebug_toColor(int3 value) { return float4(clamp(float3(value) / 255.0, 0.0, 1.0), 1.0); }",
    "float4 __shaderdebug_toColor(int4 value) { return clamp(float4(value) / 255.0, 0.0, 1.0); }",
    "float4 __shaderdebug_toColor(uint value) { float f = clamp(float(value) / 255.0, 0.0, 1.0); return float4(f, f, f, 1.0); }",
    "float4 __shaderdebug_toColor(uint2 value) { return float4(clamp(float2(value) / 255.0, 0.0, 1.0), 0.0, 1.0); }",
    "float4 __shaderdebug_toColor(uint3 value) { return float4(clamp(float3(value) / 255.0, 0.0, 1.0), 1.0); }",
    "float4 __shaderdebug_toColor(uint4 value) { return clamp(float4(value) / 255.0, 0.0, 1.0); }",
    "float4 __shaderdebug_toColor(bool value) { return value ? float4(1.0, 1.0, 1.0, 1.0) : float4(0.0, 0.0, 0.0, 1.0); }",
    "float4 __shaderdebug_toColor(bool2 value) { return float4(value.x ? 1.0 : 0.0, value.y ? 1.0 : 0.0, 0.0, 1.0); }",
    "float4 __shaderdebug_toColor(bool3 value) { return float4(value.x ? 1.0 : 0.0, value.y ? 1.0 : 0.0, value.z ? 1.0 : 0.0, 1.0); }",
    "float4 __shaderdebug_toColor(bool4 value) { return float4(value.x ? 1.0 : 0.0, value.y ? 1.0 : 0.0, value.z ? 1.0 : 0.0, value.w ? 1.0 : 0.0); }",
    "",
}, "\n")

local function notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = "shaderdebug" })
end

local function setup_preview_highlights()
    vim.api.nvim_set_hl(0, "ShaderDebugHeader", { link = "Title", bold = true })
    vim.api.nvim_set_hl(0, "ShaderDebugInputDefault", { link = "Identifier", bold = true })
    vim.api.nvim_set_hl(0, "ShaderDebugInputOverride", { link = "Function", bold = true })
    vim.api.nvim_set_hl(0, "ShaderDebugInputName", { link = "Identifier", bold = true })
    vim.api.nvim_set_hl(0, "ShaderDebugInputDetail", { link = "Comment" })
    vim.api.nvim_set_hl(0, "ShaderDebugInputEmpty", { link = "NonText" })
end

local function ensure_cache_dir()
    vim.fn.mkdir(config.cache_dir, "p")
end

local function read_text(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end

    local content = file:read("*a")
    file:close()
    return content
end

local function write_text(path, content)
    local file, err = io.open(path, "wb")
    if not file then
        return nil, err
    end

    file:write(content)
    file:close()
    return true
end

local function write_binary(path, content)
    local file, err = io.open(path, "wb")
    if not file then
        return nil, err
    end

    file:write(content)
    file:close()
    return true
end

local function system_wait(cmd, opts)
    return vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait()
end

local function system_start(cmd, opts, on_exit)
    return vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {}), function(result)
        vim.schedule(function()
            on_exit(result)
        end)
    end)
end

local function file_mtime(path)
    local stat = uv.fs_stat(path)
    return stat and stat.mtime and stat.mtime.sec or 0
end

local function ensure_runner()
    ensure_cache_dir()

    local source = config.runner_source
    local binary = config.runner_binary
    local needs_build = vim.fn.executable(binary) ~= 1 or file_mtime(source) > file_mtime(binary)
    if not needs_build then
        return true
    end

    local command = string.format(
        'c++ -x c++ "%s" -O2 -std=c++20 -o "%s" $(pkg-config --cflags --libs vulkan libpng)',
        source,
        binary
    )
    local result = system_wait({ "bash", "-lc", command })
    if result.code ~= 0 then
        notify("Failed to build shaderdebug Vulkan renderer:\n" .. (result.stderr ~= "" and result.stderr or result.stdout), vim.log.levels.ERROR)
        return false
    end

    return true
end

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function sanitize_name(name)
    return (name:gsub("[^%w_%-]", "_"))
end

local function read_lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function current_line_expression(line)
    local return_expr = line:match("^%s*return%s+(.+);%s*$")
    if return_expr then
        return trim(return_expr)
    end

    if line:find("==", 1, true) or line:find("!=", 1, true) or line:find("<=", 1, true) or line:find(">=", 1, true) then
        return nil
    end

    local _, operator, rhs = line:match("^%s*(.-)%s*([%+%-%*/%%]?=)%s*(.+);%s*$")
    if rhs and operator == "=" then
        return trim(rhs)
    end

    return nil
end

local function find_fragment_entry(lines)
    local saw_fragment_attr = false

    for _, line in ipairs(lines) do
        if line:match('%[shader%(%s*"fragment"%s*%)%]') or line:match("%[shader%(%s*'fragment'%s*%)%]") then
            saw_fragment_attr = true
        elseif saw_fragment_attr then
            local function_name = line:match("([%a_][%w_]*)%s*%(")
            if function_name then
                return function_name
            end
        end
    end

    return nil
end

local function brace_delta(line)
    local opens = select(2, line:gsub("{", ""))
    local closes = select(2, line:gsub("}", ""))
    return opens - closes
end

local function find_function_end(lines, cursor_line)
    local depth = 0
    for i = 1, cursor_line do
        depth = depth + brace_delta(lines[i])
    end

    local running_depth = depth
    for i = cursor_line + 1, #lines do
        running_depth = running_depth + brace_delta(lines[i])
        if running_depth <= 0 then
            return i
        end
    end

    return #lines
end

local function build_instrumented_source(bufnr, cursor_line)
    local lines = read_lines(bufnr)
    local line = lines[cursor_line]
    if not line then
        return nil, "No line under cursor"
    end

    local expression = current_line_expression(line)
    if not expression then
        return nil, "Cursor line must be a simple assignment or return statement"
    end

    local entry = find_fragment_entry(lines)
    if not entry then
        return nil, "No [shader(\"fragment\")] entry point found"
    end

    local new_lines = vim.deepcopy(lines)
    local indent = line:match("^(%s*)") or ""
    new_lines[cursor_line] = indent .. "return __shaderdebug_toColor(" .. expression .. ");"

    local depth = 0
    for i = 1, cursor_line do
        depth = depth + brace_delta(lines[i])
    end

    if depth > 0 then
        local running_depth = depth
        for i = cursor_line + 1, #new_lines do
            local brace_tokens = {}
            for token in lines[i]:gmatch("[{}]") do
                brace_tokens[#brace_tokens + 1] = token
            end

            new_lines[i] = #brace_tokens > 0 and table.concat(brace_tokens, " ") or ""
            running_depth = running_depth + brace_delta(lines[i])
            if running_depth <= 0 then
                break
            end
        end

        local function_end = find_function_end(lines, cursor_line)
        if function_end >= cursor_line then
            table.insert(new_lines, function_end, indent .. "return float4(0.0, 0.0, 0.0, 1.0);")
        end
    end

    table.insert(new_lines, debug_helpers)

    return {
        source = table.concat(new_lines, "\n") .. "\n",
        entry = entry,
        expression = expression,
        cursor_line = cursor_line,
    }
end

local function write_temp_source(bufnr, payload)
    ensure_cache_dir()

    local source_name = vim.api.nvim_buf_get_name(bufnr)
    local stem = vim.fn.fnamemodify(source_name ~= "" and source_name or "shader", ":t:r")
    local prefix = string.format("%s/%s-line-%d.debug", config.cache_dir, sanitize_name(stem), payload.cursor_line)
    local temp_source = prefix .. ".slang"
    local output_png = prefix .. ".png"

    local ok, err = write_text(temp_source, payload.source)
    if not ok then
        return nil, err
    end

    return temp_source, output_png, prefix
end

local function parse_reflection(path)
    local content = read_text(path)
    if not content then
        return nil, "Failed to read reflection JSON"
    end

    local ok, decoded = pcall(vim.json.decode, content)
    if not ok then
        return nil, decoded
    end

    return decoded
end

local function find_entry_reflection(reflection, entry_name)
    for _, entry in ipairs(reflection.entryPoints or {}) do
        if entry.name == entry_name then
            return entry
        end
    end

    for _, entry in ipairs(reflection.entryPoints or {}) do
        if entry.stage == "fragment" then
            return entry
        end
    end

    return nil
end

local function binding_map(entry)
    local map = {}
    for _, binding in ipairs(entry.bindings or {}) do
        if binding.name and binding.binding and (binding.binding.used == nil or binding.binding.used ~= 0) then
            map[binding.name] = binding.binding
        end
    end
    return map
end

local function detect_api(reflection, entry)
    if config.api ~= "auto" then
        return config.api
    end

    if entry and entry.stage == "fragment" then
        return "vulkan"
    end

    for _, parameter in ipairs(reflection.parameters or {}) do
        if parameter.binding and parameter.binding.kind == "descriptorTableSlot" then
            return "vulkan"
        end
    end

    return "vulkan"
end

local function reflection_resource_spec(parameter, used_binding)
    local typeinfo = parameter.type or {}
    local spec = {
        name = parameter.name,
        set = (used_binding and used_binding.space) or (parameter.binding and parameter.binding.space) or 0,
        binding = (used_binding and used_binding.index) or (parameter.binding and parameter.binding.index) or 0,
        used = true,
        raw_type = typeinfo,
    }

    if typeinfo.kind == "constantBuffer" then
        spec.kind = "uniform_buffer"
        spec.type_info = typeinfo.elementType
        spec.layout_binding = typeinfo.elementVarLayout and typeinfo.elementVarLayout.binding or nil
        return spec
    end

    if typeinfo.kind == "resource" and typeinfo.baseShape == "structuredBuffer" then
        spec.kind = "storage_buffer"
        spec.type_info = typeinfo.resultType
        spec.is_array = true
        return spec
    end

    if typeinfo.kind == "resource" and typeinfo.baseShape == "texture2D" then
        spec.kind = typeinfo.combined and "combined_image_sampler" or "sampled_image"
        spec.type_info = typeinfo
        spec.descriptor_count = 1
        return spec
    end

    if typeinfo.kind == "samplerState" then
        spec.kind = "sampler"
        spec.type_info = typeinfo
        spec.descriptor_count = 1
        return spec
    end

    if typeinfo.kind == "array" and typeinfo.elementType and typeinfo.elementType.kind == "resource" and typeinfo.elementType.baseShape == "texture2D" then
        spec.kind = typeinfo.elementType.combined and "combined_image_sampler" or "sampled_image"
        spec.type_info = typeinfo.elementType
        spec.is_array = true
        spec.descriptor_count = math.max(typeinfo.elementCount or 0, 1)
        return spec
    end

    return nil
end

local function collect_resource_specs(reflection, entry)
    local specs = {}
    local used_map = binding_map(entry)
    for _, parameter in ipairs(reflection.parameters or {}) do
        local used_binding = used_map[parameter.name]
        if used_binding then
            local spec = reflection_resource_spec(parameter, used_binding)
            if spec then
                table.insert(specs, spec)
            end
        end
    end

    table.sort(specs, function(a, b)
        if a.set == b.set then
            return a.binding < b.binding
        end
        return a.set < b.set
    end)

    return specs
end

local function glsl_type_for_type(typeinfo)
    local kind = typeinfo.kind
    if kind == "scalar" then
        local scalar = typeinfo.scalarType
        if scalar == "float32" then
            return "float"
        elseif scalar == "int32" then
            return "int"
        elseif scalar == "uint32" then
            return "uint"
        elseif scalar == "bool" then
            return "bool"
        end
    elseif kind == "vector" then
        local scalar = typeinfo.elementType and typeinfo.elementType.scalarType
        local count = typeinfo.elementCount or 1
        if scalar == "float32" then
            return ({ [2] = "vec2", [3] = "vec3", [4] = "vec4" })[count]
        elseif scalar == "int32" then
            return ({ [2] = "ivec2", [3] = "ivec3", [4] = "ivec4" })[count]
        elseif scalar == "uint32" then
            return ({ [2] = "uvec2", [3] = "uvec3", [4] = "uvec4" })[count]
        elseif scalar == "bool" then
            return ({ [2] = "bvec2", [3] = "bvec3", [4] = "bvec4" })[count]
        end
    end

    return nil
end

local function default_glsl_expr(typeinfo, location, name)
    local kind = typeinfo.kind
    local scalar = typeinfo.scalarType or (typeinfo.elementType and typeinfo.elementType.scalarType)
    local uv = "__shaderdebug_uv"
    local centered = "__shaderdebug_centered"

    if kind == "scalar" then
        if scalar == "float32" then
            if name == "plane_coord" then
                return "0.0"
            end
            return uv .. ".x"
        elseif scalar == "int32" then
            return "int(floor(" .. uv .. ".x * 4.0))"
        elseif scalar == "uint32" then
            return "uint(floor(" .. uv .. ".x * 4.0))"
        elseif scalar == "bool" then
            return uv .. ".x > 0.5"
        end
    elseif kind == "vector" then
        local count = typeinfo.elementCount or 1
        if scalar == "float32" then
            if count == 2 then
                return uv
            elseif count == 3 then
                if name == "world_pos" then
                    return "vec3(" .. centered .. ", 0.0)"
                end
                return "vec3(" .. uv .. ", 1.0)"
            elseif count == 4 then
                return "vec4(" .. uv .. ", 0.0, 1.0)"
            end
        elseif scalar == "int32" then
            if count == 2 then
                return "ivec2(floor(" .. uv .. " * 8.0))"
            elseif count == 3 then
                return "ivec3(int(floor(" .. uv .. ".x * 8.0)), int(floor(" .. uv .. ".y * 8.0)), " .. tostring(location) .. ")"
            elseif count == 4 then
                return "ivec4(int(floor(" .. uv .. ".x * 8.0)), int(floor(" .. uv .. ".y * 8.0)), " .. tostring(location) .. ", 1)"
            end
        elseif scalar == "uint32" then
            if count == 2 then
                return "uvec2(uint(floor(" .. uv .. ".x * 8.0)), uint(floor(" .. uv .. ".y * 8.0)))"
            elseif count == 3 then
                return "uvec3(uint(floor(" .. uv .. ".x * 8.0)), uint(floor(" .. uv .. ".y * 8.0)), uint(" .. tostring(location) .. "))"
            elseif count == 4 then
                return "uvec4(uint(floor(" .. uv .. ".x * 8.0)), uint(floor(" .. uv .. ".y * 8.0)), uint(" .. tostring(location) .. "), 1u)"
            end
        elseif scalar == "bool" then
            if count == 2 then
                return "bvec2(" .. uv .. ".x > 0.5, " .. uv .. ".y > 0.5)"
            elseif count == 3 then
                return "bvec3(" .. uv .. ".x > 0.5, " .. uv .. ".y > 0.5, true)"
            elseif count == 4 then
                return "bvec4(" .. uv .. ".x > 0.5, " .. uv .. ".y > 0.5, true, true)"
            end
        end
    end

    return nil
end

local function collect_fragment_varyings(entry)
    local varyings = {}
    local function push(name, typeinfo, binding)
        if binding and binding.kind == "varyingInput" and binding.index ~= nil then
            varyings[#varyings + 1] = {
                name = name,
                type = typeinfo,
                location = binding.index,
            }
        end
    end

    for _, parameter in ipairs(entry.parameters or {}) do
        local typeinfo = parameter.type or {}
        if typeinfo.kind == "struct" then
            for _, field in ipairs(typeinfo.fields or {}) do
                push(field.name, field.type, field.binding)
            end
        else
            push(parameter.name, typeinfo, parameter.binding)
        end
    end

    table.sort(varyings, function(a, b)
        return a.location < b.location
    end)

    local deduped = {}
    local by_location = {}
    for _, varying in ipairs(varyings) do
        if not by_location[varying.location] then
            by_location[varying.location] = true
            table.insert(deduped, varying)
        end
    end

    return deduped
end

local function build_vertex_glsl(entry)
    local varyings = collect_fragment_varyings(entry)
    local lines = {
        "#version 450",
    }

    for _, varying in ipairs(varyings) do
        local glsl_type = glsl_type_for_type(varying.type)
        if not glsl_type then
            return nil, string.format("Unsupported fragment varying type for '%s'", varying.name)
        end
        table.insert(lines, string.format("layout(location = %d) out %s v_%d;", varying.location, glsl_type, varying.location))
    end

    vim.list_extend(lines, {
        "vec2 __shaderdebug_positions[3] = vec2[](",
        "    vec2(-1.0, -1.0),",
        "    vec2( 3.0, -1.0),",
        "    vec2(-1.0,  3.0)",
        ");",
        "void main()",
        "{",
        "    vec2 pos = __shaderdebug_positions[gl_VertexIndex];",
        "    gl_Position = vec4(pos, 0.0, 1.0);",
        "    vec2 __shaderdebug_uv = pos * 0.5 + 0.5;",
        "    vec2 __shaderdebug_centered = __shaderdebug_uv * 2.0 - 1.0;",
    })

    for _, varying in ipairs(varyings) do
        local expr = default_glsl_expr(varying.type, varying.location, varying.name)
        if not expr then
            return nil, string.format("Unsupported varying default expression for '%s'", varying.name)
        end
        table.insert(lines, string.format("    v_%d = %s;", varying.location, expr))
    end

    table.insert(lines, "}")
    table.insert(lines, "")

    return table.concat(lines, "\n")
end

local function compile_vertex_spirv(vertex_glsl, prefix)
    local source_path = prefix .. ".vert.glsl"
    local output_path = prefix .. ".vert.spv"
    local ok, err = write_text(source_path, vertex_glsl)
    if not ok then
        return nil, err
    end

    local result = system_wait({
        config.glslang_validator,
        "-V",
        "--target-env",
        "vulkan1.2",
        "-S",
        "vert",
        "-o",
        output_path,
        source_path,
    })
    if result.code ~= 0 then
        return nil, (result.stderr ~= "" and result.stderr) or result.stdout
    end

    return output_path
end

local function shader_key_for_buffer(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    return vim.fn.fnamemodify(path ~= "" and path or ("buffer-" .. bufnr), ":p")
end

local function get_input_store(shader_key)
    state.input_overrides[shader_key] = state.input_overrides[shader_key] or {}
    return state.input_overrides[shader_key]
end

local function table_is_array(value)
    if type(value) ~= "table" then
        return false
    end

    local count = 0
    for key, _ in pairs(value) do
        if type(key) ~= "number" then
            return false
        end
        count = count + 1
    end

    for i = 1, count do
        if value[i] == nil then
            return false
        end
    end

    return true
end

local function flatten_numeric_array(value)
    if type(value) ~= "table" then
        return { value }
    end

    local out = {}
    for _, item in ipairs(value) do
        if type(item) == "table" then
            vim.list_extend(out, flatten_numeric_array(item))
        else
            out[#out + 1] = item
        end
    end
    return out
end

local function struct_size_from_fields(fields)
    local size = 0
    for _, field in ipairs(fields or {}) do
        local binding = field.binding or {}
        if binding.offset and binding.size then
            size = math.max(size, binding.offset + binding.size)
        elseif field.type then
            size = math.max(size, struct_size_from_fields(field.type.fields or {}))
        end
    end
    return size
end

local function element_size_for_type(typeinfo)
    local kind = typeinfo.kind
    if kind == "scalar" then
        return 4
    elseif kind == "vector" then
        return (typeinfo.elementCount or 1) * 4
    elseif kind == "matrix" then
        return (typeinfo.rowCount or 1) * (typeinfo.columnCount or 1) * 4
    elseif kind == "struct" then
        return struct_size_from_fields(typeinfo.fields)
    elseif kind == "array" then
        local stride = (typeinfo.binding and typeinfo.binding.elementStride) or element_size_for_type(typeinfo.elementType)
        local count = math.max(typeinfo.elementCount or 0, 1)
        return stride * count
    end
    return 0
end

local function identity_matrix(rows, cols)
    local out = {}
    for row = 1, rows do
        for col = 1, cols do
            out[#out + 1] = row == col and 1 or 0
        end
    end
    return out
end

local function default_value_for_type(typeinfo, field_name, context)
    local kind = typeinfo.kind
    if kind == "scalar" then
        if typeinfo.scalarType == "bool" then
            return false
        end
        return 0
    elseif kind == "vector" then
        if field_name == "resolution" and (typeinfo.elementCount or 0) == 2 and typeinfo.elementType and typeinfo.elementType.scalarType == "float32" then
            return { context.image_size, context.image_size }
        end
        if field_name == "tint" and (typeinfo.elementCount or 0) == 4 and typeinfo.elementType and typeinfo.elementType.scalarType == "float32" then
            return { 1, 1, 1, 0.5 }
        end
        if field_name == "camera_pos" and (typeinfo.elementCount or 0) == 4 then
            return { 0, 0, 0, 1 }
        end
        local out = {}
        for i = 1, (typeinfo.elementCount or 1) do
            out[i] = 0
        end
        return out
    elseif kind == "matrix" then
        if field_name == "view" or field_name == "proj" or field_name == "model" then
            return identity_matrix(typeinfo.rowCount or 1, typeinfo.columnCount or 1)
        end
        local out = {}
        for i = 1, (typeinfo.rowCount or 1) * (typeinfo.columnCount or 1) do
            out[i] = 0
        end
        return out
    elseif kind == "struct" then
        local out = {}
        for _, field in ipairs(typeinfo.fields or {}) do
            out[field.name] = default_value_for_type(field.type, field.name, context)
        end
        return out
    elseif kind == "array" then
        local count = typeinfo.elementCount and typeinfo.elementCount > 0 and typeinfo.elementCount or 1
        local out = {}
        for i = 1, count do
            out[i] = default_value_for_type(typeinfo.elementType, field_name, context)
        end
        return out
    end

    return nil
end

local function merge_values(default_value, override_value)
    if override_value == nil then
        return default_value
    end
    if type(default_value) ~= "table" or type(override_value) ~= "table" then
        return override_value
    end

    if table_is_array(default_value) or table_is_array(override_value) then
        return override_value
    end

    local merged = vim.deepcopy(default_value)
    for key, value in pairs(override_value) do
        merged[key] = merge_values(merged[key], value)
    end
    return merged
end

local function write_scalar(ptr, offset, scalar_type, value)
    if scalar_type == "float32" then
        ffi.cast("float*", ptr + offset)[0] = tonumber(value or 0)
    elseif scalar_type == "int32" then
        ffi.cast("int32_t*", ptr + offset)[0] = tonumber(value or 0)
    elseif scalar_type == "uint32" then
        ffi.cast("uint32_t*", ptr + offset)[0] = tonumber(value or 0)
    elseif scalar_type == "bool" then
        ffi.cast("uint32_t*", ptr + offset)[0] = value and 1 or 0
    end
end

local function pack_value(ptr, base_offset, typeinfo, value, binding)
    local kind = typeinfo.kind
    if kind == "scalar" then
        write_scalar(ptr, base_offset, typeinfo.scalarType, value)
        return
    end

    if kind == "vector" then
        local values = flatten_numeric_array(value or {})
        local scalar_type = typeinfo.elementType and typeinfo.elementType.scalarType or "float32"
        for index = 1, (typeinfo.elementCount or 1) do
            write_scalar(ptr, base_offset + (index - 1) * 4, scalar_type, values[index] or 0)
        end
        return
    end

    if kind == "matrix" then
        local values = flatten_numeric_array(value or {})
        local scalar_type = typeinfo.elementType and typeinfo.elementType.scalarType or "float32"
        local count = (typeinfo.rowCount or 1) * (typeinfo.columnCount or 1)
        for index = 1, count do
            write_scalar(ptr, base_offset + (index - 1) * 4, scalar_type, values[index] or 0)
        end
        return
    end

    if kind == "struct" then
        local object = type(value) == "table" and value or {}
        for _, field in ipairs(typeinfo.fields or {}) do
            local field_binding = field.binding or {}
            local field_offset = base_offset + (field_binding.offset or 0)
            pack_value(ptr, field_offset, field.type, object[field.name], field_binding)
        end
        return
    end

    if kind == "array" then
        local array_value = table_is_array(value) and value or {}
        local stride = (binding and binding.elementStride and binding.elementStride > 0) and binding.elementStride or element_size_for_type(typeinfo.elementType)
        local count = typeinfo.elementCount and typeinfo.elementCount > 0 and typeinfo.elementCount or #array_value
        if count == 0 then
            count = 1
        end
        for index = 1, count do
            pack_value(ptr, base_offset + (index - 1) * stride, typeinfo.elementType, array_value[index], typeinfo.elementType.binding)
        end
    end
end

local function parse_data_argument(argument)
    local payload = argument
    if payload:sub(1, 1) == "@" then
        payload = read_text(payload:sub(2))
    elseif uv.fs_stat(payload) then
        payload = read_text(payload)
    end

    if not payload then
        return nil, "Failed to read data payload"
    end

    local ok, decoded = pcall(vim.json.decode, payload)
    if not ok then
        return nil, decoded
    end
    return decoded
end

local function convert_image_if_needed(source_path, prefix, name, index)
    if source_path == "__default__" then
        return source_path
    end

    local absolute = vim.fn.fnamemodify(source_path, ":p")

    if vim.fn.filereadable(absolute) ~= 1 then
        return nil, "Image not found: " .. absolute
    end

    if absolute:lower():match("%.png$") then
        return absolute
    end

    local cache_dir = config.cache_dir .. "/image-cache"
    vim.fn.mkdir(cache_dir, "p")
    local output_path = string.format(
        "%s/%s-%d.png",
        cache_dir,
        sanitize_name(absolute),
        file_mtime(absolute)
    )

    if vim.fn.filereadable(output_path) == 1 then
        return output_path
    end

    local result = system_wait({
        config.ffmpeg,
        "-y",
        "-i",
        absolute,
        output_path,
    })
    if result.code ~= 0 then
        return nil, (result.stderr ~= "" and result.stderr) or result.stdout
    end
    return output_path
end

local function build_buffer_blob(spec, override_value, context)
    if spec.kind == "uniform_buffer" then
        local typeinfo = spec.type_info
        local merged_value = merge_values(default_value_for_type(typeinfo, spec.name, context), override_value)
        local size = (spec.layout_binding and spec.layout_binding.size) or struct_size_from_fields(typeinfo.fields)
        local storage = ffi.new("uint8_t[?]", size)
        ffi.fill(storage, size, 0)
        pack_value(ffi.cast("uint8_t*", storage), 0, typeinfo, merged_value, spec.layout_binding)
        return ffi.string(storage, size)
    end

    if spec.kind == "storage_buffer" then
        local typeinfo = spec.type_info
        local default_element = default_value_for_type(typeinfo, spec.name, context)
        local values = override_value
        if type(values) ~= "table" or not table_is_array(values) then
            values = { merge_values(default_element, values or {}) }
        else
            local merged = {}
            for index, value in ipairs(values) do
                merged[index] = merge_values(default_element, value)
            end
            values = merged
        end

        local element_size = struct_size_from_fields(typeinfo.fields)
        local size = math.max(#values, 1) * math.max(element_size, 4)
        local storage = ffi.new("uint8_t[?]", size)
        ffi.fill(storage, size, 0)
        local ptr = ffi.cast("uint8_t*", storage)
        for index, value in ipairs(values) do
            pack_value(ptr, (index - 1) * element_size, typeinfo, value)
        end
        return ffi.string(storage, size)
    end

    return nil, "Unsupported buffer kind: " .. spec.kind
end

local function prepare_manifest(specs, shader_key, prefix, context)
    local manifest_path = prefix .. ".manifest.tsv"
    local store = get_input_store(shader_key)
    local lines = {}
    local prepared_specs = {}

    for _, spec in ipairs(specs) do
        local override = store[spec.name]
        local manifest_fields = {
            "resource",
            spec.name,
            spec.kind,
            tostring(spec.set),
            tostring(spec.binding),
        }
        local source_label = "default"

        if spec.kind == "combined_image_sampler" or spec.kind == "sampled_image" then
            local paths = { "__default__" }
            if override and override.kind == "images" then
                paths = override.values
                source_label = "override"
            end
            if not spec.is_array then
                paths = { paths[1] or "__default__" }
            end

            local converted = {}
            for index, path in ipairs(paths) do
                local actual, err = convert_image_if_needed(path, prefix, spec.name, index)
                if not actual then
                    return nil, err
                end
                converted[#converted + 1] = actual
            end

            manifest_fields[#manifest_fields + 1] = tostring(#converted)
            vim.list_extend(manifest_fields, converted)
            spec.descriptor_count = #converted
            spec.source_label = source_label
            spec.bound_values = converted
        elseif spec.kind == "sampler" then
            local sampler_mode = override and override.mode or "linear"
            manifest_fields[#manifest_fields + 1] = "1"
            manifest_fields[#manifest_fields + 1] = sampler_mode
            spec.descriptor_count = 1
            spec.source_label = override and "override" or "default"
            spec.bound_values = { sampler_mode }
        elseif spec.kind == "uniform_buffer" or spec.kind == "storage_buffer" then
            local blob, err = build_buffer_blob(spec, override and override.value or nil, context)
            if not blob then
                return nil, err
            end
            local buffer_path = string.format("%s.%s.bin", prefix, sanitize_name(spec.name))
            local ok, write_err = write_binary(buffer_path, blob)
            if not ok then
                return nil, write_err
            end
            manifest_fields[#manifest_fields + 1] = "1"
            manifest_fields[#manifest_fields + 1] = buffer_path
            spec.descriptor_count = 1
            spec.source_label = override and "override" or "default"
            spec.bound_values = { buffer_path }
        else
            return nil, "Unsupported reflected resource kind: " .. spec.kind
        end

        lines[#lines + 1] = table.concat(manifest_fields, "\t")
        prepared_specs[#prepared_specs + 1] = spec
    end

    local ok, err = write_text(manifest_path, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
    if not ok then
        return nil, err
    end

    return manifest_path, prepared_specs
end

local function fragment_compile_spec(temp_source, prefix, entry)
    return {
        fragment_spv = prefix .. ".frag.spv",
        reflection_json = prefix .. ".reflect.json",
        command = {
            config.slangc,
            "-target",
            "spirv",
            "-profile",
            config.slang_profile,
            "-fvk-use-entrypoint-name",
            "-fvk-use-scalar-layout",
            "-entry",
            entry,
            "-stage",
            "fragment",
            "-reflection-json",
            prefix .. ".reflect.json",
            temp_source,
            "-o",
            prefix .. ".frag.spv",
        },
    }
end

local function vertex_compile_spec(prefix)
    return {
        source_path = prefix .. ".vert.glsl",
        output_path = prefix .. ".vert.spv",
        command = {
            config.glslang_validator,
            "-V",
            "--target-env",
            "vulkan1.2",
            "-S",
            "vert",
            "-o",
            prefix .. ".vert.spv",
            prefix .. ".vert.glsl",
        },
    }
end

local function render_command_spec(vertex_spv, fragment_spv, manifest_path, output_png, entry)
    return {
        config.runner_binary,
        "--vertex",
        vertex_spv,
        "--fragment",
        fragment_spv,
        "--manifest",
        manifest_path,
        "--entry",
        entry,
        "--output",
        output_png,
        "--size",
        tostring(config.image_size),
    }
end

local function compile_fragment_spirv(temp_source, prefix, entry)
    local spec = fragment_compile_spec(temp_source, prefix, entry)
    local result = system_wait(spec.command)

    if result.code ~= 0 then
        return nil, (result.stderr ~= "" and result.stderr) or result.stdout
    end

    return spec.fragment_spv, spec.reflection_json
end

local function render_vulkan(vertex_spv, fragment_spv, manifest_path, output_png, entry)
    local result = system_wait(render_command_spec(vertex_spv, fragment_spv, manifest_path, output_png, entry))

    if result.code ~= 0 then
        return nil, (result.stderr ~= "" and result.stderr) or result.stdout
    end

    return true
end

local function current_cursor_line_for_buffer(bufnr)
    local current_buf = vim.api.nvim_get_current_buf()
    if current_buf == bufnr then
        return vim.api.nvim_win_get_cursor(0)[1]
    end

    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
        return vim.api.nvim_win_get_cursor(winid)[1]
    end

    return 1
end

local function stop_active_process()
    if state.active_process then
        pcall(state.active_process.kill, state.active_process, 15)
        state.active_process = nil
    end
end

local function input_summary_line(spec)
    local detail = "default"
    if spec.kind == "combined_image_sampler" or spec.kind == "sampled_image" then
        if spec.bound_values and #spec.bound_values > 0 then
            if spec.bound_values[1] == "__default__" then
                detail = "default image"
            else
                local names = {}
                for _, path in ipairs(spec.bound_values) do
                    names[#names + 1] = vim.fn.fnamemodify(path, ":t")
                end
                detail = table.concat(names, ", ")
            end
        end
    elseif spec.kind == "sampler" then
        detail = spec.bound_values and spec.bound_values[1] or "linear"
    elseif spec.source_label == "override" then
        detail = "custom data"
    else
        detail = "default data"
    end

    return string.format("• %s [%s] set=%d binding=%d → %s", spec.name, spec.kind, spec.set, spec.binding, detail)
end

local function input_detail_lines(spec)
    if spec.kind == "combined_image_sampler" or spec.kind == "sampled_image" then
        if spec.bound_values and #spec.bound_values > 0 then
            if spec.bound_values[1] == "__default__" then
                return { "  image: default checkerboard" }
            end

            local lines = {}
            for index, path in ipairs(spec.bound_values) do
                lines[#lines + 1] = string.format("  image[%d]: %s", index, path)
            end
            return lines
        end
        return { "  image: press <Enter> to choose path" }
    end

    if spec.kind == "sampler" then
        local mode = spec.bound_values and spec.bound_values[1] or "linear"
        return { string.format("  sampler: %s", mode) }
    end

    if spec.kind == "uniform_buffer" or spec.kind == "storage_buffer" then
        if spec.bound_values and #spec.bound_values > 0 then
            return { string.format("  data: %s", spec.bound_values[1]) }
        end
        return { "  data: press <Enter> to edit JSON" }
    end

    return {}
end

local function result_context(result)
    return {
        bufnr = result.bufnr,
        cursor_line = result.cursor_line,
        shader_key = result.shader_key,
    }
end

local function rerender_context(context)
    if not context or not context.bufnr or not vim.api.nvim_buf_is_valid(context.bufnr) then
        return nil, "Source shader buffer is no longer valid"
    end

    return start_preview_job({ bufnr = context.bufnr, cursor_line = context.cursor_line })
end

local function input_store_for_spec(spec, shader_key)
    local store = get_input_store(shader_key)
    return store[spec.name]
end

local function default_json_for_spec(spec, context)
    if spec.kind == "uniform_buffer" then
        return default_value_for_type(spec.type_info, spec.name, { image_size = config.image_size })
    end

    if spec.kind == "storage_buffer" then
        return { default_value_for_type(spec.type_info, spec.name, { image_size = config.image_size }) }
    end

    return nil
end

local function encode_json_pretty(value, indent)
    indent = indent or 0
    local pad = string.rep("  ", indent)
    local next_pad = string.rep("  ", indent + 1)
    local value_type = type(value)

    if value_type == "nil" then
        return "null"
    elseif value_type == "boolean" or value_type == "number" then
        return tostring(value)
    elseif value_type == "string" then
        return vim.json.encode(value)
    elseif value_type ~= "table" then
        return vim.json.encode(tostring(value))
    end

    if table_is_array(value) then
        if #value == 0 then
            return "[]"
        end

        local parts = {}
        for _, item in ipairs(value) do
            parts[#parts + 1] = next_pad .. encode_json_pretty(item, indent + 1)
        end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
    end

    local keys = vim.tbl_keys(value)
    table.sort(keys)
    if #keys == 0 then
        return "{}"
    end

    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = next_pad .. vim.json.encode(key) .. ": " .. encode_json_pretty(value[key], indent + 1)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
end

local function set_image_input_for(shader_key, name, path)
    get_input_store(shader_key)[name] = { kind = "images", values = { path } }
    notify(string.format("Bound image '%s' -> %s", name, path))
end

local function set_images_input_for(shader_key, name, paths)
    local values = paths
    if type(values) == "string" then
        values = vim.split(values, ",", { trimempty = true })
        for index, value in ipairs(values) do
            values[index] = trim(value)
        end
    end

    get_input_store(shader_key)[name] = { kind = "images", values = values }
    notify(string.format("Bound image list '%s' (%d item%s)", name, #values, #values == 1 and "" or "s"))
end

local function set_data_input_value_for(shader_key, name, value)
    get_input_store(shader_key)[name] = { kind = "data", value = value }
    notify(string.format("Bound data '%s'", name))
    return true
end

local function clear_input_for(shader_key, name)
    get_input_store(shader_key)[name] = nil
    notify(string.format("Cleared input '%s'", name))
end

local function open_json_input_editor(spec, context)
    local shader_key = context.shader_key
    local current = input_store_for_spec(spec, shader_key)
    local value = (current and current.kind == "data" and current.value) or default_json_for_spec(spec, context)
    local text = encode_json_pretty(value)

    vim.cmd("belowright split")
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(win, buf)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "json"
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_name(buf, string.format("shaderdebug://input/%s", spec.name))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
    state.input_editors[buf] = {
        spec = spec,
        context = context,
    }

    vim.keymap.set("n", "q", function()
        if vim.bo[buf].modified then
            notify("Input buffer has unsaved changes", vim.log.levels.WARN)
            return
        end
        pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, silent = true, desc = "Close shaderdebug input editor" })

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function(args)
            local session = state.input_editors[args.buf]
            if not session then
                return
            end

            local content = table.concat(vim.api.nvim_buf_get_lines(args.buf, 0, -1, false), "\n")
            local ok, decoded = pcall(vim.json.decode, content)
            if not ok then
                notify("Invalid JSON: " .. decoded, vim.log.levels.ERROR)
                return
            end

            set_data_input_value_for(session.context.shader_key, session.spec.name, decoded)
            vim.bo[args.buf].modified = false
            rerender_context(session.context)
        end,
    })

    notify("Edit JSON and :write to apply")
end

local function prompt_image_input(spec, context)
    local shader_key = context.shader_key
    local current = input_store_for_spec(spec, shader_key)
    local default_value = current and current.values and table.concat(current.values, ",") or ""
    local prompt = spec.is_array and ("Image paths for " .. spec.name .. " (comma-separated): ") or ("Image path for " .. spec.name .. ": ")
    vim.ui.input({ prompt = prompt, default = default_value }, function(input)
        if not input or trim(input) == "" then
            return
        end
        if spec.is_array then
            set_images_input_for(shader_key, spec.name, input)
        else
            set_image_input_for(shader_key, spec.name, trim(input))
        end
        rerender_context(context)
    end)
end

local function prompt_sampler_input(spec, context)
    local shader_key = context.shader_key
    local current = input_store_for_spec(spec, shader_key)
    vim.ui.select({ "linear", "nearest", "clear override" }, {
        prompt = string.format("Sampler mode for %s", spec.name),
        format_item = function(item)
            if item == "clear override" then
                return item
            end
            local marker = current and current.mode == item and " (current)" or ""
            return item .. marker
        end,
    }, function(choice)
        if not choice then
            return
        end
        if choice == "clear override" then
            clear_input_for(shader_key, spec.name)
        else
            get_input_store(shader_key)[spec.name] = { kind = "sampler", mode = choice }
            notify(string.format("Bound sampler '%s' -> %s", spec.name, choice))
        end
        rerender_context(context)
    end)
end

local function edit_input_spec(spec, context)
    local actions = {}
    if spec.kind == "combined_image_sampler" or spec.kind == "sampled_image" then
        actions = {
            { key = "set", label = spec.is_array and "Set image paths" or "Set image path" },
            { key = "clear", label = "Use default" },
        }
    elseif spec.kind == "sampler" then
        actions = {
            { key = "set", label = "Choose sampler mode" },
            { key = "clear", label = "Use default" },
        }
    elseif spec.kind == "uniform_buffer" or spec.kind == "storage_buffer" then
        actions = {
            { key = "edit", label = "Edit JSON in split" },
            { key = "load", label = "Load JSON from file" },
            { key = "clear", label = "Use default" },
        }
    else
        notify("No editor available for " .. spec.kind, vim.log.levels.WARN)
        return
    end

    vim.ui.select(actions, {
        prompt = string.format("Input actions for %s", spec.name),
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        if not choice then
            return
        end

        if choice.key == "clear" then
            clear_input_for(context.shader_key, spec.name)
            rerender_context(context)
            return
        end

        if spec.kind == "combined_image_sampler" or spec.kind == "sampled_image" then
            prompt_image_input(spec, context)
            return
        end

        if spec.kind == "sampler" then
            prompt_sampler_input(spec, context)
            return
        end

        if choice.key == "edit" then
            open_json_input_editor(spec, context)
            return
        end

        if choice.key == "load" then
            vim.ui.input({ prompt = "JSON file path for " .. spec.name .. ": " }, function(input)
                if not input or trim(input) == "" then
                    return
                end
                local value, err = parse_data_argument(input)
                if not value then
                    notify(err, vim.log.levels.ERROR)
                    return
                end
                set_data_input_value_for(context.shader_key, spec.name, value)
                rerender_context(context)
            end)
        end
    end)
end

local function prepare_render_request(opts)
    opts = opts or {}
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "slang" then
        return nil, "Current buffer is not a Slang file"
    end

    if ensure_runner() ~= true then
        return nil, "Renderer build failed"
    end

    local cursor_line = opts.cursor_line or current_cursor_line_for_buffer(bufnr)
    local payload, err = build_instrumented_source(bufnr, cursor_line)
    if not payload then
        return nil, err
    end

    local temp_source, output_png, prefix = write_temp_source(bufnr, payload)
    if not temp_source then
        return nil, output_png
    end

    return {
        opts = opts,
        bufnr = bufnr,
        cursor_line = cursor_line,
        payload = payload,
        temp_source = temp_source,
        output_png = output_png,
        prefix = prefix,
        shader_key = shader_key_for_buffer(bufnr),
    }
end

local function render_current_line(opts)
    local request, request_err = prepare_render_request(opts)
    if not request then
        return nil, request_err
    end

    local opts = request.opts
    local bufnr = request.bufnr
    local cursor_line = request.cursor_line
    local payload = request.payload
    local temp_source = request.temp_source
    local output_png = request.output_png
    local prefix = request.prefix
    local shader_key = request.shader_key

    local fragment_spv, reflection_json_or_err = compile_fragment_spirv(temp_source, prefix, payload.entry)
    if not fragment_spv then
        return nil, "Slang SPIR-V compile failed:\n" .. reflection_json_or_err
    end

    local reflection, reflect_err = parse_reflection(reflection_json_or_err)
    if not reflection then
        return nil, "Failed to parse reflection:\n" .. reflect_err
    end

    local entry = find_entry_reflection(reflection, payload.entry)
    if not entry then
        return nil, "No fragment entry reflection found for " .. payload.entry
    end

    local vertex_glsl, vertex_err = build_vertex_glsl(entry)
    if not vertex_glsl then
        return nil, vertex_err
    end

    local vertex_spv, vertex_spv_err = compile_vertex_spirv(vertex_glsl, prefix)
    if not vertex_spv then
        return nil, "Vertex SPIR-V compile failed:\n" .. vertex_spv_err
    end

    local specs = collect_resource_specs(reflection, entry)
    local context = {
        image_size = config.image_size,
        shader_key = shader_key,
    }
    local manifest_path, prepared_specs_or_err = prepare_manifest(specs, shader_key, prefix, context)
    if not manifest_path then
        return nil, "Failed to prepare inputs:\n" .. prepared_specs_or_err
    end
    local prepared_specs = prepared_specs_or_err

    local api = detect_api(reflection, entry)
    local result = {
        api = api,
        entry = payload.entry,
        expression = payload.expression,
        cursor_line = cursor_line,
        bufnr = bufnr,
        shader_key = shader_key,
        output_png = output_png,
        temp_source = temp_source,
        fragment_spv = fragment_spv,
        vertex_spv = vertex_spv,
        manifest_path = manifest_path,
        resource_specs = prepared_specs,
    }

    if not opts.skip_render then
        local ok, render_err = render_vulkan(vertex_spv, fragment_spv, manifest_path, output_png, payload.entry)
        if not ok then
            return nil, "Vulkan preview render failed:\n" .. render_err
        end
    end

    state.last_result = result
    return result
end

start_preview_job = function(opts, on_complete)
    local request, request_err = prepare_render_request(opts)
    if not request then
        if on_complete then
            on_complete(nil, request_err)
        end
        return nil, request_err
    end

    state.render_request_id = state.render_request_id + 1
    local request_id = state.render_request_id
    stop_active_process()

    local opts_for_job = request.opts or {}

    local function is_current()
        return request_id == state.render_request_id
    end

    local function finish(result, err)
        if not is_current() then
            return
        end

        state.active_process = nil
        if result then
            state.last_result = result
            if not opts_for_job.skip_preview and not opts_for_job.skip_render then
                show_preview(result)
            end
        elseif err and not opts_for_job.silent and not err:match("Cursor line must") then
            notify(err, vim.log.levels.WARN)
        end

        if on_complete then
            on_complete(result, err)
        end
    end

    local function spawn(cmd, err_prefix, next_step)
        if not is_current() then
            return
        end

        state.active_process = system_start(cmd, nil, function(result)
            if not is_current() then
                return
            end

            state.active_process = nil
            if result.code ~= 0 then
                local message = (result.stderr ~= "" and result.stderr) or result.stdout or "unknown error"
                finish(nil, err_prefix .. message)
                return
            end

            next_step(result)
        end)
    end

    local fragment_spec = fragment_compile_spec(request.temp_source, request.prefix, request.payload.entry)
    spawn(fragment_spec.command, "Slang SPIR-V compile failed:\n", function()
        local reflection, reflect_err = parse_reflection(fragment_spec.reflection_json)
        if not reflection then
            finish(nil, "Failed to parse reflection:\n" .. reflect_err)
            return
        end

        local entry = find_entry_reflection(reflection, request.payload.entry)
        if not entry then
            finish(nil, "No fragment entry reflection found for " .. request.payload.entry)
            return
        end

        local vertex_glsl, vertex_err = build_vertex_glsl(entry)
        if not vertex_glsl then
            finish(nil, vertex_err)
            return
        end

        local vertex_spec = vertex_compile_spec(request.prefix)
        local ok, write_err = write_text(vertex_spec.source_path, vertex_glsl)
        if not ok then
            finish(nil, write_err)
            return
        end

        local specs = collect_resource_specs(reflection, entry)
        local context = {
            image_size = config.image_size,
            shader_key = request.shader_key,
        }
        local manifest_path, prepared_specs_or_err = prepare_manifest(specs, request.shader_key, request.prefix, context)
        if not manifest_path then
            finish(nil, "Failed to prepare inputs:\n" .. prepared_specs_or_err)
            return
        end
        local prepared_specs = prepared_specs_or_err

        local result = {
            api = detect_api(reflection, entry),
            entry = request.payload.entry,
            expression = request.payload.expression,
            cursor_line = request.cursor_line,
            bufnr = request.bufnr,
            shader_key = request.shader_key,
            output_png = request.output_png,
            temp_source = request.temp_source,
            fragment_spv = fragment_spec.fragment_spv,
            vertex_spv = vertex_spec.output_path,
            manifest_path = manifest_path,
            resource_specs = prepared_specs,
        }

        if opts_for_job.skip_render then
            finish(result, nil)
            return
        end

        spawn(vertex_spec.command, "Vertex SPIR-V compile failed:\n", function()
            spawn(
                render_command_spec(vertex_spec.output_path, fragment_spec.fragment_spv, manifest_path, request.output_png, request.payload.entry),
                "Vulkan preview render failed:\n",
                function()
                    finish(result, nil)
                end
            )
        end)
    end)

    return true
end

local function load_image_api()
    local ok, image = pcall(require, "image")
    if ok then
        return image
    end

    local ok_lazy, lazy = pcall(require, "lazy")
    if ok_lazy then
        pcall(lazy.load, { plugins = { "image.nvim" } })
    end

    ok, image = pcall(require, "image")
    if ok then
        return image
    end

    return nil
end

local function clear_image()
    if state.image then
        pcall(state.image.clear, state.image)
        state.image = nil
    end
end

local function update_preview_image(image, result, preview_win, preview_buf, width, height)
    local absolute_path = vim.fn.fnamemodify(result.output_png, ":p")
    local image_y = math.max((state.preview_text_line_count or 1) + (config.preview.image_gap_lines or 0) - 1, 0)

    image.window = preview_win
    image.buffer = preview_buf
    image.namespace = "shaderdebug"
    image.inline = true
    image.with_virtual_padding = true
    image.geometry = image.geometry or {}
    image.geometry.x = 0
    image.geometry.y = image_y
    image.geometry.width = width
    image.geometry.height = height
    image.rendered_geometry = { x = nil, y = nil, width = nil, height = nil }
    image.last_modified = -1
    image.resize_hash = nil
    image.cropped_hash = nil

    if image.original_path ~= absolute_path then
        image:clear(true)
        image.original_path = absolute_path
        image.path = absolute_path
        image.cropped_path = absolute_path
        image.resized_path = absolute_path
    end
end

local function ensure_preview_window()
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) and state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) then
        return state.preview_win, state.preview_buf
    end

    local previous_win = vim.api.nvim_get_current_win()
    vim.cmd(config.preview.split_command)
    state.preview_win = vim.api.nvim_get_current_win()
    state.preview_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(state.preview_win, state.preview_buf)

    local target_width = math.max(math.floor(vim.o.columns * config.preview.width_fraction), 30)
    pcall(vim.api.nvim_win_set_width, state.preview_win, target_width)

    vim.bo[state.preview_buf].buftype = "nofile"
    vim.bo[state.preview_buf].bufhidden = "hide"
    vim.bo[state.preview_buf].swapfile = false
    vim.bo[state.preview_buf].modifiable = false
    vim.bo[state.preview_buf].filetype = "shaderdebug"
    vim.api.nvim_buf_set_name(state.preview_buf, config.preview.buffer_name)
    vim.wo[state.preview_win].number = false
    vim.wo[state.preview_win].relativenumber = false
    vim.wo[state.preview_win].cursorline = false
    vim.wo[state.preview_win].signcolumn = "no"
    vim.wo[state.preview_win].foldcolumn = "0"
    vim.wo[state.preview_win].winfixwidth = true

    vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout", "BufDelete" }, {
        buffer = state.preview_buf,
        callback = function()
            disable_auto_preview("Auto preview disabled because preview buffer was closed")
        end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        callback = function(args)
            if tonumber(args.match) == state.preview_win then
                disable_auto_preview("Auto preview disabled because preview window was closed")
            end
        end,
    })

    vim.keymap.set("n", "<CR>", function()
        require("shaderdebug").activate_preview_line()
    end, { buffer = state.preview_buf, silent = true, desc = "Edit shaderdebug input under cursor" })
    vim.keymap.set("n", "x", function()
        require("shaderdebug").clear_preview_line_input()
    end, { buffer = state.preview_buf, silent = true, desc = "Clear shaderdebug input under cursor" })
    vim.keymap.set("n", "r", function()
        require("shaderdebug").refresh_preview_context()
    end, { buffer = state.preview_buf, silent = true, desc = "Refresh shaderdebug preview" })
    vim.keymap.set("n", "<LeftMouse>", function()
        local mouse = vim.fn.getmousepos()
        if mouse.winid == state.preview_win and mouse.line > 0 then
            vim.api.nvim_set_current_win(state.preview_win)
            vim.api.nvim_win_set_cursor(state.preview_win, { mouse.line, math.max((mouse.column or 1) - 1, 0) })
            require("shaderdebug").activate_preview_line()
        end
    end, { buffer = state.preview_buf, silent = true, desc = "Click to edit shaderdebug input" })

    if vim.api.nvim_win_is_valid(previous_win) then
        vim.api.nvim_set_current_win(previous_win)
    end

    return state.preview_win, state.preview_buf
end

local function set_preview_lines(lines, line_kinds, line_meta)
    local _, preview_buf = ensure_preview_window()
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
    vim.bo[preview_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(preview_buf, preview_ns, 0, -1)

    for index, kind in ipairs(line_kinds or {}) do
        local hl = nil
        if kind == "header" then
            hl = "ShaderDebugHeader"
        elseif kind == "input_default" then
            hl = "ShaderDebugInputDefault"
        elseif kind == "input_override" then
            hl = "ShaderDebugInputOverride"
        elseif kind == "detail" then
            hl = "ShaderDebugInputDetail"
        elseif kind == "empty" then
            hl = "ShaderDebugInputEmpty"
        end

        if hl then
            vim.api.nvim_buf_add_highlight(preview_buf, preview_ns, hl, index - 1, 0, -1)
        end

        local meta = line_meta and line_meta[index] or nil
        if meta and meta.name_start and meta.name_end then
            vim.api.nvim_buf_add_highlight(preview_buf, preview_ns, "ShaderDebugInputName", index - 1, meta.name_start, meta.name_end)
        end
    end
end

disable_auto_preview = function(reason)
    if state.timer then
        state.pending_request = nil
        state.timer:stop()
    end

    state.render_request_id = state.render_request_id + 1
    stop_active_process()

    if state.auto_enabled then
        state.auto_enabled = false
        if reason then
            notify(reason)
        end
    end
end

show_preview = function(result)
    local preview_win, preview_buf = ensure_preview_window()
    state.preview_context = result_context(result)
    state.preview_actions = {}
    local lines = {
        string.format("%s > %s", result.entry, result.expression),
        result.api,
    }
    local line_kinds = { "header", "detail" }
    local line_meta = {}

    if #result.resource_specs == 0 then
        lines[#lines + 1] = "- none"
        line_kinds[#line_kinds + 1] = "empty"
    else
        for _, spec in ipairs(result.resource_specs) do
            local line = input_summary_line(spec)
            lines[#lines + 1] = line
            line_kinds[#line_kinds + 1] = spec.source_label == "override" and "input_override" or "input_default"
            local line_index = #lines
            local name_start = line:find(spec.name, 1, true)
            if name_start then
                line_meta[line_index] = {
                    name_start = name_start - 1,
                    name_end = name_start - 1 + #spec.name,
                }
            end
            state.preview_actions[#lines] = { type = "input", spec = spec }
            local detail_lines = input_detail_lines(spec)
            for _, detail_line in ipairs(detail_lines) do
                lines[#lines + 1] = detail_line
                line_kinds[#line_kinds + 1] = "detail"
                state.preview_actions[#lines] = { type = "input", spec = spec }
            end
        end
    end

    state.preview_text_line_count = #lines

    local display_lines = vim.deepcopy(lines)
    for _ = 1, (config.preview.image_gap_lines or 0) do
        display_lines[#display_lines + 1] = ""
    end

    for _ = #line_kinds + 1, #display_lines do
        line_kinds[#line_kinds + 1] = "empty"
    end

    set_preview_lines(display_lines, line_kinds, line_meta)

    clear_image()
    if #vim.api.nvim_list_uis() == 0 then
        return
    end

    local image_api = load_image_api()
    if not image_api then
        return
    end

    local width = math.max(vim.api.nvim_win_get_width(preview_win) - 2, 12)
    local height = math.max(vim.api.nvim_win_get_height(preview_win) - state.preview_text_line_count - (config.preview.image_gap_lines or 0), 12)

    if not state.image then
        state.image = image_api.from_file(result.output_png, {
            id = "shaderdebug-preview",
            namespace = "shaderdebug",
            window = preview_win,
            buffer = preview_buf,
            inline = true,
            with_virtual_padding = true,
            x = 0,
            y = math.max(state.preview_text_line_count + (config.preview.image_gap_lines or 0) - 1, 0),
            width = width,
            height = height,
        })
    end

    if state.image then
        update_preview_image(state.image, result, preview_win, preview_buf, width, height)
        state.image:render()
    end
end

local function schedule_preview(bufnr, cursor_line)
    if not state.auto_enabled then
        return
    end

    if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "slang" then
        return
    end

    local request = {
        bufnr = bufnr,
        cursor_line = cursor_line or current_cursor_line_for_buffer(bufnr),
        changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    }
    state.pending_request = request

    if not state.timer then
        state.timer = uv.new_timer()
    end

    state.timer:stop()
    state.timer:start(config.debounce_ms, 0, vim.schedule_wrap(function()
        if state.pending_request ~= request then
            return
        end
        if not vim.api.nvim_buf_is_valid(request.bufnr) or vim.bo[request.bufnr].filetype ~= "slang" then
            return
        end

        start_preview_job({ bufnr = request.bufnr, cursor_line = request.cursor_line, silent = true }, function(_, err)
            if err and not err:match("Cursor line must") then
                notify(err, vim.log.levels.WARN)
            end
        end)
    end))
end

function M.preview_current_line(opts)
    opts = opts or {}
    if opts.sync or opts.skip_render then
        local result, err = render_current_line(opts)
        if not result then
            if not opts.silent then
                notify(err, vim.log.levels.WARN)
            end
            return nil, err
        end

        if not opts.skip_preview and not opts.skip_render then
            show_preview(result)
        end

        return result
    end

    local started, err = start_preview_job(opts)
    if not started then
        if not opts.silent then
            notify(err, vim.log.levels.WARN)
        end
        return nil, err
    end

    return true
end

function M.show_inputs()
    local result, err = render_current_line({ skip_render = true, sync = true })
    if not result then
        notify(err, vim.log.levels.WARN)
        return nil, err
    end

    local lines = {
        string.format("API: %s", result.api),
        string.format("Expression: %s", result.expression),
        "Inputs:",
    }
    if #result.resource_specs == 0 then
        lines[#lines + 1] = "- none"
    else
        for _, spec in ipairs(result.resource_specs) do
            lines[#lines + 1] = input_summary_line(spec)
        end
    end
    notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    return result
end

function M.set_image_input(name, path)
    local shader_key = shader_key_for_buffer(vim.api.nvim_get_current_buf())
    set_image_input_for(shader_key, name, path)
end

function M.set_images_input(name, paths)
    local shader_key = shader_key_for_buffer(vim.api.nvim_get_current_buf())
    set_images_input_for(shader_key, name, paths)
end

function M.set_data_input(name, argument)
    local value, err = parse_data_argument(argument)
    if not value then
        notify(err, vim.log.levels.ERROR)
        return nil, err
    end
    local shader_key = shader_key_for_buffer(vim.api.nvim_get_current_buf())
    return set_data_input_value_for(shader_key, name, value)
end

function M.clear_input(name)
    local shader_key = shader_key_for_buffer(vim.api.nvim_get_current_buf())
    clear_input_for(shader_key, name)
end

function M.refresh_preview_context()
    if not state.preview_context then
        notify("No preview context available", vim.log.levels.WARN)
        return nil
    end
    local started, err = rerender_context(state.preview_context)
    if not started then
        notify(err, vim.log.levels.WARN)
        return nil, err
    end
    return true
end

function M.activate_preview_line()
    if not state.preview_buf or vim.api.nvim_get_current_buf() ~= state.preview_buf then
        return
    end

    local line = vim.api.nvim_win_get_cursor(0)[1]
    local action = state.preview_actions[line]
    if not action or action.type ~= "input" then
        return
    end

    local context = state.preview_context or (state.last_result and result_context(state.last_result))
    if not context then
        notify("No preview context available", vim.log.levels.WARN)
        return
    end

    edit_input_spec(action.spec, context)
end

function M.clear_preview_line_input()
    if not state.preview_buf or vim.api.nvim_get_current_buf() ~= state.preview_buf then
        return
    end

    local line = vim.api.nvim_win_get_cursor(0)[1]
    local action = state.preview_actions[line]
    if not action or action.type ~= "input" then
        return
    end

    local context = state.preview_context or (state.last_result and result_context(state.last_result))
    if not context then
        notify("No preview context available", vim.log.levels.WARN)
        return
    end

    clear_input_for(context.shader_key, action.spec.name)
    rerender_context(context)
end

function M.toggle_auto_preview()
    state.auto_enabled = not state.auto_enabled
    notify("Auto preview " .. (state.auto_enabled and "enabled" or "disabled"))
    if state.auto_enabled and vim.bo.filetype == "slang" then
        schedule_preview(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1])
    else
        disable_auto_preview()
    end
end

function M.clear_preview()
    disable_auto_preview()
    clear_image()
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
        pcall(vim.api.nvim_win_close, state.preview_win, true)
    end
    state.preview_win = nil
    state.preview_buf = nil
end

function M.open_test_shader()
    local path = "/tmp/shaderdebug_test.slang"
    local lines = {
        "Texture2D<float4> scene_color;",
        "SamplerState scene_sampler;",
        "StructuredBuffer<float4> debug_points;",
        "struct Globals {",
        "    float4 tint;",
        "    float time;",
        "    float _padding0;",
        "    float2 resolution;",
        "};",
        "ConstantBuffer<Globals> globals;",
        "",
        "struct FragmentInput {",
        "    float4 position : SV_Position;",
        "    float2 uv : TEXCOORD0;",
        "    float3 world_pos : TEXCOORD1;",
        "};",
        "",
        "[shader(\"fragment\")]",
        "float4 fsMain(FragmentInput input) : SV_Target",
        "{",
        "    float2 uv = input.uv;",
        "    float wave = 0.5 + 0.5 * sin(globals.time + input.world_pos.x * 6.0);",
        "    float3 baseColor = float3(uv.x, uv.y, wave);",
        "    float4 sampled = scene_color.Sample(scene_sampler, uv);",
        "    float3 finalColor = lerp(baseColor * globals.tint.xyz, sampled.xyz, globals.tint.w);",
        "    return float4(finalColor, 1.0);",
        "}",
    }

    vim.fn.writefile(lines, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.bo.filetype = "slang"
    notify("Wrote test shader to " .. path)
end

function M.get_last_result()
    return state.last_result
end

function M.setup(user_config)
    config = vim.tbl_deep_extend("force", default_config, user_config or {})
    state.auto_enabled = config.auto_preview
    setup_preview_highlights()

    state.augroup = vim.api.nvim_create_augroup("ShaderDebugPreview", { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMoved", "TextChanged", "TextChangedI", "BufEnter" }, {
        group = state.augroup,
        callback = function(args)
            if vim.bo[args.buf].filetype == "slang" then
                schedule_preview(args.buf, vim.api.nvim_win_get_cursor(0)[1])
            end
        end,
    })

    vim.api.nvim_create_user_command("ShaderDebugPreview", function()
        M.preview_current_line()
    end, { desc = "Render shader output for the current Slang line" })

    vim.api.nvim_create_user_command("ShaderDebugToggleAuto", function()
        M.toggle_auto_preview()
    end, { desc = "Toggle automatic shader debug preview" })

    vim.api.nvim_create_user_command("ShaderDebugInputs", function()
        M.show_inputs()
    end, { desc = "Show reflected inputs for the current debug expression" })

    vim.api.nvim_create_user_command("ShaderDebugSetImage", function(opts)
        if #opts.fargs < 2 then
            notify("Usage: ShaderDebugSetImage <name> <path>", vim.log.levels.ERROR)
            return
        end
        M.set_image_input(opts.fargs[1], opts.fargs[2])
    end, { nargs = "+", desc = "Bind a single image input by reflected name" })

    vim.api.nvim_create_user_command("ShaderDebugSetImages", function(opts)
        if #opts.fargs < 2 then
            notify("Usage: ShaderDebugSetImages <name> <path1,path2,...>", vim.log.levels.ERROR)
            return
        end
        M.set_images_input(opts.fargs[1], table.concat(vim.list_slice(opts.fargs, 2), " "))
    end, { nargs = "+", desc = "Bind an image array input by reflected name" })

    vim.api.nvim_create_user_command("ShaderDebugSetData", function(opts)
        if #opts.fargs < 2 then
            notify("Usage: ShaderDebugSetData <name> <json|@file>", vim.log.levels.ERROR)
            return
        end
        M.set_data_input(opts.fargs[1], table.concat(vim.list_slice(opts.fargs, 2), " "))
    end, { nargs = "+", desc = "Bind JSON data for a uniform/storage buffer input" })

    vim.api.nvim_create_user_command("ShaderDebugClearInput", function(opts)
        if #opts.fargs ~= 1 then
            notify("Usage: ShaderDebugClearInput <name>", vim.log.levels.ERROR)
            return
        end
        M.clear_input(opts.fargs[1])
    end, { nargs = 1, desc = "Clear a reflected input override" })

    vim.api.nvim_create_user_command("ShaderDebugOpenTestShader", function()
        M.open_test_shader()
    end, { desc = "Create and open a test shader in /tmp" })

    vim.api.nvim_create_user_command("ShaderDebugClear", function()
        M.clear_preview()
    end, { desc = "Clear shader debug preview" })
end

return M

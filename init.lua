local uv = vim.uv

local M = {}

local default_config = {
    auto_preview = false,
    debounce_ms = 180,
    image_size = 512,
    preview = {
        buffer_name = "ShaderDebug Preview",
        split_command = "rightbelow vsplit",
        width_fraction = 0.35,
        top_padding_lines = 6,
    },
    cache_dir = vim.fn.stdpath("cache") .. "/shaderdebug",
    runner_source = vim.fn.stdpath("config") .. "/lua/shaderdebug/renderer.c",
    runner_binary = vim.fn.stdpath("cache") .. "/shaderdebug/shaderdebug_renderer",
    slangc = vim.fn.exepath("slangc") ~= "" and vim.fn.exepath("slangc") or "slangc",
    glsl_profile = "glsl_460",
}

local config = vim.deepcopy(default_config)

local state = {
    auto_enabled = false,
    timer = nil,
    pending_request = nil,
    preview_buf = nil,
    preview_win = nil,
    image = nil,
    augroup = nil,
    last_result = nil,
}

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

local function ensure_cache_dir()
    vim.fn.mkdir(config.cache_dir, "p")
end

local function system_wait(cmd, opts)
    local result = vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait()
    return result
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
        'cc "%s" -O2 -std=c11 -o "%s" $(pkg-config --cflags --libs egl epoxy libpng)',
        source,
        binary
    )

    local result = system_wait({ "bash", "-lc", command })
    if result.code ~= 0 then
        notify("Failed to build shaderdebug renderer:\n" .. (result.stderr or result.stdout or "unknown error"), vim.log.levels.ERROR)
        return false
    end

    return true
end

local function read_lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
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
    local temp_source = string.format("%s/%s-line-%d.debug.slang", config.cache_dir, stem, payload.cursor_line)
    local temp_glsl = string.format("%s/%s-line-%d.debug.frag.glsl", config.cache_dir, stem, payload.cursor_line)
    local output_png = string.format("%s/%s-line-%d.debug.png", config.cache_dir, stem, payload.cursor_line)

    vim.fn.writefile(vim.split(payload.source, "\n", { plain = true }), temp_source)

    return temp_source, temp_glsl, output_png
end

local function compile_fragment(temp_source, temp_glsl, entry)
    local result = system_wait({
        config.slangc,
        "-target",
        "glsl",
        "-profile",
        config.glsl_profile,
        "-entry",
        entry,
        "-stage",
        "fragment",
        temp_source,
        "-o",
        temp_glsl,
    })

    if result.code ~= 0 then
        return nil, (result.stderr ~= "" and result.stderr) or result.stdout
    end

    return true
end

local function render_glsl(temp_glsl, output_png)
    local result = system_wait({
        config.runner_binary,
        "--fragment",
        temp_glsl,
        "--output",
        output_png,
        "--size",
        tostring(config.image_size),
    })

    if result.code ~= 0 then
        return nil, (result.stderr ~= "" and result.stderr) or result.stdout
    end

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

local function update_preview_image(image, result, preview_win, preview_buf, width, height)
    local absolute_path = vim.fn.fnamemodify(result.output_png, ":p")

    image.window = preview_win
    image.buffer = preview_buf
    image.namespace = "shaderdebug"
    image.inline = true
    image.with_virtual_padding = true
    image.geometry = image.geometry or {}
    image.geometry.x = 0
    image.geometry.y = config.preview.top_padding_lines - 1
    image.geometry.width = width
    image.geometry.height = height
    image.rendered_geometry = {
        x = nil,
        y = nil,
        width = nil,
        height = nil,
    }
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

    if vim.api.nvim_win_is_valid(previous_win) then
        vim.api.nvim_set_current_win(previous_win)
    end

    return state.preview_win, state.preview_buf
end

local function set_preview_lines(lines)
    local _, preview_buf = ensure_preview_window()
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
    vim.bo[preview_buf].modifiable = false
end

local function show_preview(result)
    local preview_win, preview_buf = ensure_preview_window()

    set_preview_lines({
        "ShaderDebug",
        "",
        "Expression: " .. result.expression,
        "Entry: " .. result.entry,
        "PNG: " .. result.output_png,
        "",
    })

    clear_image()

    if #vim.api.nvim_list_uis() == 0 then
        return
    end

    local image_api = load_image_api()
    if not image_api then
        return
    end

    local width = math.max(vim.api.nvim_win_get_width(preview_win) - 2, 12)
    local height = math.max(vim.api.nvim_win_get_height(preview_win) - config.preview.top_padding_lines, 12)

    if not state.image then
        state.image = image_api.from_file(result.output_png, {
            id = "shaderdebug-preview",
            namespace = "shaderdebug",
            window = preview_win,
            buffer = preview_buf,
            inline = true,
            with_virtual_padding = true,
            x = 0,
            y = config.preview.top_padding_lines - 1,
            width = width,
            height = height,
        })
    end

    if state.image then
        update_preview_image(state.image, result, preview_win, preview_buf, width, height)
        state.image:render()
    end
end

local function render_current_line(opts)
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

    local temp_source, temp_glsl, output_png = write_temp_source(bufnr, payload)

    local ok, compile_err = compile_fragment(temp_source, temp_glsl, payload.entry)
    if not ok then
        return nil, "Slang compile failed:\n" .. compile_err
    end

    local rendered, render_err = render_glsl(temp_glsl, output_png)
    if not rendered then
        return nil, "Preview render failed:\n" .. render_err
    end

    local result = {
        expression = payload.expression,
        entry = payload.entry,
        temp_source = temp_source,
        temp_glsl = temp_glsl,
        output_png = output_png,
        cursor_line = cursor_line,
    }

    state.last_result = result
    return result
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

        local result, err = render_current_line({ bufnr = request.bufnr, cursor_line = request.cursor_line })
        if result then
            show_preview(result)
        elseif err and not err:match("Cursor line must") then
            notify(err, vim.log.levels.WARN)
        end
    end))
end

function M.preview_current_line(opts)
    local result, err = render_current_line(opts)
    if not result then
        if not (opts and opts.silent) then
            notify(err, vim.log.levels.WARN)
        end
        return nil, err
    end

    if not (opts and opts.skip_preview) then
        show_preview(result)
    end

    return result
end

function M.toggle_auto_preview()
    state.auto_enabled = not state.auto_enabled
    notify("Auto preview " .. (state.auto_enabled and "enabled" or "disabled"))

    if state.auto_enabled and vim.bo.filetype == "slang" then
        schedule_preview(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1])
    elseif state.timer then
        state.pending_request = nil
        state.timer:stop()
    end
end

function M.clear_preview()
    state.pending_request = nil

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
        "struct FragmentInput {",
        "    float4 position : SV_Position;",
        "    float2 uv : TEXCOORD0;",
        "};",
        "",
        "[shader(\"fragment\")]",
        "float4 fsMain(FragmentInput input) : SV_Target",
        "{",
        "    float2 uv = input.uv;",
        "    float2 centered = uv - float2(0.5, 0.5);",
        "    float radius = length(centered * 2.0);",
        "    float wave = 0.5 + 0.5 * sin(uv.x * 18.0 + uv.y * 12.0);",
        "    float ringMask = smoothstep(0.85, 0.80, radius) - smoothstep(0.62, 0.57, radius);",
        "    float3 baseColor = float3(uv.x, uv.y, wave);",
        "    float3 finalColor = lerp(baseColor, float3(1.0, 0.7, 0.2), ringMask);",
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

    vim.api.nvim_create_user_command("ShaderDebugOpenTestShader", function()
        M.open_test_shader()
    end, { desc = "Create and open a test shader in /tmp" })

    vim.api.nvim_create_user_command("ShaderDebugClear", function()
        M.clear_preview()
    end, { desc = "Clear shader debug preview" })
end

return M

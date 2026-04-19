local context = require("shaderdebug.src.context")
local input_store = require("shaderdebug.src.input_store")

local M = {}

local on_preview_closed = function() end

function M.setup(opts)
    on_preview_closed = opts and opts.on_preview_closed or on_preview_closed
end

function M.result_context(result)
    return {
        bufnr = result.bufnr,
        cursor_line = result.cursor_line,
        shader_key = result.shader_key,
    }
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

function M.clear_image()
    local state = context.get_state()
    if state.image then
        pcall(state.image.clear, state.image)
        state.image = nil
    end
end

local function update_preview_image(image, result, preview_win, preview_buf, width, height)
    local state = context.get_state()
    local config = context.get_config()
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

function M.ensure_preview_window()
    local state = context.get_state()
    local config = context.get_config()

    if state.preview_win
        and vim.api.nvim_win_is_valid(state.preview_win)
        and state.preview_buf
        and vim.api.nvim_buf_is_valid(state.preview_buf)
    then
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
        once = true,
        callback = function()
            on_preview_closed("Auto preview disabled because preview buffer was closed")
        end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(state.preview_win),
        once = true,
        callback = function()
            on_preview_closed("Auto preview disabled because preview window was closed")
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
    local _, preview_buf = M.ensure_preview_window()
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
    vim.bo[preview_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(preview_buf, context.get_preview_ns(), 0, -1)

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
            vim.api.nvim_buf_add_highlight(preview_buf, context.get_preview_ns(), hl, index - 1, 0, -1)
        end

        local meta = line_meta and line_meta[index] or nil
        if meta and meta.name_start and meta.name_end then
            vim.api.nvim_buf_add_highlight(preview_buf, context.get_preview_ns(), "ShaderDebugInputName", index - 1, meta.name_start, meta.name_end)
        end
    end
end

function M.show_preview(result)
    local preview_win, preview_buf = M.ensure_preview_window()
    local state = context.get_state()
    local config = context.get_config()

    state.preview_context = M.result_context(result)
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
            local line = input_store.input_summary_line(spec)
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
            for _, detail_line in ipairs(input_store.input_detail_lines(spec)) do
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

    M.clear_image()
    if #vim.api.nvim_list_uis() == 0 then
        return
    end

    local image_api = load_image_api()
    if not image_api then
        return
    end

    local width = math.max(vim.api.nvim_win_get_width(preview_win) - 2, 12)
    local bottom_padding = config.preview.bottom_padding_lines or 0
    local height = math.max(
        vim.api.nvim_win_get_height(preview_win)
            - state.preview_text_line_count
            - (config.preview.image_gap_lines or 0)
            - bottom_padding,
        12
    )

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

function M.close()
    local state = context.get_state()
    M.clear_image()
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
        pcall(vim.api.nvim_win_close, state.preview_win, true)
    end
    if state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) then
        pcall(vim.api.nvim_buf_delete, state.preview_buf, { force = true })
    end
    state.preview_win = nil
    state.preview_buf = nil
    state.preview_context = nil
    state.preview_actions = {}
    state.preview_text_line_count = 0
end

return M

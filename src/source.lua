local context = require("shaderdebug.src.context")
local util = require("shaderdebug.src.util")

local M = {}

local function current_line_expression(line)
    local return_expr = line:match("^%s*return%s+(.+);%s*$")
    if return_expr then
        return util.trim(return_expr)
    end

    if line:find("==", 1, true) or line:find("!=", 1, true) or line:find("<=", 1, true) or line:find(">=", 1, true) then
        return nil
    end

    local _, operator, rhs = line:match("^%s*(.-)%s*([%+%-%*/%%]?=)%s*(.+);%s*$")
    if rhs and operator == "=" then
        return util.trim(rhs)
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

function M.build_instrumented_source(bufnr, cursor_line)
    local lines = util.read_lines(bufnr)
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
    new_lines[cursor_line] = indent .. "return shaderdebug_toColor(" .. expression .. ");"

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

    table.insert(new_lines, context.get_debug_helpers())

    return {
        source = table.concat(new_lines, "\n") .. "\n",
        entry = entry,
        expression = expression,
        cursor_line = cursor_line,
    }
end

function M.write_temp_source(bufnr, payload)
    util.ensure_cache_dir()

    local source_name = vim.api.nvim_buf_get_name(bufnr)
    local stem = vim.fn.fnamemodify(source_name ~= "" and source_name or "shader", ":t:r")
    local prefix = string.format(
        "%s/%s-line-%d.debug",
        context.get_config().cache_dir,
        util.sanitize_name(stem),
        payload.cursor_line
    )

    local temp_source = prefix .. ".slang"
    local output_png = prefix .. ".png"
    local ok, err = util.write_text(temp_source, payload.source)
    if not ok then
        return nil, err
    end

    return temp_source, output_png, prefix
end

return M

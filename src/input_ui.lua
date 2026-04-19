local context = require("shaderdebug.src.context")
local input_store = require("shaderdebug.src.input_store")
local util = require("shaderdebug.src.util")

local M = {}

local rerender_context = function()
    return nil, "No rerender callback configured"
end

function M.setup(opts)
    rerender_context = opts and opts.rerender_context or rerender_context
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

    if input_store.table_is_array(value) then
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

local function open_json_input_editor(spec, preview_context)
    local shader_key = preview_context.shader_key
    local current = input_store.input_store_for_spec(spec, shader_key)
    local value = (current and current.kind == "data" and current.value) or input_store.default_json_for_spec(spec)
    local text = encode_json_pretty(value)
    local state = context.get_state()

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
        preview_context = preview_context,
    }

    vim.keymap.set("n", "q", function()
        if vim.bo[buf].modified then
            util.notify("Input buffer has unsaved changes", vim.log.levels.WARN)
            return
        end
        pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, silent = true, desc = "Close shaderdebug input editor" })

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function(args)
            local session = context.get_state().input_editors[args.buf]
            if not session then
                return
            end

            local content = table.concat(vim.api.nvim_buf_get_lines(args.buf, 0, -1, false), "\n")
            local ok, decoded = pcall(vim.json.decode, content)
            if not ok then
                util.notify("Invalid JSON: " .. decoded, vim.log.levels.ERROR)
                return
            end

            input_store.set_data_input_value_for(session.preview_context.shader_key, session.spec.name, decoded)
            vim.bo[args.buf].modified = false
            rerender_context(session.preview_context)
        end,
    })

    util.notify("Edit JSON and :write to apply")
end

local function prompt_image_input(spec, preview_context)
    local shader_key = preview_context.shader_key
    local current = input_store.input_store_for_spec(spec, shader_key)
    local default_value = current and current.values and table.concat(current.values, ",") or ""
    local prompt = spec.is_array and ("Image paths for " .. spec.name .. " (comma-separated): ")
        or ("Image path for " .. spec.name .. ": ")

    vim.ui.input({ prompt = prompt, default = default_value }, function(input)
        if not input or util.trim(input) == "" then
            return
        end
        if spec.is_array then
            input_store.set_images_input_for(shader_key, spec.name, input)
        else
            input_store.set_image_input_for(shader_key, spec.name, util.trim(input))
        end
        rerender_context(preview_context)
    end)
end

local function prompt_sampler_input(spec, preview_context)
    local shader_key = preview_context.shader_key
    local current = input_store.input_store_for_spec(spec, shader_key)

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
            input_store.clear_input_for(shader_key, spec.name)
        else
            input_store.get_input_store(shader_key)[spec.name] = { kind = "sampler", mode = choice }
            util.notify(string.format("Bound sampler '%s' -> %s", spec.name, choice))
        end
        rerender_context(preview_context)
    end)
end

function M.edit_input_spec(spec, preview_context)
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
        util.notify("No editor available for " .. spec.kind, vim.log.levels.WARN)
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
            input_store.clear_input_for(preview_context.shader_key, spec.name)
            rerender_context(preview_context)
            return
        end

        if spec.kind == "combined_image_sampler" or spec.kind == "sampled_image" then
            prompt_image_input(spec, preview_context)
            return
        end

        if spec.kind == "sampler" then
            prompt_sampler_input(spec, preview_context)
            return
        end

        if choice.key == "edit" then
            open_json_input_editor(spec, preview_context)
            return
        end

        if choice.key == "load" then
            vim.ui.input({ prompt = "JSON file path for " .. spec.name .. ": " }, function(input)
                if not input or util.trim(input) == "" then
                    return
                end
                local value, err = input_store.parse_data_argument(input)
                if not value then
                    util.notify(err, vim.log.levels.ERROR)
                    return
                end
                input_store.set_data_input_value_for(preview_context.shader_key, spec.name, value)
                rerender_context(preview_context)
            end)
        end
    end)
end

return M

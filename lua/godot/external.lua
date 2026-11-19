local M = {}
function M.configure(root, callback)
  local entry = vim.api.nvim_get_runtime_file("scripts/godot-nvim-open.lua", false)[1]
  assert(entry, "godot.nvim launcher is missing")
  local state_dir = vim.fs.normalize(require("godot.config").options.state_dir)
  local flags = ('--headless -u NONE -i NONE -l "%s" "%s" "{file}" {line} {col}'):format(
    vim.fs.normalize(entry), state_dir)
  require("godot.bridge").call(root, "configure_external", {
    executable = vim.v.progpath, flags = flags,
  }, function(err)
    if callback then return callback(err) end
    vim.notify(err or "Godot now opens scripts in the project's Neovim session.",
      err and vim.log.levels.ERROR or vim.log.levels.INFO)
  end)
end

function M.open_file(file, line, column)
  local path = vim.fs.normalize(file)
  assert(vim.fn.filereadable(path) == 1, "File does not exist: " .. path)
  vim.cmd("keepalt drop " .. vim.fn.fnameescape(path))
  local row = math.max(1, math.min(tonumber(line) or 1, vim.api.nvim_buf_line_count(0)))
  local text = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
  local col = vim.str_byteindex(text, "utf-32", math.max(0, (tonumber(column) or 1) - 1), false)
  vim.api.nvim_win_set_cursor(0, { row, col })
  pcall(vim.cmd, "normal! zv")
  -- The UI process owns the terminal. A headless server can also receive
  -- file callbacks, in which case there is no desktop window to activate.
  if vim.fn.has("win32") == 1 then
    for _, ui in ipairs(vim.api.nvim_list_uis()) do
      local client = vim.api.nvim_get_chan_info(ui.chan).client or {}
      if client.name == "nvim-tui" and client.attributes and type(client.attributes.pid) == "number" then
        return { tui_pid = client.attributes.pid }
      end
    end
  end
  return true
end
return M


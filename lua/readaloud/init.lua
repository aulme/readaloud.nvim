-- Reading mode: reads a plain text or markdown buffer aloud with Kokoro,
-- highlighting the line and the word being read and keeping the cursor on it
-- in the middle of the window. Code blocks and tables are skipped. speak.py
-- next to this file does the speaking, see the protocol there.
local M = {}

-- `pause` is the longest silence within a paragraph, eg between sentences,
-- and `paragraph_pause` the silence between paragraphs, in seconds. `keymap`,
-- when set, is a normal mode key that starts reading.
M.config = { voice = "af_heart", speed = 1.0, pause = 0.3, paragraph_pause = 0.3, keymap = nil }

local ns = vim.api.nvim_create_namespace("readaloud")
local helper_path = debug.getinfo(1, "S").source:sub(2):gsub("init%.lua$", "speak.py")

-- The word in the background colour on the colour scheme's colour for
-- functions, in bold, so it stands out from any syntax colour.
-- ReadAloudCursor hides the cursor while reading, as its block covers
-- the word's first letter.
local function highlights()
  local accent = vim.api.nvim_get_hl(0, { name = "Function", link = false }).fg
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
  vim.api.nvim_set_hl(0, "ReadAloudWord", { fg = normal, bg = accent, bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReadAloudLine", { link = "CursorLine", default = true })
  vim.api.nvim_set_hl(0, "ReadAloudCursor", { blend = 100, nocombine = true })
end
highlights()
local group = vim.api.nvim_create_augroup("readaloud", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })

-- The helper, kept running between reads, as loading Kokoro takes seconds.
local job
-- The read in progress: its buffer and window, the paragraphs sent, and what
-- the mode changed, to put back on exit.
local session
local gen = 0

-- Splits markdown into paragraphs of plain words, without markup, code blocks
-- or tables. Each paragraph has its `text` and `pos`, the buffer position
-- {line, col} of each byte of the text, or false for a joining space.
local function paragraphs(buf)
  local markdown = vim.bo[buf].filetype == "markdown"
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local result, current = {}, nil
  local function finish()
    if current and current.text:find("%w") then result[#result + 1] = current end
    current = nil
  end
  local fence, frontmatter = nil, markdown and lines[1] == "---"
  for lnum, line in ipairs(lines) do
    local skip = false
    if frontmatter then
      skip = true
      if lnum > 1 and line == "---" then frontmatter = false end
    elseif markdown then
      local marker = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
      if fence then
        skip = true
        if marker and marker:sub(1, 1) == fence:sub(1, 1) and #marker >= #fence then fence = nil end
      elseif marker then
        fence, skip = marker, true
      else
        skip = line:match("^%s*|") or line:match("^%s*%[[^%]]+%]:%s") or line:match("^%s*<!%-%-")
          or line:match("^%s*[-*_][-*_%s]*$") and #line:gsub("%s", "") >= 3
      end
    end
    if skip or not line:find("%S") then
      finish()
    else
      local drop, start, own = {}, 1, false
      if markdown then
        -- Block markup at the start: quotes, a heading or a list marker. A
        -- heading or a list item starts a paragraph of its own.
        local s = line:match("^%s*()")
        while line:sub(s, s) == ">" do s = line:match("^>%s*()", s) end
        local after = line:match("^#+%s+()", s)
        if after then
          own = "heading"
        else
          after = line:match("^[-*+]%s+()", s) or line:match("^%d+[.)]%s+()", s)
          if after then
            own = "item"
            after = line:match("^%[[ xX]%]%s+()", after) or after
          end
        end
        start = after or s
        -- Links and images keep their text and lose the target.
        for open, close, stop in line:gmatch("()!?%[[^%]]*%]()%b()()") do
          for i = open, (line:find("%[", open)) do drop[i] = true end
          for i = close - 1, stop - 1 do drop[i] = true end
        end
        for open, close, stop in line:gmatch("()%[[^%]]*%]()%[[^%]]*%]()") do
          drop[open] = true
          for i = close - 1, stop - 1 do drop[i] = true end
        end
        for i = 1, #line do
          local c = line:sub(i, i)
          if c == "`" or c == "*" or c == "~" then
            drop[i] = true
          elseif c == "_" and not (line:sub(i - 1, i - 1):match("%w") and line:sub(i + 1, i + 1):match("%w")) then
            drop[i] = true
          end
        end
      end
      if own or current and current.heading then finish() end
      if not current then
        current = { text = "", pos = {}, heading = own == "heading" }
      else
        current.text = current.text .. " "
        current.pos[#current.pos + 1] = false
      end
      for i = start, #line do
        if not drop[i] then
          current.text = current.text .. line:sub(i, i)
          current.pos[#current.pos + 1] = { lnum, i - 1 }
        end
      end
    end
  end
  finish()
  return result
end

local function before(a, b) return a[1] < b[1] or a[1] == b[1] and a[2] < b[2] end

-- The paragraphs from the word at or after a buffer position onwards. The
-- first starts at that word, and `base` keeps its offset into the paragraph.
local function from_position(buf, at)
  local result = {}
  for _, para in ipairs(paragraphs(buf)) do
    if #result > 0 then
      para.base = 0
      result[#result + 1] = para
    else
      for i, pos in ipairs(para.pos) do
        if pos and not before(pos, at) then
          while i > 1 and para.text:sub(i - 1, i - 1):match("%S") do i = i - 1 end
          para.base = i - 1
          result[1] = para
          break
        end
      end
    end
  end
  return result
end

local function set_winbar(text)
  if session and vim.api.nvim_win_is_valid(session.win) then
    vim.wo[session.win].winbar = "%#ReadAloudWord# " .. text .. " %* Space pause · { } paragraph · Enter or click read from there · q quit"
  end
end

local function show(event)
  local para = session.paras[event.para + 1]
  if not para then return end
  local first, last = para.pos[para.base + event.s + 1], para.pos[para.base + event.e]
  if not first then return end
  local buf, win = session.buf, session.win
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  -- A range rather than line_hl_group, whose background covers the word's
  -- whatever the priorities.
  vim.api.nvim_buf_set_extmark(buf, ns, first[1] - 1, 0, { end_row = first[1], hl_group = "ReadAloudLine", hl_eol = true, priority = 100 })
  local end_col = last and last[1] == first[1] and last[2] + 1 or #vim.api.nvim_buf_get_lines(buf, first[1] - 1, first[1], false)[1]
  vim.api.nvim_buf_set_extmark(buf, ns, first[1] - 1, first[2], { end_col = end_col, hl_group = "ReadAloudWord", priority = 5000 })
  if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_set_cursor(win, first) end
end

local function on_event(event)
  if event.ready then
    if session and not session.started then set_winbar("loading the voice") end
    return
  end
  if not session or event.gen ~= gen then return end
  if event.done then
    vim.api.nvim_buf_clear_namespace(session.buf, ns, 0, -1)
    session.paused = true
    set_winbar("■ finished")
  else
    if not session.started then
      session.started = true
      set_winbar("▶ reading")
    end
    show(event)
  end
end

local function send(command)
  if job then vim.fn.chansend(job, vim.json.encode(command) .. "\n") end
end

local function start_helper()
  if job then return true end
  if vim.fn.executable("uv") == 0 then
    vim.notify("Reading aloud needs uv", vim.log.levels.ERROR)
    return false
  end
  local partial, errors = "", {}
  job = vim.fn.jobstart({ "uv", "run", "--quiet", "--script", helper_path }, {
    on_stdout = function(_, data)
      data[1] = partial .. data[1]
      partial = table.remove(data)
      for _, line in ipairs(data) do
        local ok, event = pcall(vim.json.decode, line)
        if ok then on_event(event) end
      end
    end,
    on_stderr = function(_, data) vim.list_extend(errors, data) end,
    on_exit = function(_, code)
      job = nil
      if code ~= 0 and code ~= 143 then
        vim.notify("The reading helper stopped:\n" .. table.concat(vim.list_slice(errors, math.max(1, #errors - 15)), "\n"), vim.log.levels.ERROR)
      end
    end,
  })
  if job <= 0 then job = nil end
  return job ~= nil
end

-- Reads from the word at or after the cursor.
function M.from_cursor()
  if not session then return end
  local paras = from_position(session.buf, vim.api.nvim_win_get_cursor(session.win))
  if #paras == 0 then return vim.notify("Nothing to read after the cursor", vim.log.levels.INFO) end
  gen = gen + 1
  session.paras, session.paused = paras, false
  local texts = vim.tbl_map(function(p) return p.text:sub(p.base + 1) end, paras)
  send({
    cmd = "read", gen = gen, voice = M.config.voice, speed = M.config.speed,
    pause = M.config.pause, paragraph_pause = M.config.paragraph_pause, paras = texts,
  })
  set_winbar(session.started and "▶ reading" or "loading the voice")
end

function M.toggle_pause()
  if not session then return end
  session.paused = not session.paused
  send({ cmd = session.paused and "pause" or "resume" })
  set_winbar(session.paused and "⏸ paused" or "▶ reading")
end

-- Reads from the start of the next paragraph, or with a negative `step` from
-- the start of this one, or of the one before when this one has just begun.
function M.jump(step)
  if not session then return end
  local at = vim.api.nvim_win_get_cursor(session.win)
  local starts = {}
  for _, para in ipairs(paragraphs(session.buf)) do
    for _, pos in ipairs(para.pos) do
      if pos then
        starts[#starts + 1] = pos
        break
      end
    end
  end
  local current = 0
  for i, pos in ipairs(starts) do
    if not before(at, pos) then current = i end
  end
  local target = current + step
  if step < 0 and current > 0 and before(starts[current], at) then target = current end
  if not starts[target] then return end
  vim.api.nvim_win_set_cursor(session.win, starts[target])
  M.from_cursor()
end

local keys = { "<Space>", "<CR>", "<LeftMouse>", "q", "<Esc>", "}", "{" }

function M.stop()
  if not session then return end
  send({ cmd = "stop" })
  local s = session
  session = nil
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  if vim.api.nvim_win_is_valid(s.win) then
    vim.wo[s.win].winbar = s.winbar
    vim.wo[s.win].scrolloff = s.scrolloff
  end
  if vim.api.nvim_buf_is_valid(s.buf) then
    vim.bo[s.buf].modifiable = s.modifiable
    vim.o.guicursor = s.guicursor
    for _, key in ipairs(keys) do pcall(vim.keymap.del, "n", key, { buffer = s.buf }) end
  end
end

-- Enters the reading mode and reads from the cursor. While it's on, the
-- buffer can't be edited, so the words stay where the read expects them.
function M.start()
  if session then M.stop() end
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  if not start_helper() then return end
  session = {
    buf = buf, win = win, paras = {},
    winbar = vim.wo[win].winbar, scrolloff = vim.wo[win].scrolloff, modifiable = vim.bo[buf].modifiable,
    guicursor = vim.o.guicursor,
  }
  vim.o.guicursor = "a:ReadAloudCursor"
  -- A large scrolloff keeps the cursor line in the middle, except near the
  -- start and end of the file.
  vim.wo[win].scrolloff = 999
  vim.bo[buf].modifiable = false
  local opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "<Space>", M.toggle_pause, vim.tbl_extend("force", opts, { desc = "Pause or continue reading" }))
  vim.keymap.set("n", "<CR>", M.from_cursor, vim.tbl_extend("force", opts, { desc = "Read from the cursor" }))
  vim.keymap.set("n", "<LeftMouse>", "<LeftMouse><Cmd>lua require('readaloud').from_cursor()<CR>", vim.tbl_extend("force", opts, { desc = "Read from the clicked word" }))
  vim.keymap.set("n", "}", function() M.jump(1) end, vim.tbl_extend("force", opts, { desc = "Read from the next paragraph" }))
  vim.keymap.set("n", "{", function() M.jump(-1) end, vim.tbl_extend("force", opts, { desc = "Read this paragraph again, or the one before" }))
  vim.keymap.set("n", "q", M.stop, vim.tbl_extend("force", opts, { desc = "Stop reading" }))
  vim.keymap.set("n", "<Esc>", M.stop, vim.tbl_extend("force", opts, { desc = "Stop reading" }))
  M.from_cursor()
end

vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWipeout" }, {
  group = group,
  callback = function(args) if session and args.buf == session.buf then M.stop() end end,
})

function M.setup(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})
  if M.config.keymap then
    vim.keymap.set("n", M.config.keymap, M.start, { desc = "Read aloud from the cursor" })
  end
end

return M

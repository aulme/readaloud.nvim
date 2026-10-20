vim.api.nvim_create_user_command("ReadAloud", function() require("readaloud").start() end, {
  desc = "Read the buffer aloud from the cursor",
})
vim.api.nvim_create_user_command("ReadAloudStop", function() require("readaloud").stop() end, {
  desc = "Stop reading aloud",
})

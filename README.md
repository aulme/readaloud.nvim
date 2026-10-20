# readaloud.nvim

A Neovim plugin that reads a plain text or markdown buffer aloud and
highlights each word as it's spoken, like the read-aloud mode of an e-reader.
The cursor follows the words, and the line being read stays in the middle of
the window. The voice is [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M),
an open speech model that runs on your machine, so the text never leaves it.

## Requirements

- Neovim. I've only tried it on 0.12, on macOS.
- [uv](https://docs.astral.sh/uv/), which runs the plugin's Python helper with
  its dependencies pinned inside it. The first start downloads them, about
  1 GB with PyTorch, and then Kokoro's model and voices from Hugging Face,
  several hundred MB more.
- Sound. On Linux, the helper's audio library needs PortAudio, eg the
  `libportaudio2` package on Debian and Ubuntu.

## Install

With `vim.pack`, in Neovim 0.12:

```lua
vim.pack.add({ "https://github.com/aulme/readaloud.nvim" })
require("readaloud").setup({ keymap = "<leader>R" })
```

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "aulme/readaloud.nvim", opts = { keymap = "<leader>R" } }
```

## Use

`:ReadAloud`, or the key you set as `keymap`, starts reading from the
word under the cursor. The first start in a session takes a few seconds,
mostly to load PyTorch, and the helper stays running after that, so later
reads start at once.

While it reads, these keys work in that buffer:

| Key                       | Does                                                         |
| ------------------------- | ------------------------------------------------------------ |
| `Space`                   | pause or continue                                            |
| `Enter`, or click a word  | read from that word                                          |
| `}`                       | read from the next paragraph                                 |
| `{`                       | read this paragraph again, or the one before when it has just begun |
| `q` or `Esc`              | stop                                                         |

`Space` pauses even when it's your leader key, so your leader mappings don't
work in that buffer until you stop. The buffer can't be edited while it's
read, so the words stay where the highlight expects them. `:ReadAloudStop`
stops reading from anywhere.

## Options

These are the defaults:

```lua
require("readaloud").setup({
  voice = "af_heart",     -- a Kokoro voice
  speed = 1.0,            -- 1.2 reads 20% faster
  pause = 0.3,            -- the longest silence within a paragraph, in seconds
  paragraph_pause = 0.3,  -- the silence between paragraphs, in seconds
  keymap = nil,           -- a normal mode key that starts reading
})
```

Kokoro's [list of voices](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md)
has the rest. The first letter of a voice's name is its language, eg `a` for
American English and `b` for British English. Use an English voice, since
Kokoro gives the timing of each word, which the highlight needs, only for
English.

`pause` cuts any longer silence down to it, eg between sentences, where
Kokoro can pause for half a second or more.

The word and the line use the highlight groups `ReadAloudWord` and
`ReadAloudLine`. Define them in your config to change their colours.

## What it reads

In markdown, it reads headings, paragraphs, list items and quotes, and drops
the markup, eg the `**` around bold text and the target of a link. It skips
fenced code blocks, tables, front matter, horizontal rules and lines that
start an HTML comment. Each
heading and list item is a paragraph of its own.

Any other buffer is read as plain text, with paragraphs separated by blank
lines.

## How it works

The plugin starts `speak.py` with `uv run --script` and sends it the
paragraphs from the cursor onwards, each with its line breaks joined, as
Kokoro pauses at every line break. The helper turns them into speech up to 20
seconds ahead, plays it, and reports each word as it starts to play, by its
position in the paragraph. The plugin then maps that position back to the
line and column in the buffer.

## Licence

MIT. Kokoro is under the Apache 2.0 licence.

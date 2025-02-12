# gdb-ollama

**gdb-ollama** is a **GDB extension** that integrates **Ollama AI** into the GDB debugging workflow, allowing AI-powered debugging insights directly from within GDB. It provides an automated way to analyze the current debugging session and generate AI-assisted feedback.

## Features
- **Seamless GDB Integration**: Works as a single `.gdbinit` file.
- **AI Debugging Assistance**: Calls Ollama AI to analyze the program state.
- **Command-Driven**: Supports the `ollama-debug` command to trigger AI analysis.

## Installation
To install `gdb-ollama`, simply download and place `.gdbinit` in your home directory or load it manually:

```sh
curl -o ~/.gdbinit https://raw.githubusercontent.com/danielinux/gdb-ollama/refs/heads/master/.gdbinit
```

## Usage
1. **Start (any) GDB in TUI mode**:
   ```sh
   gdb -tui ./your-program
   ```

2. **Trigger AI debugging assistance** by running:
   ```gdb
   (gdb) ollama-debug
   ```

   - This will capture the backtrace and source code context.
   - It will send the captured information to **Ollama AI** for analysis.
   - The AI-generated response will be displayed inside the GDB UI.

![Demo gif of gdb-ollama](/gdb-ollama.gif)

## Requirements
- **GDB with Python support** (GDB 8.0+ recommended)
- **Ollama AI API running locally** (default: `http://localhost:11434`)
- **Python 3** (for AI query handling)

## License
`gdb-ollama` is licensed under the **GNU General Public License v3 (GPL-3.0)**.

## Contributing
Contributions are welcome! Feel free to submit issues or pull requests.

## Author
Developed by @danielinux. (README.md is AI generated.)


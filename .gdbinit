# gdb-ollama (GPLv3)
# https://github.com/danielinux/gdb-ollama

set logging enabled off
set logging overwrite on
set logging file gdb.out
set listsize 100
set logging enabled on

python


import gdb
import sys
import argparse
import httpx
import json
import asyncio
import ollama
import os
import time
import textwrap
import re
from collections import deque

global Prompt
global ModelName
global ModelRole
global History
History = None
Prompt = None
ModelName = 'qwen2.5-coder:7b'
ModelRole = "You are gdb-ollama, a GDB session debugging assistant with the possibility to communicate with both GDB and a human user. Your goal is to help with debugging sessions."
AiCmdWin = None


class ai_cmd_window():
    def __init__(self, tw):
        global AiCmdWin
        self._tui_window = tw
        AiCmdWin = self
        self.cmds = ""

    def render(self):
        height = self._tui_window.height
        width = self._tui_window.width
        self._tui_window.erase()
        wl = []
        buffer = deque(maxlen=height)
        if self.cmds:
             for line in self.cmds.split("\n"):
                 wl.extend(textwrap.wrap(line, width))
        buffer.extend(wl)
        for line in buffer:
            self._tui_window.write(line + '\n')
    def clear(self):
        self.cmds = ""
        self._tui_window.erase()

class ai_window():
    def __init__(self, tw):
        self._tui_window = tw
        self._before_prompt_listener = lambda : self.gdb_prompt()
        gdb.events.before_prompt.connect(self._before_prompt_listener)
        self.buffer = ""
        self.answer = ""
        self.model = None
        self.arch = None
        self.source = None
        self.messages = []
        self.closing = False

    def gdb_prompt(self):
        global Prompt
        if Prompt:
            asyncio.run(self.run())
        elif not self.model:
            self.model = ollama.create(model="gdb-ollama", from_=ModelName, system=ModelRole)
            res = ollama.chat('gdb-ollama', [{ 'role': 'user', 'content':'Hello! Introduce yourself.'}])
            if res:
                self.answer += res.message.content + "\nTo invoke the assistant, type the command 'ollama [<msg>]'.\n"
            self.render()
            self.messages += [ {'role': 'assistant', 'content': 'GDB{info connections}'},
                    {'role':'tool', 'content': gdb.execute('info connections',to_string = True)} ]
            self.messages += [ {'role': 'assistant', 'content': 'GDB{info target}'},
                    {'role':'tool', 'content': gdb.execute('info target',to_string = True)} ]

    async def run(self):
        global Prompt
        txt = Prompt
        Prompt = None
        self._tui_window.title = 'gdb-ollama'
        AiCmdWin.clear()
        await self.process_prompt(txt)

    async def process_prompt(self, txt):
        global ModelName, ModelRole, History
        self._tui_window.title = f'gdb-ollama [{self.arch}]: (model: {ModelName})'
        if not self.arch:
            self.arch = gdb.execute('show architecture', to_string=True).split(' ')[-1].rstrip(').')
        self.messages.append({"role": "user", "content": txt})
        try:
            fr = gdb.selected_frame()
            if fr:
                source = gdb.execute(f"list {fr.find_sal().symtab.filename}:{fr.name()}", to_string=True)
                if not source:
                    source = f'{fr.find_sal().filename}:{fr.name()}'
                ollama.embed('gdb-ollama', "architecture is " + self.arch + ".\nCurrent C code is " + source)
        except Exception:
            pass

        self.answer = ''
        try:
            gdb.execute('up', to_string=True)
            gdb.execute('down', to_string=True)
        except Exception as e:
            pass
        chat_msg = ('You are in command of a live debugging session on GDB. Analyze the GDB context in the messages history \n'+
                    'and the embedded code context \n' + gdb.execute('info line', to_string = True) + 
                    '\n' +
                    'To send GDB commands directly to the debugger, provide a line with GDB tag followed by a single command enclosed in curly brackets, e.g.:\nGDB{info registers}\n' +
                    'Move one little step at a time. The user will invoke you regularly. \n' +
                    'Do not make action lists: think about the present. All GDB will be executed at once.\n' + 
                    'Explore the sources using GDB{list}. Visit the registers and the stack. Show the value of local variables. Step if needed.' +
                    'Based on the code and the GDB context provided, inspect the code running and provide suggestions. ' +
                    'Optionally, you can decide to send GDB commands to interact with the live GDB session ongoing' +
                    'Use commands to collect information about the running session, such as register values, variables, source file content and memory content and stack traces. ' +
                    'Do not assume memory-mapped registers are known by name, use address to dereference.\n' +
                    'Ignore GDB crashes or errors from previous sessions.\n' + txt
        )
        if History:
            for en in History:
                self.messages += [ {"role": "tool", "content": en} ]
        try:
            resp = await ollama.AsyncClient().chat("gdb-ollama", messages=self.messages + [{"role": "user", "content": chat_msg}], stream=True)
            async for resp in resp:
                self.answer += resp.message.content
                self.render()
                self.messages.append({"role": "assistant", "content": self.answer})
            await self.process_gdb_commands()
        except Exception as e:
            self.answer += f'Error: {e}'
            self.render()

    async def process_gdb_commands(self):
        matches = re.finditer(r'GDB\{([^}]*)\}', self.answer)
        commands = [match.group(1) for match in matches]
        for xcmd in commands:
            self.messages.append({"role": "assistant", "content": xcmd})
            AiCmdWin.cmds += '\n(gdb) ' + xcmd + '\n'
            AiCmdWin.render()
            try:
                res = gdb.execute(xcmd, to_string=True)
            except gdb.error as e:
                res = str(e)
            AiCmdWin.cmds += res + '\n'
            AiCmdWin.render()
            self.messages.append({"role": "tool", "content": res})

    def close(self):
        gdb.events.before_prompt.disconnect(self._before_prompt_listener)

    def render(self):
        height = self._tui_window.height
        width = self._tui_window.width
        self._tui_window.erase()
        wl = []
        buffer = deque(maxlen=height)
        if self.answer:
             for line in self.answer.split("\n"):
                 wl.extend(textwrap.wrap(line, width))
        buffer.extend(wl)
        for line in buffer:
            self._tui_window.write(line + '\n')


class OllamaDebug(gdb.Command):
    def __init__(self):
        global Prompt
        super(OllamaDebug, self).__init__("ollama", gdb.COMMAND_USER)
        gdb.execute('lay split')
        gdb.execute('tui new-layout ailayout {-horizontal src 1 asm 1} 2 {-horizontal ai 3 aicmd 1} 2 cmd 1 status 1')
        gdb.execute('lay ailayout')
        gdb.execute('focus cmd', to_string=True)

    def invoke(self, arg, from_tty):
        global Prompt, History
        with open('gdb.out', 'r') as f:
            History = f.read()
        #gdb.execute('foc ai', to_string=True)
        if arg:
            Prompt = arg
        else:
            Prompt = "Continue the debug session."


gdb.register_window_type('ai', ai_window)
gdb.register_window_type('aicmd', ai_cmd_window)

OllamaDebug()


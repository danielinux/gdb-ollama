# gdb-ollama (GPLv3)
# https://github.com/danielinux/gdb-ollama

set logging enabled off
set logging overwrite off
set logging file gdb.out
set listsize 4000
set logging enabled on

python


import gdb
import sys
import argparse
import httpx
import json
import asyncio
import ollama
import threading
import os
import time
import textwrap
import re
import queue
from collections import deque

global Prompt
global ModelName
global ModelRole
global AI_Prompt_queue
Prompt = None
ModelName = 'qwen2.5-coder:7b'
ModelRole = "You are a GDB session debugging assistant with the possibility to communicate with both GDB and a human user. Your goal is to help with debugging sessions."



class ai_window():
    def __init__(self, tw):
        global AI_Prompt_queue
        self._tui_window = tw
        self.thread = None
        self._before_prompt_listener = lambda : self.gdb_prompt()
        self._free_objfile = lambda: self.kill()
        self.buffer = ""
        self.answer = ""
        self.model = None
        self.arch = None
        self.source = None
        self.messages = []
        gdb.events.before_prompt.connect(self._before_prompt_listener)
        self.queue = queue.Queue()
        self.running = False
        self.closing = False

    def gdb_prompt(self):
        global Prompt
        if not self.thread:
            self.thread = threading.Thread(target = lambda :self.run())
            self.thread.start()
        if Prompt:
            self.queue.put(Prompt)
            Prompt = None
        else:
            with open('gdb.out', 'r') as f:
                for l in f.readlines():
                    if not l:
                        continue
                    if l.startswith('(gdb)'):
                        self.messages += [ {'role': 'user', 'content': l } ]
                    else:
                        self.messages += [ {'role': 'tool', 'content': l } ]

    def run(self):
        global Prompt, ModelName, ModelRole
        self._tui_window.title = 'gdb-ollama'
        while True:
            try:
                msg = self.queue.get(timeout = .1)
            except queue.Empty:
                continue
            self.running = True
            if (msg):
                if msg == 'stop':
                    self.closing = False
                    break
                else:
                    prompt = msg.strip()
                    self.process_prompt(prompt)

    def process_prompt(self, txt):
        self.messages += [ { "role": "user", "content": txt } ]
        source = None
        if not self.arch:
            self.arch = gdb.execute('show architecture', to_string=True).rstrip('\n').split(' ')[-1].rstrip(').')
            self._tui_window.title = 'gdb-ollama ['+self.arch+']: (model: '+ModelName+')'
        self.render()
        if not self.model:
            self.model = ollama.create(model = "gdb-ollama", from_=ModelName, system=ModelRole)
        fr = gdb.selected_frame()
        try:
            if fr:
                source = gdb.execute("list " + fr.find_sal().symtab.filename+":"+fr.name(), to_string=True)
            if not source:
                source = '' + fr.find_sal().filename+':'+fr.name()
            ollama.embed('gdb-ollama', source)
        except Exception:
            pass

        while self.running:
            self.answer = ''
            chat_msg = ('You are in command of a live debugging session on GDB. Analyze the GDB context in the messages history \n'+
                        'and the embedded code context \n' +
                        '\n' +
                        'Based on the code and the GDB context provided, inspect the code running and provide suggestions. ' +
                        'Optionally, you can decide to send GDB commands to interact with the live GDB session ongoing. Do not interact with the program execution. ' +
                        'Only use commands to collect information about the running session, such as register values, variables, memory content and stack traces. ' +
                        'To send GDB commands directly to the debugger, provide a line with GDB tag followed by a single command enclosed in curly brackets, e.g.\nGDB{info registers}\n' +
                        'Do not assume memory-mapped registers are known by name, use address to dereference.\n' +
                        'Ignore GDB crashes or errors from previous sessions.\n' + txt
            )
            for part in (ollama.chat('gdb-ollama', messages = self.messages +
                    [ { "role": "user", "content": chat_msg }, ], stream = True)):
                self.answer += part.message.content
                self.render()
            self.messages += [ { "role": "assistant", "content": self.answer } ]

            matches = re.finditer(r'GDB{(.+?)}', self.answer)
            if matches:
                commands = [match.group(1) for match in matches]
                for xcmd in commands:
                    self.messages += [ { "role":"assistant", "content":xcmd} ]
                    err = False
                    try:
                        res = gdb.execute(xcmd, to_string=True)
                    except gdb.error as e:
                        res = str(e)
                        err = True
                    self.messages += [ { "role":"tool", "content":res } ]

            self.running = False

    def close(self):
        gdb.events.before_prompt.disconnect(self._before_prompt_listener)
        self.closing = True
        self.queue.put('stop')

        while self.closing:
            time.sleep(.1)


    def render(self):
        height = self._tui_window.height
        width = self._tui_window.width
        self._tui_window.erase()
        wl = []
        buffer = deque(maxlen = height)
        for line in self.answer.split("\n"):
            wl.extend(textwrap.wrap(line, width))
        buffer.extend(wl)
        for l in buffer:
            if l:
                self._tui_window.write(str(l) + '\n')


class OllamaDebug(gdb.Command):
    def __init__(self):
        super(OllamaDebug, self).__init__("ollama-debug", gdb.COMMAND_USER)
        gdb.execute('lay split')
        gdb.execute('tui new-layout ailayout {-horizontal src 1 asm 1} 2 ai 1 cmd 1 status 1')
        gdb.execute('lay ailayout')
        gdb.execute('focus cmd', to_string=True)
        gdb.execute('set logging enabled off', to_string=True)
        gdb.execute('set logging file gdb.out', to_string=True)
        gdb.execute('set logging enabled on', to_string=True)


    def invoke(self, arg, from_tty):
        global Prompt
        gdb.execute('foc ai', to_string=True)
        if arg:
            Prompt = arg
        else:
            Prompt = "Continue the debug session."

gdb.register_window_type('ai', ai_window)

OllamaDebug()


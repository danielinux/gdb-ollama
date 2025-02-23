# gdb-ollama (GPLv3)
# https://github.com/danielinux/gdb-ollama

set logging enabled off
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
import threading
import os
import time
import textwrap
import re
from collections import deque

global Prompt
Prompt = None


class ai_window:
    def __init__(self, tui_window):
        self._tui_window = tui_window
        self._before_prompt_listener = lambda : self.gdb_prompt()
        gdb.events.before_prompt.connect(self._before_prompt_listener)
        self.answer = ""
        self.arch = gdb.execute('show architecture', to_string=True).rstrip('\n').split(' ')[-1].rstrip(').')
        self.DEFAULT_HOST='http://deathstar:11434'
        self.DEFAULT_MODEL = 'qwen2.5-coder:7b'
        #self.DEFAULT_MODEL = 'deepseek-r1:70b'
        #self.DEFAULT_MODEL = 'deepseek-coder-v2:16b-lite-base-q4_0'
        self.DEFAULT_TIMEOUT = 300
        self._tui_window.title = 'gdb-ollama ['+self.arch+']: (model: '+self.DEFAULT_MODEL+')'
    def gdb_prompt(self):
        global Prompt
        if Prompt:
            txt = Prompt
            Prompt = None
            self.prompt(txt)
        self.render()
    def prompt(self, txt):
        source = None
        fr = gdb.selected_frame()
        source = gdb.execute("list " + fr.find_sal().symtab.filename+":"+fr.name(), to_string=True)
        # source = gdb.execute("list", to_string=True)
        if not source:
            source = '' + fr.find_sal().filename+':'+fr.name()
        with open("gdb.out", "r") as f:
            history = f.read()

        #chat_msg = ('"""Given the following code snippet, on architecture '+ self.arch +':\n'
        #            '<START_CODE>' + source + '<END_CODE>' +
        #            'And the following GDB session history:\n'
        #            '<START_GDB>' + history + '<END_GDB>\n'
        #            'You are a debugging assistant, running from within GDB. You can provide debugging hints, analysis, and next steps.\n'
        #            'Keep answer short and work one step at a time.\n'
        #            'You can decide to execute GDB commands to inspect registers, variables etc. using valid gdb syntax.\n'
        #            'Do not assume memory-mapped registers are known by name, use address to dereference.\n'
        #            'Do not use GDB commands to interact with the program execution, only for inspection to collect more information to keep investigating, and only if needed.\n'
        #            'Interact directly with gdb using GDB tag followed by the command enclosed them in curly brackets, e.g.:\nGDB{x /4x $sp; info registers}\n'
        #            'Ignore GDB crashes or errors from previous sessions.\n'
        #    )
        chat_msg = ('Analyze the GDB context: \n'+
                    history + '\n' +
                    'and the code context: \n' +
                    source +' \n' +
                    '\n' +
                    'You are the GDB assistant. Based on the code and the GDB context provided, inspect the code running and provide suggestions. ' +
                    'Optionally, you can decide to send GDB commands to interact with the live GDB session ongoing. Do not interact with the program execution. ' +
                    'Only use commands to collect information about the running session, such as register values, variables, memory content and stack traces. ' +
                    'To send GDB commands directly to the debugger, provide a line with GDB tag followed by a single command enclosed in curly brackets, e.g.\nGDB{info registers}\n' +
                    'Do not assume memory-mapped registers are known by name, use address to dereference.\n' +
                    'Ignore GDB crashes or errors from previous sessions.\n'
        )



        if txt != None and txt != " ":
            chat_msg += (txt + '\n"""')
        else:
            chat_msg += ('Provide analysis, debugging hints, and next steps.\n"""')
        with open("gdb.out", "a") as f:
            f.write("prompt: " + chat_msg + "\n")
        asyncio.run(self.main(self.DEFAULT_HOST, self.DEFAULT_MODEL, self.DEFAULT_TIMEOUT, chat_msg))
        self.render()

    def close(self):
        gdb.events.before_prompt.disconnect(self._before_prompt_listener)

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

    async def stream_chat_message(self, messages, endpoint, model, timeout):
        headers = {
            'Content-Type': 'application/json',
            'Accept': '*/*',
            'Host': endpoint.split('//')[1].split('/')[0]
        }
        data = {'model': model, 'messages': messages}
        assistant_message = "\n\n"
        self.answer += '\n'


        try:
            async with httpx.AsyncClient(timeout=timeout) as client:
                async with client.stream('POST', endpoint, headers=headers, json=data) as response:
                    if response.status_code == 200:
                        async for line in response.aiter_lines():
                            if line:
                                message = json.loads(line)
                                if 'message' in message and 'content' in message['message']:
                                    content = message['message']['content']
                                    assistant_message += content
                                    self.answer+=content
                                    self.render()
                                    if '<EOT>' in content:
                                        gdb.execute("echo [End of AI Debugging Assistance]")
                                        break

                    else:
                        await response.aread()
                        raise Exception(f"Error: {response.status_code} - {response.text}")
        except httpx.ReadTimeout:
            print("Read timeout occurred. Please try again.")
        except asyncio.CancelledError:
            pass
        except Exception as e:
            pass

        if assistant_message:
            messages.append({"role": "assistant", "content": assistant_message.strip()})
        gdb.execute('focus cmd')
        with open("gdb.out", "a") as f:
            f.write("answer: " + assistant_message + "\n")
        matches = re.finditer(r'GDB{(.+?)}', assistant_message)
        if matches:
            commands = [match.group(1) for match in matches]
            for xcmd in commands:
                err = False
                try:
                    res = gdb.execute(xcmd, to_string=True)
                except gdb.error as e:
                    res = str(e)
                    err = True

                with open("gdb.out", "a") as f:
                    f.write("gdb command: " + xcmd + "\n")
                    f.write("gdb command result: " + res + "\n")
                self.answer += '\n'
                self.answer += "(gdb) " + xcmd + "\n"
                if err:
                    self.answer += res + "\n"
                else:
                    self.answer += res + "\n"
                self.render()


    async def main(self, baseurl, model, timeout, user_message):
        conversation_history = []
        endpoint = baseurl + "/api/chat"
        conversation_history.append({"role": "user", "content": user_message})
        await self.stream_chat_message(conversation_history, endpoint, model, timeout)

class OllamaDebug(gdb.Command):
    def __init__(self):
        super(OllamaDebug, self).__init__("ollama-debug", gdb.COMMAND_USER)
        gdb.execute('lay split')
        gdb.execute('tui new-layout ailayout {-horizontal src 1 asm 1} 2 ai 1 cmd 1 status 1')
        gdb.execute('lay ailayout')
        gdb.execute('focus cmd', to_string=True)


    def invoke(self, arg, from_tty):
        x = gdb.execute('set logging enabled off', to_string=True)
        x = gdb.execute('set logging file gdb.out', to_string=True)
        x = gdb.execute('set logging enabled on', to_string=True)
        gdb.execute('foc ai', to_string=True)
        global Prompt
        if arg:
            Prompt = arg
        else:
            Prompt = " "

gdb.register_window_type('ai', ai_window)

OllamaDebug()


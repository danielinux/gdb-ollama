# gdb-ollama (GPLv3)
# https://github.com/danielinux/gdb-ollama
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
from collections import deque


class ai_window:
    def __init__(self, tui_window):
        self._tui_window = tui_window
        self._before_prompt_listener = lambda : self.prompt()
        gdb.events.before_prompt.connect(self._before_prompt_listener)
        self.answer = ""
        self.DEFAULT_HOST = 'http://localhost:11434'
        self.DEFAULT_MODEL = 'mistral:latest'
        self.DEFAULT_TIMEOUT = 60
        self._tui_window.title = 'LLM Hints: ('+self.DEFAULT_MODEL+')'
    def prompt(self):
        print("Fetching debugging info for Ollama...")
        source = gdb.execute("list .", to_string=True)
        history = gdb.execute("bt full", to_string=True)
        chat_msg = ("Given the following code snippet:\n"
                    "<START_CODE>" + source + "<END_CODE>" +
                    "And the following GDB session history:\n"
                    "<START_GDB>" + history + "<END_GDB>\n"
                    "Provide analysis, debugging hints, and next steps. Keep answers short and don't provide code longer than one single line.")
        asyncio.run(self.main(self.DEFAULT_HOST, self.DEFAULT_MODEL, self.DEFAULT_TIMEOUT, chat_msg))
        self.render()

    def render(self):
        height = self._tui_window.height
        width = self._tui_window.width
        self._tui_window.erase()
        wl = []
        buffer = deque(maxlen = height)
        for line in self.answer.split("\n"):
            wl.extend(textwrap.wrap(line, width))
        buffer.extend(wl)
        #buffer.rotate(-height)
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
        assistant_message = ""

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
                                        break
                        gdb.execute("echo \n[End of AI Debugging Assistance]\n")
                    else:
                        await response.aread()
                        raise Exception(f"Error: {response.status_code} - {response.text}")
        except httpx.ReadTimeout:
            print("Read timeout occurred. Please try again.")
        except asyncio.CancelledError:
            raise
        except Exception as e:
            print(f"An error occurred: {str(e)}")

        if assistant_message:
            messages.append({"role": "assistant", "content": assistant_message.strip()})

    async def main(self, baseurl, model, timeout, user_message):
        conversation_history = []
        endpoint = baseurl + "/api/chat"
        conversation_history.append({"role": "user", "content": user_message})
        await self.stream_chat_message(conversation_history, endpoint, model, timeout)

class OllamaDebug(gdb.Command):
    def __init__(self):
        super(OllamaDebug, self).__init__("ollama-debug", gdb.COMMAND_USER)

    def invoke(self, arg, from_tty):
        gdb.execute('lay split')
        gdb.execute('tui new-layout ailayout {-horizontal src 1 asm 1} 2 ai 1 cmd 1 status 1')
        gdb.execute('lay ailayout')
        gdb.execute('foc ai')
        print("Fetching debugging info for Ollama...")

gdb.register_window_type('ai', ai_window)

OllamaDebug()


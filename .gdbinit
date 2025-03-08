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
from elftools.elf.elffile import ELFFile

global Prompt
global ModelName
global ModelRole
global History
History = None
Prompt = None

ModelName='qwen2.5-coder-32b-16k'
ModelRole = ("You are gdb-ollama, a debugging assistant. Your goal is to provide strategies and ideas to debug the current executable.\n" +
             "Work one step at a time. Stick to the information you can verify through current register/memory/code/values. Use the following format:\n" +
             "Thought: you should always think about what to do. " +
             "Can I provide a final answer, or do I need to use a TOOL_CALL tag? " +
             "What is the current status of the system? Do I need to check the value of CPU registers or memory to find out what is going on?" +
             "Do I need to look into the implementation of the functions involved? Do I need to advance the state of the program?\n" +
             "API identification: look for TOOL_CALL: tags in the prompt to find out which APIs are available\n" +
             "Action: the action to take, should be either providing a Final Answer, or Calling one of the API provided. API calls MUST always be prefixed by the TOOL_CALL: tag. If using a TOOL_CALL, end your answer here and wait for the tool response.\n" +
             "TOOL_CALL: the input to the action. Send the action as reply.\n" +
             "Observation: the result of the and related functions, or do you need to call APIs to complete the analysis?\n" +
             "... (this Thought/Action/TOOL_CALL:/Observation sequence can be repeated zero or more times)\n" +
             "Thought: I finally know what is going on, and/or I have spotted a critical problem in the code.\n" +
             "Final Answer: the final answer to the original user question, or an explaination of the critical problem encountered. I provide a list of suggested fixes.\n\n\nLet's begin!\n" +
"")
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

class ElfSymbol():
    def __init__(self, name, address, size, type, file, start_line, end_line):
        self.name = name
        self.address = address
        self.size = size
        self.type = type
        self.file_ = file
        self.start_line = start_line
        self.end_line = end_line


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
        self.elffile = None
        self.symbols = []
        self.elf_file = None

    def get_symbols_by_name(self, sname):
        match = []
        for s in self.symbols:
           if s.name == sname:
               match.append(s)
        return match

    def get_symbol_by_address(self, address):
        for s in self.symbols:
           if s.address == int(address, base=16):
              return s
        return None

    def gdb_prompt(self):
        global Prompt
        f = None
        if Prompt:
            asyncio.run(self.run())
        elif not self.model:
            self.model = ollama.create(model="gdb-ollama", from_=ModelName, system=ModelRole)
            # Get information about running target, connections, elf file
            try:
                elf_file_string = gdb.execute('info file', to_string=True).split('\n')[0].strip()
                elf_file = elf_file_string.split('"')[1]
            except:
                self.answer += 'no debugging symbols found!'
                self.render()
                return
            finally:
                try:
                    f = open(elf_file, 'rb')
                    self.elffile = ELFFile(f)
                except FileNotFoundError:
                    self.answer += 'elf file not found!'
                    self.render()
                    return

            self.arch = self.elffile.get_machine_arch()
            symtab_section = self.elffile.get_section_by_name('.symtab')
            if symtab_section is None:
                self.answer += ("Symbol table section not found")
                self.render()
                return

            dwarf_info = self.elffile.get_dwarf_info() if self.elffile.has_dwarf_info() else None
            if dwarf_info is None:
                self.answer += ("DWARF info section not found")
                self.render()
                return

            line_programs = {cu: dwarf_info.line_program_for_CU(cu) for cu in dwarf_info.iter_CUs()} if dwarf_info else {}

            for symbol in symtab_section.iter_symbols():
                sym_name = symbol.name
                sym_address = symbol.entry['st_value'] & ~0x01
                sym_size = symbol.entry['st_size']
                sym_type = symbol.entry['st_info']['type']

                if sym_type in ['STT_NOTYPE', 'STT_FILE', 'STT_SECTION']:
                    continue

                file_name = None
                start_line = None
                end_line = None
                for cu, line_prog in line_programs.items():

                    # First, find the correct file name and starting line
                    for entry in line_prog.get_entries():
                        if entry and entry.state and (entry.state.address & ~0x01) == sym_address and sym_size > 0 and entry.state.file > 0:
                            file_idx = entry.state.file
                            if file_idx > 0 and entry.state.line > 0:
                                file_name = line_prog['file_entry'][file_idx - 1].name.decode('utf-8', errors='ignore')
                                start_line = entry.state.line  # First occurrence is likely the start
                            break  # Stop scanning once we have the first match

                    # Now, find the function's address range
                    for die in cu.iter_DIEs():
                        if die.tag == "DW_TAG_subprogram":
                            func_name_attr = die.attributes.get("DW_AT_name")
                            low_pc_attr = die.attributes.get("DW_AT_low_pc")
                            high_pc_attr = die.attributes.get("DW_AT_high_pc")

                            if func_name_attr and low_pc_attr and high_pc_attr:
                                func_name = func_name_attr.value.decode('utf-8', errors='ignore')
                                low_pc = low_pc_attr.value

                                # Compute high_pc correctly (absolute or relative)
                                high_pc_raw = high_pc_attr.value
                                high_pc = high_pc_raw + low_pc if high_pc_attr.form.startswith("DW_FORM_data") else high_pc_raw

                                # Check if this DIE corresponds to our symbol
                                if func_name == sym_name and (low_pc & ~0x01 == sym_address) and sym_address < high_pc:
                                    # Scan line table for highest line number within the address range
                                    for en in line_prog.get_entries():
                                        if en.state and (low_pc <= (en.state.address & ~0x01) < high_pc):
                                            if end_line is None or en.state.line > end_line:
                                                end_line = en.state.line  # Track the last valid line
                                    break  # Function found, exit loop
                if file_name == None or start_line == None or end_line == None:
                    continue

                s = ElfSymbol(sym_name, sym_address, sym_size, sym_type, file_name, start_line, end_line)
                self.symbols.append(s)

            if f:
                f.close()
            self.render()

    async def run(self):
        global Prompt
        txt = Prompt
        Prompt = None
        self._tui_window.title = 'gdb-ollama'
        AiCmdWin.clear()
        await self.process_prompt(txt)

    async def process_prompt(self, txt):
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
        except Exception:
            pass

        self.answer = ''
        try:
            gdb.execute('up', to_string=True)
            gdb.execute('down', to_string=True)
        except Exception as e:
            pass
        continue_debugging = True
        self.messages.append({'role':'user', 'content':''})
        while continue_debugging:
            chat_msg = ('\n' +
                    'You are an AI assistant with the purpose of helping to debug a program running under GDB. \n' +
                    'Follow these APIs to interact with gdb and to inspect the code under analysis.\n'+
                    'Usage: TOOL_CALL:{"name":"show_source_of", "arguments":{"function_name": "name_of_the_function" }} Search for a function in the codebase given its name and returns its source code \n' +
                    'Usage: TOOL_CALL:{"name":"show_source_at", "arguments":{"address": "address_of_the_function" }} Search for a function in the codebase given its address and returns its source code \n' +
                    'Usage: TOOL_CALL:{"name":"show_assembly_at", "arguments":{"address": "address_of_the_symbol", "length": size_in_bytes }} Show the assembly code of a symbol given its address and for the specified length. \n' +
                    'Usage: TOOL_CALL:{"name":"show_stack_trace", "arguments":{}} Show the current stack trace. \n' +
                    'Usage: TOOL_CALL:{"name":"show_registers", "arguments":{}} Show the value of the CPU registers\n' +
                    'Usage: TOOL_CALL:{"name":"show_memory_at", "arguments":{"address": "address_in_memory", "length": size_in_bytes }} Show the memory content of a symbol given its address and for the specified length. \n' +
                    'Usage: TOOL_CALL:{"name":"step_into", "arguments":{"steps":"number_of_steps"}} Step into the next line of code. \n' +
                    'Usage: TOOL_CALL:{"name":"step_over", "arguments":{}} Step over the next line of code. \n' +
                    'Usage: TOOL_CALL:{"name":"continue_execution", "arguments":{}} Continue execution until a breakpoint is hit or the program exits. \n' +
                    'Usage: TOOL_CALL:{"name":"break_at", "arguments":{"address": address_of_the_symbol }} Set a breakpoint at the specified address.\n' +
                    'Usage: TOOL_CALL:{"name":"break", "arguments":{"function": address_of_the_symbol }} Set a breakpoint at the specified function.\n' +
                    'Usage: TOOL_CALL:{"name":"delete_breakpoint", "arguments":{"number": number_of_the_breakpoint }} Delete the breakpoint with the specified number. \n' +
                    'Usage: TOOL_CALL:{"name":"delete_all_breakpoints", "arguments":{}} Delete all breakpoints \n'+
                    'Usage: TOOL_CALL:{"name":"show_breakpoints", "arguments":{}} Show all breakpoints set in the current session.\n' +
                    'Usage: TOOL_CALL:{"name":"evaluate_expression", "arguments":{"expression": expression_to_evaluate}} Evaluate a C expression and return the result \n' +
                    'Usage: TOOL_CALL:{"name":"stack_climb", "arguments":{}} Climb up the stack trace by one frame.\n' +
                    'Usage: TOOL_CALL:{"name":"stack_descend", "arguments":{}} Descend down the stack trace by one frame.\n' +
                    'Usage: TOOL_CALL:{"name":"reset", "arguments" : {}} Reset the current GDB session, e.g. restart the program, or send "mon reset" to the remote target.\n' +
                    'The current architecture is ' + self.arch + '\n' +
                    #'and the current context \n' + gdb.execute('info line', to_string = True) +
                    #'\n' + gdb.execute('where', to_string = True) + '\n' +
                    'Based on the code and the GDB context provided, inspect the code running and provide suggestions. ' +
                    'Ignore GDB crashes or errors from previous sessions.\n' +
                    'Query from user: '  + txt +
                    '\n'
            )
            self.messages[-1]['content'] += '\n' + chat_msg
            try:
                gdb.execute('focus ai', to_string=True)
                resp = await ollama.AsyncClient().chat("gdb-ollama", messages=self.messages, stream=True)
                answer = ''
                async for resp in resp:
                    answer += resp.message.content
                    self.answer += resp.message.content
                    self.render()
                self.messages.append({"role": "assistant", "content": resp.message.content})
                self.answer += '\n\n'
                gdb.execute('focus aicmd', to_string=True)
                continue_debugging = self.process_commands(answer)
                self.render()
                gdb.execute('focus src', to_string=True)
            except Exception as e:
                self.answer += f'Error: {e}'
                self.render()

    def show_source_of(self, fn_name):
        res = ''
        for s in self.get_symbols_by_name(fn_name):
            res += f'Function: {s.name}\n'
            res += f'Source file: {s.file_}\n'
            res += f'Execution address: {s.address}\n'
            res += f'Code:\n'
            with open(s.file_, 'r') as f:
                lines = f.readlines()
                start_line = s.start_line - 1
                end_line = s.end_line + 4
                res += ''.join(lines[start_line:end_line])
            res += '\n'
        return res

    def show_source_at(self, address):
        res = ''
        s = self.get_symbol_by_address(address)
        if s:
            res += f'Function: {s.name}\n'
            res += f'Source file: {s.file_}\n'
            res += f'Execution address: {s.address}\n'
            res += f'Code:\n'
            with open(s.file_, 'r') as f:
                lines = f.readlines()
                start_line = s.start_line - 1
                end_line = s.end_line + 4
                res += ''.join(lines[start_line:end_line])
        else:
            res += f'No symbol found at address {address}\n'
        return res

    def process_commands(self, msg):
        AiCmdWin.clear()
        AiCmdWin.cmds += msg
        AiCmdWin.render()

        matches = re.finditer(r'TOOL_CALL:\s*\{([^}]*)\}', msg)
        commands = ['{' + match.group(1) + '}}' for match in matches]
        res = '\n'
        if len(commands) == 0 and '"name":' in msg and '"arguments":' in msg:
            res += '\nSyntax Error: Assistant tried to invoke API without TOOL_CALL: Tag. I MUST use the TOOL_CALL: tag to access the API, e.g.: TOOL_CALL:{"name":"show_registers", "arguments":{}}\n'
            AiCmdWin.cmds += res
            AiCmdWin.render()
            self.messages.append({"role": "user", "content": res})
            return True
        for xcmd in commands:
            self.messages.append({"role": "assistant", "content": xcmd})
            try:
                res += '\nTOOL_CALL:'+xcmd+'\n'
                xcmd = json.loads(xcmd.strip())
                if False:
                    pass
                elif xcmd['name'] == 'show_source_of':
                    fn_name = xcmd['arguments']['function_name']
                    res += self.show_source_of(fn_name)
                elif xcmd['name'] == 'show_source_at':
                    res += self.show_source_at(xcmd['arguments']['address'])
                elif xcmd['name'] == 'show_assembly_at':
                    res += gdb.execute(f'disassemble {xcmd["arguments"]["address"]}', to_string=True)
                elif xcmd['name'] == 'show_stack_trace':
                    res += gdb.execute('bt full', to_string=True)
                elif xcmd['name'] == 'show_registers':
                    res += gdb.execute('info registers', to_string=True)
                elif xcmd['name'] == 'show_memory_at':
                    res += gdb.execute(f'x/{xcmd["arguments"]["length"]}x {xcmd["arguments"]["address"]}', to_string=True)  # Show memory at the specified address
                elif xcmd['name'] == 'show_variables':
                    res += gdb.execute('info locals', to_string=True)
                elif xcmd['name'] == 'break_at':
                    res += gdb.execute('b *' + xcmd['arguments']['address'], to_string=True)
                elif xcmd['name'] == 'break':
                    res += gdb.execute('b ' + xcmd['arguments']['function'], to_string=True)
                elif xcmd['name'] == 'evaluate_expression':
                    res += gdb.execute('p ' + xcmd['arguments']['expression'], to_string=True)
                elif xcmd['name'] == 'continue_execution':
                    res += 'Continuing...\n'
                    c = gdb.execute('c', to_string=True)
                elif xcmd['name'] == 'step_into':
                    try:
                        steps = int(xcmd['arguments']['steps'])
                    except:
                        steps = 1

                    for _ in range(steps):
                        res += "stepping\n"
                        res += gdb.execute('si', to_string = True)
                elif xcmd['name'] == 'step_over':
                    res += gdb.execute('n', to_string = True)
                elif xcmd['name'] == 'show_breakpoints':
                    res += gdb.execute('info breakpoints', to_string=True)
                elif xcmd['name'] == 'delete_breakpoint':
                    res += gdb.execute(f'delete {xcmd["arguments"]["breakpoint_number"]}', to_string=True)  # Delete breakpoint by number
                elif xcmd['name'] == 'delete_all_breakpoints':
                    res += gdb.execute('d', to_string=True)
                elif xcmd['name'] == 'stack_climb':
                    res += gdb.execute('up', to_string = True)
                elif xcmd['name'] == 'stack_descend':
                    res += gdb.execute('down', to_string = True)

                elif xcmd['name'] == 'reset':
                    info = gdb.execute('info conn', to_string=True)
                    if 'native' in info.lower() or 'no connection' in info.lower():
                        res += gdb.execute('run', to_string = True)
                    else:
                        res += gdb.execute('mon reset', to_string = True)
                        #res += gdb.execute('mon reset 0', to_string = True)
                else:
                    res += f'Unknown command: {xcmd}\n'
            except Exception as e:
                res += f'Error executing command: {str(e)}\n'
            if (len(res) > 0):
                self.messages.append({"role": "user", "content": res})
                AiCmdWin.clear()
                AiCmdWin.cmds += res + '\n'
                AiCmdWin.render()
                return True
            else:
                print("Done.")
                return False

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
        gdb.execute('tui new-layout ailayout src 2 {-horizontal ai 3 aicmd 1} 2 cmd 1 status 1')
        gdb.execute('lay ailayout')
        gdb.execute('focus cmd', to_string=True)

    def invoke(self, arg, from_tty):
        global Prompt, History
        with open('gdb.out', 'r') as f:
            History = f.read()
        gdb.execute('foc ai', to_string=True)
        if arg:
            Prompt = arg
        else:
            Prompt = "Continue the debug session."


gdb.register_window_type('ai', ai_window)
gdb.register_window_type('aicmd', ai_cmd_window)

OllamaDebug()


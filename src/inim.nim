# MIT License
# Copyright (c) 2018 Andrei Regiani

import os, osproc, strformat, strutils, terminal, times, strformat, streams, parsecfg
import noise

type App = ref object
  nim: string
  srcFile: string
  showHeader: bool
  flags: string
  rcFile: string
  showColor: bool
  noAutoIndent: bool

var
  app: App
  config: Config
  indentSpaces = "  "

const
  NimblePkgVersion {.strdefine.} = ""
  # endsWith
  IndentTriggers = [
      ",", "=", ":",
      "var", "let", "const", "type", "import",
      "object", "RootObj", "enum"
  ]
  # preloaded code into user's session
  EmbeddedCode = staticRead("inimpkg/embedded.nim")
  ConfigDir = getConfigDir() / "inim"
  RcFilePath = ConfigDir / "inim.ini"

proc createRcFile(path: string): Config =
  ## Create a new rc file with default sections populated
  result = newConfig()
  result.setSectionKey("History", "persistent", "True")
  result.setSectionKey("Style", "prompt", "nim> ")
  result.setSectionKey("Style", "showTypes", "True")
  result.setSectionKey("Style", "ShowColor", "True")
  result.writeConfig(path)

let
  uniquePrefix = epochTime().int
  bufferSource = getTempDir() & "inim_" & $uniquePrefix & ".nim"
  tmpHistory = getTempDir() & "inim_history_" & $uniquePrefix & ".nim"

proc compileCode(): auto =
  # PENDING https://github.com/nim-lang/Nim/issues/8312, remove redundant `--hint[source]=off`
  let compileCmd = [
      app.nim, "compile", "--run", "--verbosity=0", app.flags,
      "--hints=off", "--hint[source]=off", "--path=./", bufferSource
  ].join(" ")
  result = execCmdEx(compileCmd)

proc getPromptSymbol(): Styler

var
  currentExpression = "" # Last stdin to evaluate
  currentOutputLine = 0  # Last line shown from buffer's stdout
  validCode = ""         # All statements compiled succesfully
  tempIndentCode = ""    # Later append to `validCode` if whole block compiles well
  indentLevel = 0        # Current
  previouslyIndented = false # Helper for showError(), indentLevel resets before showError()
  sessionNoAutoIndent = false
  buffer: File
  noiser = Noise.init()
  historyFile: string

template outputFg(color: ForegroundColor, bright: bool = false,
    body: untyped): untyped =
  ## Sets the foreground color for any writes to stdout in body and resets afterwards
  if config.getSectionValue("Style", "showColor") == "True":
    stdout.setForegroundColor(color, bright)
  body

  if config.getSectionValue("Style", "showColor") == "True":
    stdout.resetAttributes()
  stdout.flushFile()

proc getNimVersion*(): string =
  let (output, status) = execCmdEx(fmt"{app.nim} --version")
  doAssert status == 0, fmt"make sure {app.nim} is in PATH"
  result = output.splitLines()[0]

proc getNimPath(): string =
  # TODO: use `which` PENDING https://github.com/nim-lang/Nim/issues/8311
  let whichCmd = when defined(Windows):
        fmt"where {app.nim}"
    else:
        fmt"which {app.nim}"
  let (output, status) = execCmdEx(which_cmd)
  if status == 0:
    return " at " & output
  return "\n"


proc welcomeScreen() =
  outputFg(fgYellow, false):
    when defined(posix):
      stdout.write "👑 " # Crashes on Windows: Unknown IO Error [IOError]
    stdout.writeLine "INim ", NimblePkgVersion
    if config.getSectionValue("Style", "showColor") == "True":
      stdout.setForegroundColor(fgCyan)
    stdout.write getNimVersion()
    stdout.write getNimPath()


proc cleanExit(exitCode = 0) =
  buffer.close()
  removeFile(bufferSource) # Temp .nim
  removeFile(bufferSource[0..^5]) # Temp binary, same filename just without ".nim"
  removeFile(tmpHistory)
  removeDir(getTempDir() & "nimcache")
  when promptHistory:
    # Save our history
    discard noiser.historySave(historyFile)
  quit(exitCode)

proc getFileData(path: string): string =
  try: path.readFile() except: ""

proc compilationSuccess(current_statement, output: string, commit = true) =
  ## Add our line to valid code
  ## If we don't commit, roll back validCode if we've entered an echo
  if len(tempIndentCode) > 0:
    validCode &= tempIndentCode
  else:
    validCode &= current_statement & "\n"

  # Print only output you haven't seen
  outputFg(fgCyan, true):
    let lines = output.splitLines
    let new_lines = lines[currentOutputLine..^1]
    for index, line in new_lines:
      # Skip last empty line (otherwise blank line is displayed after command)
      if index+1 == len(new_lines) and line == "":
        continue
      echo line

  # Roll back our valid code to not include the echo
  if current_statement.contains("echo") and not commit:
    let newOffset = current_statement.len + 1
    validCode = validCode[0 ..< ^newOffset]
  else:
    # Or commit the line
    currentOutputLine = len(lines)-1

proc bufferRestoreValidCode() =
  if buffer != nil:
    buffer.close()
  buffer = open(bufferSource, fmWrite)
  buffer.writeLine(EmbeddedCode)
  buffer.write(validCode)
  buffer.flushFile()

proc showError(output: string) =
  # Determine whether last expression was to import a module
  var importStatement = false
  try:
    if currentExpression[0..6] == "import ":
      importStatement = true
  except IndexError:
    discard

  #### Runtime errors:
  if output.contains("Error: unhandled exception:"):
    outputFg(fgRed, true):
      # Display only the relevant lines of the stack trace
      let lines = output.splitLines()

      if not importStatement:
        echo lines[^3]
      else:
        for line in lines[len(lines)-5 .. len(lines)-3]:
          echo line
    return

  #### Compilation errors:
  # Prints only relevant message without file and line number info.
  # e.g. "inim_1520787258.nim(2, 6) Error: undeclared identifier: 'foo'"
  # Becomes: "Error: undeclared identifier: 'foo'"
  let pos = output.find(")") + 2
  var message = output[pos..^1].strip

  # Discard shortcut conditions
  let
    a = currentExpression != ""
    b = importStatement == false
    c = previouslyIndented == false
    d = message.contains("and has to be")

  # Discarded shortcut, print values: nim> myvar
  if a and b and c and d:
    # Following lines grabs the type from the discarded expression:
    # Remove text bloat to result into: e.g. foo'int
    message = message.multiReplace({
        "Error: expression '": "",
        " is of type '": "",
        "' and has to be discarded": "",
        "' and has to be used (or discarded)": ""
    })
    # Make split char to be a semicolon instead of a single-quote,
    # To avoid char type conflict having single-quotes
    message[message.rfind("'")] = ';' # last single-quote
    let message_seq = message.split(";") # expression;type, e.g 'a';char
    let typeExpression = message_seq[1] # type, e.g. char

    # Ignore this colour change
    let shortcut = when defined(Windows):
            fmt"""
            stdout.write $({currentExpression})
            stdout.write "  : "
            stdout.write "{typeExpression}"
            echo ""
            """.unindent()
        else: # Posix: colorize type to yellow
          if config.getSectionValue("Style", "showColor") == "True":
            fmt"""
            stdout.write $({currentExpression})
            stdout.write "\e[33m" # Yellow
            stdout.write "  : "
            stdout.write "{typeExpression}"
            echo "\e[39m" # Reset color
            """.unindent()
          else:
            fmt"""
            stdout.write $({currentExpression})
            stdout.write "  : "
            stdout.write "{typeExpression}"
            """.unindent()

    buffer.writeLine(shortcut)
    buffer.flushFile()

    let (output, status) = compileCode()
    if status == 0:
      compilationSuccess(shortcut, output)
    else:
      bufferRestoreValidCode()
      showError(output) # Recursion

    # Display all other errors
  else:
    outputFg(fgRed, true):
      echo if importStatement:
              output.strip() # Full message
          else:
              message # Shortened message
    previouslyIndented = false

proc getPromptSymbol(): Styler =
  var prompt = ""
  if indentLevel == 0:
    prompt = config.getSectionValue("Style", "prompt")
    previouslyIndented = false
  else:
    prompt = ".... "
  # Auto-indent (multi-level)
  prompt &= indentSpaces.repeat(indentLevel)
  result = Styler.init(prompt)

proc init(preload = "") =
  bufferRestoreValidCode()

  if preload == "":
    # First dummy compilation so next one is faster for the user
    discard compileCode()
    return

  buffer.writeLine(preload)
  buffer.flushFile()

  # Check preloaded file compiles succesfully
  let (output, status) = compileCode()
  if status == 0:
    compilationSuccess(preload, output)

  # Compilation error
  else:
    bufferRestoreValidCode()
    # Imports display more of the stack trace in case of errors, instead of one liners error
    currentExpression = "import " # Pretend it was an import for showError()
    showError(output)
    cleanExit(1)

proc hasIndentTrigger*(line: string): bool =
  if line.len == 0:
    return
  for trigger in IndentTriggers:
    if line.strip().endsWith(trigger):
      result = true

proc doRepl() =
  # Read line
  let ok = noiser.readLine()
  if not ok:
    case noiser.getKeyType():
    of ktCtrlC:
      bufferRestoreValidCode()
      indentLevel = 0
      tempIndentCode = ""
      return
    of ktCtrlD:
      echo "\nQuitting INim: Goodbye!"
      cleanExit()
    else:
      return

  currentExpression = noiser.getLine

  # Special commands
  if currentExpression in ["exit", "exit()", "quit", "quit()"]:
    cleanExit()
  elif currentExpression in ["help", "help()"]:
    outputFg(fgCyan, true):
      echo("""
iNim - Interactive Nim Shell - By AndreiRegiani

Available Commands:
Quit - exit, exit(), quit, quit(), ctrl+d
Help - help, help()""")
    return

  # Empty line: exit indent level, otherwise do nothing
  if currentExpression == "":
    if indentLevel > 0:
      indentLevel -= 1
    elif indentLevel == 0:
      return

  # Write your line to buffer(temp) source code
  buffer.writeLine(indentSpaces.repeat(indentLevel) & currentExpression)
  buffer.flushFile()

  # Check for indent and trigger it
  if currentExpression.hasIndentTrigger():
    # Already indented once skipping
    if not sessionNoAutoIndent or not previouslyIndented:
      indentLevel += 1
      previouslyIndented = true

  # Don't run yet if still on indent
  if indentLevel != 0:
    # Skip indent for first line
    let n = if currentExpression.hasIndentTrigger(): 1 else: 0
    tempIndentCode &= indentSpaces.repeat(indentLevel-n) &
    currentExpression & "\n"
    when promptHistory:
      # Add in indents to our history
      if tempIndentCode.len > 0:
        noiser.historyAdd(indentSpaces.repeat(indentLevel-n) & currentExpression)
    return

  # Compile buffer
  let (output, status) = compileCode()

  when promptHistory:
    if currentExpression.len > 0:
      noiser.historyAdd(currentExpression)

  # Succesful compilation, expression is valid
  if status == 0:
    compilationSuccess(currentExpression, output)
    if "echo" in currentExpression:
      # Roll back echoes
      bufferRestoreValidCode()
  # Maybe trying to echo value?
  elif "has to be discarded" in output and indentLevel == 0: #
    bufferRestoreValidCode()

    # Save the current expression as an echo
    currentExpression = if config.getSectionValue("Style", "showTypes") == "True":
        fmt"""echo $({currentExpression}) & " == " & "type " & $(type({currentExpression}))"""
      else:
        fmt"""echo $({currentExpression})"""
    buffer.writeLine(currentExpression)
    buffer.flushFile()

    # Don't run yet if still on indent
    if indentLevel != 0:
      # Skip indent for first line
      let n = if currentExpression.hasIndentTrigger(): 1 else: 0
      tempIndentCode &= indentSpaces.repeat(indentLevel-n) &
        currentExpression & "\n"
      when promptHistory:
        # Add in indents to our history
        if tempIndentCode.len > 0:
          noiser.historyAdd(indentSpaces.repeat(indentLevel-n) & currentExpression)

    let (echo_output, echo_status) = compileCode()
    if echo_status == 0:
      compilationSuccess(currentExpression, echo_output)
    else:
      # Show any errors in echoing the statement
      indentLevel = 0
      showError(echo_output)
      # Roll back to not include the temporary echo line
      bufferRestoreValidCode()

    # Roll back to not include the temporary echo line
    bufferRestoreValidCode()
  else:
    # Write back valid code to buffer
    bufferRestoreValidCode()
    indentLevel = 0
    showError(output)

  # Clean up
  tempIndentCode = ""

proc initApp*(nim, srcFile: string, showHeader: bool, flags = "",
    rcFilePath = RcFilePath, showColor = true, noAutoIndent = false) =
  ## Initialize the ``app` variable.
  app = App(
      nim: nim,
      srcFile: srcFile,
      showHeader: showHeader,
      flags: flags,
      rcFile: rcFilePath,
      showColor: showColor,
      noAutoIndent: noAutoIndent
  )

proc main(nim = "nim", srcFile = "", showHeader = true,
          flags: seq[string] = @[], createRcFile = false,
          rcFilePath: string = RcFilePath, showTypes: bool = false,
          showColor: bool = true, noAutoIndent: bool = false
          ) =
  ## inim interpreter

  initApp(nim, srcFile, showHeader)
  if flags.len > 0:
    app.flags = " -d:" & join(@flags, " -d:")

  let shouldCreateRc = not existsorCreateDir(rcFilePath.splitPath.head) or not existsFile(rcFilePath) or createRcFile
  config = if shouldCreateRc: createRcFile(rcFilePath)
           else: loadConfig(rcFilePath)

  if app.showHeader: welcomeScreen()

  assert not isNil config
  when promptHistory:
    # When prompt history is enabled, we want to load history
    historyFile = if config.getSectionValue("History", "persistent") == "True":
                    ConfigDir / "history.nim"
                  else: tmpHistory
    discard noiser.historyLoad(historyFile)

  if config.getSectionValue("Style", "FakeshowColor") == "True":
    echo "Wtf?"
  # Force show types
  if showTypes:
    config.setSectionKey("Style", "showTypes", "True")

  # Force show color
  if not showColor or defined(NoColor):
    config.setSectionKey("Style", "showColor", "False")

  if noAutoIndent:
    # Still trigger indents but do not actually output any spaces,
    # useful when sending text to a terminal
    indentSpaces = ""
    sessionNoAutoIndent = noAutoIndent

  if srcFile.len > 0:
    doAssert(srcFile.fileExists, "cannot access " & srcFile)
    doAssert(srcFile.splitFile.ext == ".nim")
    let fileData = getFileData(srcFile)
    init(fileData) # Preload code into init
  else:
    init() # Clean init

  while true:
    let prompt = getPromptSymbol()
    noiser.setPrompt(prompt)

    doRepl()

when isMainModule:
  import cligen
  dispatch(main, short = {"flags": 'd'}, help = {
          "nim": "path to nim compiler",
          "srcFile": "nim script to preload/run",
          "showHeader": "show program info startup",
          "flags": "nim flags to pass to the compiler",
          "createRcFile": "force create an inimrc file. Overrides current inimrc file",
          "rcFilePath": "Change location of the inimrc file to use",
          "showTypes": "Show var types when printing var without echo",
          "showColor": "Color displayed text",
          "noAutoIndent": "Disable automatic indentation"
    })

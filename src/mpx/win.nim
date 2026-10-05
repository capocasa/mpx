# The one raw Win32 import layer for mpx. No other module declares Win32
# procs: they import this one and get std/winlean's basics re-exported
# (including its camelCase console/event/winsock pieces) alongside the
# ConPTY, startup-attribute, screen-buffer, thread and ioctlsocket pieces
# winlean lacks. Dynlib procs bind lazily, so a binary still starts on
# Windows 10 pre-1809 and fails only where ConPTY is actually used.

import std/winlean
export winlean

const
  kernel32 = "kernel32"
  ws2_32 = "ws2_32"

type
  HPCON* = Handle

  LPPROC_THREAD_ATTRIBUTE_LIST* = pointer

  STARTUPINFOEXW* = object
    StartupInfo*: STARTUPINFO
    lpAttributeList*: LPPROC_THREAD_ATTRIBUTE_LIST

  SMALL_RECT* = object
    Left*: SHORT
    Top*: SHORT
    Right*: SHORT
    Bottom*: SHORT

  CONSOLE_SCREEN_BUFFER_INFO* = object
    dwSize*: COORD
    dwCursorPosition*: COORD
    wAttributes*: uint16
    srWindow*: SMALL_RECT
    dwMaximumWindowSize*: COORD

  ThreadProc* = proc(lpParameter: pointer): DWORD {.stdcall, gcsafe.}

# ConPTY (kernel32, Windows 10 1809+)

proc CreatePseudoConsole*(size: COORD, hInput, hOutput: Handle,
                          dwFlags: DWORD, phPC: ptr HPCON): int32 {.
                          stdcall, dynlib: kernel32,
                          importc: "CreatePseudoConsole".}

proc ResizePseudoConsole*(hPC: HPCON, size: COORD): int32 {.
                          stdcall, dynlib: kernel32,
                          importc: "ResizePseudoConsole".}

proc ClosePseudoConsole*(hPC: HPCON) {.
                          stdcall, dynlib: kernel32,
                          importc: "ClosePseudoConsole".}

# Process spawn (kernel32)

proc InitializeProcThreadAttributeList*(
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST, dwAttributeCount: DWORD,
    dwFlags: DWORD, lpSize: ptr DWORD): WINBOOL {.
    stdcall, dynlib: kernel32, importc: "InitializeProcThreadAttributeList".}

proc UpdateProcThreadAttribute*(lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
                                dwFlags: DWORD, attribute: uint,
                                lpValue: pointer, cbSize: uint,
                                lpPreviousValue: pointer,
                                lpReturnSize: ptr uint): WINBOOL {.
                                stdcall, dynlib: kernel32,
                                importc: "UpdateProcThreadAttribute".}

proc DeleteProcThreadAttributeList*(lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST) {.
                          stdcall, dynlib: kernel32,
                          importc: "DeleteProcThreadAttributeList".}

# Console (kernel32). GetConsoleMode/SetConsoleMode/readConsoleInput and
# the ENABLE_ flags come from winlean; the screen-buffer query does not.

proc GetConsoleScreenBufferInfo*(
    hConsoleOutput: Handle,
    lpConsoleScreenBufferInfo: ptr CONSOLE_SCREEN_BUFFER_INFO): WINBOOL {.
    stdcall, dynlib: kernel32, importc: "GetConsoleScreenBufferInfo".}

# Events and threads (kernel32)

proc CreateThread*(lpThreadAttributes: ptr SECURITY_ATTRIBUTES,
                   dwStackSize: uint, lpStartAddress: ThreadProc,
                   lpParameter: pointer, dwCreationFlags: DWORD,
                   lpThreadId: ptr DWORD): Handle {.
                   stdcall, dynlib: kernel32, importc: "CreateThread".}

proc GetCurrentProcessId*(): DWORD {.
  stdcall, dynlib: kernel32, importc: "GetCurrentProcessId".}

# Process parent chain (kernel32 Toolhelp)

type
  PROCESSENTRY32W* = object
    dwSize*: DWORD
    cntUsage*: DWORD
    th32ProcessID*: DWORD
    th32DefaultHeapID*: ULONG_PTR
    th32ModuleID*: DWORD
    cntThreads*: DWORD
    th32ParentProcessID*: DWORD
    pcPriClassBase*: LONG
    dwFlags*: DWORD
    szExeFile*: array[260, Utf16Char]

proc createToolhelp32Snapshot*(dwFlags: DWORD, th32ProcessID: DWORD): Handle {.
  stdcall, dynlib: kernel32, importc: "CreateToolhelp32Snapshot".}

proc process32FirstW*(hSnapshot: Handle, lppe: ptr PROCESSENTRY32W): WINBOOL {.
  stdcall, dynlib: kernel32, importc: "Process32FirstW".}

proc process32NextW*(hSnapshot: Handle, lppe: ptr PROCESSENTRY32W): WINBOOL {.
  stdcall, dynlib: kernel32, importc: "Process32NextW".}

const
  TH32CS_SNAPPROCESS* = 0x00000002'i32

# Winsock (ws2_32): the event-select pair is in winlean, the nonblocking
# ioctl and the enum-reset that goes with event select are not.

proc ioctlsocket*(s: SocketHandle, cmd: clong, argp: ptr culong): cint {.
                   stdcall, dynlib: ws2_32, importc: "ioctlsocket".}

type
  WSANETWORKEVENTS* = object
    lNetworkEvents*: clong
    iErrorCode*: array[10, cint]

proc WSAEnumNetworkEvents*(s: SocketHandle, hEventObject: Handle,
                           lpNetworkEvents: ptr WSANETWORKEVENTS): cint {.
                           stdcall, dynlib: ws2_32,
                           importc: "WSAEnumNetworkEvents".}

proc htons*(a1: uint16): uint16 {.
               stdcall, dynlib: ws2_32, importc: "htons".}

const
  # Process creation. EXTENDED_STARTUPINFO_PRESENT must accompany any
  # STARTUPINFOEXW or the attribute list is ignored.
  EXTENDED_STARTUPINFO_PRESENT* = 0x00080000'i32
  CREATE_BREAKAWAY_FROM_JOB* = 0x01000000'i32
  CREATE_NEW_PROCESS_GROUP* = 0x00000200'i32
  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE* = 0x00020016'u

  # Pipe read errors meaning the far end is gone (EOF for our purposes)
  ERROR_BROKEN_PIPE* = 109'i32
  ERROR_NO_DATA* = 232'i32

  # Winsock nonblocking ioctl command
  FIONBIO* = clong(0x8004667)

  # Winsock socket types (winlean has AF_* but not SOCK_*)
  SOCK_STREAM* = 1'i32

proc initWinsock*() =
  ## WSAStartup is refcounted per process; one call at startup covers every
  ## socket mpx makes. 2.2 is the only version that has ever mattered.
  var data: WSAData
  if wsaStartup(0x0202'i16, addr data) != 0:
    raise newException(OSError, "WSAStartup failed: " & $getLastError())

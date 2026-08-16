/* ---------------------------------------------------------------------------
 * uFVS.exe - the native Windows launcher.
 *
 * Built as a GUI-subsystem program so a double-click never leaves a console
 * window behind. Everything it needs is resolved from the directory holding
 * this executable:
 *
 *   uFVS\
 *     uFVS.exe                 this program
 *     app\                     the Shiny application, including launch.R
 *     runtime\R\bin\Rscript.exe the private R runtime
 *     runtime\R-library\        the private package library
 *     fvs\                     the FVS engine and its DLLs
 *     resources\               BUILD_INFO.json, notices, docs
 *
 * It never consults PATH, the registry, R_HOME, or the caller's current
 * directory. Starting uFVS from a shortcut, from Explorer, or from a command
 * prompt in an unrelated folder all behave identically.
 *
 * Lifecycle: the R process is created inside a job object marked
 * KILL_ON_JOB_CLOSE, so when this launcher exits - normally, on error, or if it
 * is killed from Task Manager - R and any FVS worker processes it started are
 * torn down with it. No orphans.
 *
 * Build (MinGW-w64 gcc, as shipped with Rtools):
 *   gcc -O2 -municode -mwindows -o uFVS.exe ufvs_launcher.c -lws2_32
 * ------------------------------------------------------------------------- */

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <shellapi.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define UFVS_MUTEX_NAME  L"Local\\uFVS.SingleInstance"
#define START_TIMEOUT_SECONDS 120
#define PATH_MAX_W 32768

static wchar_t g_log_path[PATH_MAX_W];
static wchar_t g_server_log_path[PATH_MAX_W];
static wchar_t g_session_path[PATH_MAX_W];

/* --- logging --------------------------------------------------------------
 * Startup problems on another person's computer can only be diagnosed from a
 * log, so the launcher records what it resolved and what it ran. Logging must
 * never itself be a reason to fail, hence the silent returns.
 */
static void log_line(const wchar_t *format, ...)
{
    if (g_log_path[0] == L'\0') return;

    HANDLE handle = CreateFileW(g_log_path, FILE_APPEND_DATA, FILE_SHARE_READ,
                                NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (handle == INVALID_HANDLE_VALUE) return;

    wchar_t message[4096];
    va_list args;
    va_start(args, format);
    _vsnwprintf(message, 4095, format, args);
    message[4095] = L'\0';
    va_end(args);

    SYSTEMTIME now;
    GetLocalTime(&now);
    wchar_t line[4600];
    _snwprintf(line, 4599, L"%04d-%02d-%02d %02d:%02d:%02d  %s\r\n",
               now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
               now.wSecond, message);
    line[4599] = L'\0';

    /* UTF-8 on disk: a bundle path can contain any character a user's account
     * name can contain. */
    int bytes = WideCharToMultiByte(CP_UTF8, 0, line, -1, NULL, 0, NULL, NULL);
    if (bytes > 1) {
        char *utf8 = (char *)malloc((size_t)bytes);
        if (utf8 != NULL) {
            WideCharToMultiByte(CP_UTF8, 0, line, -1, utf8, bytes, NULL, NULL);
            DWORD written = 0;
            SetFilePointer(handle, 0, NULL, FILE_END);
            WriteFile(handle, utf8, (DWORD)(bytes - 1), &written, NULL);
            free(utf8);
        }
    }
    CloseHandle(handle);
}

/* Read the tail of the R output so the error dialog can show the actual
 * failure rather than a generic "it did not start". */
static void read_log_tail(const wchar_t *path, wchar_t *out, size_t out_chars)
{
    out[0] = L'\0';

    HANDLE handle = CreateFileW(path, GENERIC_READ,
                                FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (handle == INVALID_HANDLE_VALUE) return;

    LARGE_INTEGER size;
    if (!GetFileSizeEx(handle, &size)) { CloseHandle(handle); return; }

    const DWORD want = 3000;
    DWORD length = (size.QuadPart > (LONGLONG)want) ? want : (DWORD)size.QuadPart;
    if (length == 0) { CloseHandle(handle); return; }

    LARGE_INTEGER offset;
    offset.QuadPart = size.QuadPart - (LONGLONG)length;
    SetFilePointerEx(handle, offset, NULL, FILE_BEGIN);

    char *buffer = (char *)malloc((size_t)length + 1);
    if (buffer == NULL) { CloseHandle(handle); return; }

    DWORD got = 0;
    if (ReadFile(handle, buffer, length, &got, NULL) && got > 0) {
        buffer[got] = '\0';
        MultiByteToWideChar(CP_UTF8, 0, buffer, -1, out, (int)out_chars);
        out[out_chars - 1] = L'\0';
    }
    free(buffer);
    CloseHandle(handle);
}

/* --- error reporting ------------------------------------------------------
 * A GUI-subsystem program that exits on error simply vanishes. Always leave the
 * user with something readable and a path to the log.
 */
static void fail(const wchar_t *message)
{
    log_line(L"STARTUP FAILED: %s", message);

    wchar_t tail[4096];
    read_log_tail(g_server_log_path, tail, 4096);

    wchar_t body[9000];
    if (tail[0] != L'\0') {
        _snwprintf(body, 8999,
                   L"%s\r\n\r\nLast messages from uFVS:\r\n%s\r\nLog file:\r\n%s",
                   message, tail, g_log_path);
    } else {
        _snwprintf(body, 8999, L"%s\r\n\r\nLog file:\r\n%s", message, g_log_path);
    }
    body[8999] = L'\0';

    MessageBoxW(NULL, body, L"uFVS", MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
    ExitProcess(1);
}

/* --- paths ---------------------------------------------------------------- */

static void directory_of_executable(wchar_t *out, DWORD out_chars)
{
    DWORD length = GetModuleFileNameW(NULL, out, out_chars);
    if (length == 0 || length >= out_chars) {
        MessageBoxW(NULL, L"uFVS could not determine its own location.", L"uFVS",
                    MB_OK | MB_ICONERROR);
        ExitProcess(1);
    }
    for (DWORD i = length; i > 0; i--) {
        if (out[i - 1] == L'\\' || out[i - 1] == L'/') { out[i - 1] = L'\0'; return; }
    }
    out[0] = L'\0';
}

static void join_path(wchar_t *out, size_t out_chars, const wchar_t *base,
                      const wchar_t *leaf)
{
    _snwprintf(out, out_chars - 1, L"%s\\%s", base, leaf);
    out[out_chars - 1] = L'\0';
}

static BOOL path_exists(const wchar_t *path)
{
    return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}

static BOOL directory_exists(const wchar_t *path)
{
    DWORD attributes = GetFileAttributesW(path);
    return attributes != INVALID_FILE_ATTRIBUTES &&
           (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

/* Create a directory and every missing parent. */
static void make_directories(const wchar_t *path)
{
    wchar_t buffer[PATH_MAX_W];
    wcsncpy(buffer, path, PATH_MAX_W - 1);
    buffer[PATH_MAX_W - 1] = L'\0';

    for (size_t i = 1; buffer[i] != L'\0'; i++) {
        if (buffer[i] == L'\\') {
            buffer[i] = L'\0';
            CreateDirectoryW(buffer, NULL);
            buffer[i] = L'\\';
        }
    }
    CreateDirectoryW(buffer, NULL);
}

/* Per-user state: the application directory may be read-only, and on a shared
 * machine two accounts must not share a log or a session file. */
static void user_state_directory(wchar_t *out, size_t out_chars)
{
    wchar_t base[PATH_MAX_W];
    DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", base, PATH_MAX_W);
    if (length == 0 || length >= PATH_MAX_W) {
        length = GetEnvironmentVariableW(L"APPDATA", base, PATH_MAX_W);
    }
    if (length == 0 || length >= PATH_MAX_W) {
        length = GetEnvironmentVariableW(L"USERPROFILE", base, PATH_MAX_W);
    }
    if (length == 0 || length >= PATH_MAX_W) {
        wcsncpy(base, L"C:\\", PATH_MAX_W - 1);
        base[PATH_MAX_W - 1] = L'\0';
    }
    _snwprintf(out, out_chars - 1, L"%s\\uFVS", base);
    out[out_chars - 1] = L'\0';
}

/* --- localhost helpers ---------------------------------------------------- */

/* Ask Windows for a free loopback port by binding one and letting it go. The
 * gap between closing the socket and R binding it is small, and R falls back to
 * choosing its own port if this one is taken in between. */
static int choose_free_port(void)
{
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return 0;

    struct sockaddr_in address;
    ZeroMemory(&address, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = 0;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    int port = 0;
    if (bind(s, (struct sockaddr *)&address, sizeof(address)) == 0) {
        int length = (int)sizeof(address);
        if (getsockname(s, (struct sockaddr *)&address, &length) == 0) {
            port = (int)ntohs(address.sin_port);
        }
    }
    closesocket(s);
    return port;
}

/* A port that accepts a connection is not the same as a Shiny app that answers
 * a request, so this asks for the page and waits for an HTTP status line. */
static BOOL server_is_answering(int port)
{
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return FALSE;

    DWORD timeout = 3000;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout));
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&timeout, sizeof(timeout));

    struct sockaddr_in address;
    ZeroMemory(&address, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((unsigned short)port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    BOOL answered = FALSE;
    if (connect(s, (struct sockaddr *)&address, sizeof(address)) == 0) {
        const char *request =
            "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
        if (send(s, request, (int)strlen(request), 0) > 0) {
            char response[256];
            int got = recv(s, response, (int)sizeof(response) - 1, 0);
            if (got > 0) {
                response[got] = '\0';
                if (strncmp(response, "HTTP/1.", 7) == 0) answered = TRUE;
            }
        }
    }
    closesocket(s);
    return answered;
}

/* Pull "port": <number> out of the session file R writes once it has bound. */
static int port_from_session_file(const wchar_t *path)
{
    HANDLE handle = CreateFileW(path, GENERIC_READ,
                                FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (handle == INVALID_HANDLE_VALUE) return 0;

    char buffer[4096];
    DWORD got = 0;
    int port = 0;
    if (ReadFile(handle, buffer, (DWORD)sizeof(buffer) - 1, &got, NULL) && got > 0) {
        buffer[got] = '\0';
        const char *found = strstr(buffer, "\"port\"");
        if (found != NULL) {
            found += 6;
            while (*found != '\0' && (*found == ':' || *found == ' ' ||
                                      *found == '\t' || *found == '[' ||
                                      *found == '\r' || *found == '\n')) {
                found++;
            }
            port = atoi(found);
        }
    }
    CloseHandle(handle);
    if (port < 1 || port > 65535) return 0;
    return port;
}

static void open_in_browser(int port)
{
    wchar_t url[64];
    _snwprintf(url, 63, L"http://127.0.0.1:%d/", port);
    url[63] = L'\0';

    /* UFVS_NO_BROWSER lets the build tests drive this launcher exactly as a user
     * would without a browser window appearing on the build machine. */
    wchar_t suppress[8];
    if (GetEnvironmentVariableW(L"UFVS_NO_BROWSER", suppress, 8) > 0 &&
        wcscmp(suppress, L"1") == 0) {
        log_line(L"browser suppressed by UFVS_NO_BROWSER; serving at %s", url);
        return;
    }
    log_line(L"opening %s", url);

    HINSTANCE result = ShellExecuteW(NULL, L"open", url, NULL, NULL, SW_SHOWNORMAL);
    if ((INT_PTR)result <= 32) {
        log_line(L"the default browser could not be opened (code %d)", (int)(INT_PTR)result);
        wchar_t message[256];
        _snwprintf(message, 255,
                   L"uFVS is running, but the default browser could not be opened.\r\n\r\n"
                   L"Open this address manually:\r\n%s", url);
        message[255] = L'\0';
        MessageBoxW(NULL, message, L"uFVS", MB_OK | MB_ICONINFORMATION);
    }
}

/* --- main ----------------------------------------------------------------- */

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command_line,
                    int show)
{
    (void)instance; (void)previous; (void)command_line; (void)show;

    wchar_t state_dir[PATH_MAX_W];
    user_state_directory(state_dir, PATH_MAX_W);
    wchar_t log_dir[PATH_MAX_W];
    join_path(log_dir, PATH_MAX_W, state_dir, L"logs");
    make_directories(log_dir);
    join_path(g_log_path, PATH_MAX_W, log_dir, L"launcher.log");
    join_path(g_server_log_path, PATH_MAX_W, log_dir, L"server.log");

    wchar_t runtime_state[PATH_MAX_W];
    join_path(runtime_state, PATH_MAX_W, state_dir, L"runtime");
    make_directories(runtime_state);
    join_path(g_session_path, PATH_MAX_W, runtime_state, L"session.json");

    log_line(L"---- uFVS launcher starting ----");

    wchar_t home[PATH_MAX_W];
    directory_of_executable(home, PATH_MAX_W);
    log_line(L"installation: %s", home);

    wchar_t app_dir[PATH_MAX_W], runtime_dir[PATH_MAX_W], library_dir[PATH_MAX_W];
    wchar_t fvs_dir[PATH_MAX_W], resources_dir[PATH_MAX_W];
    wchar_t rscript[PATH_MAX_W], launch_script[PATH_MAX_W];

    join_path(app_dir, PATH_MAX_W, home, L"app");
    join_path(runtime_dir, PATH_MAX_W, home, L"runtime");
    join_path(library_dir, PATH_MAX_W, runtime_dir, L"R-library");
    join_path(fvs_dir, PATH_MAX_W, home, L"fvs");
    join_path(resources_dir, PATH_MAX_W, home, L"resources");
    join_path(rscript, PATH_MAX_W, runtime_dir, L"R\\bin\\Rscript.exe");
    join_path(launch_script, PATH_MAX_W, app_dir, L"launch.R");

    if (!directory_exists(app_dir) || !path_exists(launch_script)) {
        fail(L"The uFVS application files are missing.\r\n\r\n"
             L"Extract the whole uFVS ZIP before running uFVS.exe. Running it "
             L"from inside the ZIP viewer does not work.");
    }
    if (!path_exists(rscript)) {
        fail(L"The bundled R runtime is missing.\r\n\r\n"
             L"Extract the whole uFVS ZIP before running uFVS.exe. uFVS does not "
             L"use any copy of R that may be installed on this computer.");
    }

    /* --- one instance at a time -------------------------------------------
     * A second double-click should show the window that is already open. */
    HANDLE instance_mutex = CreateMutexW(NULL, TRUE, UFVS_MUTEX_NAME);
    if (instance_mutex != NULL && GetLastError() == ERROR_ALREADY_EXISTS) {
        log_line(L"another instance is already running");
        WSADATA probe_winsock;
        if (WSAStartup(MAKEWORD(2, 2), &probe_winsock) == 0) {
            int running_port = port_from_session_file(g_session_path);
            if (running_port > 0 && server_is_answering(running_port)) {
                open_in_browser(running_port);
                WSACleanup();
                ExitProcess(0);
            }
            WSACleanup();
        }
        /* The mutex is held by a process that is no longer serving: most likely
         * a crash. Say so instead of starting a second, competing server. */
        fail(L"uFVS is already running, but it is not responding.\r\n\r\n"
             L"Close it from Task Manager (look for uFVS.exe and Rscript.exe) "
             L"and start uFVS again.");
    }

    WSADATA winsock_data;
    if (WSAStartup(MAKEWORD(2, 2), &winsock_data) != 0) {
        fail(L"uFVS could not initialise Windows networking.");
    }

    DeleteFileW(g_session_path);

    /* --- describe the layout to R ------------------------------------------
     * Set in this process so the child simply inherits them; that avoids
     * building an environment block by hand and getting the ordering wrong. */
    int port = choose_free_port();
    wchar_t port_text[16];
    _snwprintf(port_text, 15, L"%d", port);
    port_text[15] = L'\0';
    log_line(L"selected port %s", port_text);

    SetEnvironmentVariableW(L"UFVS_RELEASE", L"1");
    SetEnvironmentVariableW(L"UFVS_DESKTOP", L"1");
    SetEnvironmentVariableW(L"UFVS_APP_DIR", app_dir);
    SetEnvironmentVariableW(L"UFVS_RUNTIME_DIR", runtime_dir);
    SetEnvironmentVariableW(L"UFVS_LIBRARY_DIR", library_dir);
    SetEnvironmentVariableW(L"UFVS_FVS_DIR", fvs_dir);
    SetEnvironmentVariableW(L"UFVS_RESOURCES_DIR", resources_dir);
    SetEnvironmentVariableW(L"UFVS_SESSION_FILE", g_session_path);
    SetEnvironmentVariableW(L"UFVS_LAUNCH_BROWSER", L"0");
    SetEnvironmentVariableW(L"UFVS_PORT", port_text);
    SetEnvironmentVariableW(L"R_LIBS_USER", library_dir);
    SetEnvironmentVariableW(L"R_LIBS_SITE", L"");
    /* R_HOME must not leak in from a system R installation. */
    SetEnvironmentVariableW(L"R_HOME", NULL);

    /* --- keep the whole tree on a leash ------------------------------------
     * Assigning R to this job means Windows kills R, and any FVS worker R
     * started, the moment the last handle to the job closes - including when
     * this launcher is killed rather than closed. */
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (job != NULL) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
        ZeroMemory(&limits, sizeof(limits));
        limits.BasicLimitInformation.LimitFlags =
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                                sizeof(limits));
    }

    /* R's own output is the diagnostic record when something goes wrong. */
    SECURITY_ATTRIBUTES inheritable;
    inheritable.nLength = sizeof(inheritable);
    inheritable.lpSecurityDescriptor = NULL;
    inheritable.bInheritHandle = TRUE;

    HANDLE server_log = CreateFileW(g_server_log_path,
                                    GENERIC_WRITE, FILE_SHARE_READ,
                                    &inheritable, CREATE_ALWAYS,
                                    FILE_ATTRIBUTE_NORMAL, NULL);

    /* R reads standard input on startup. Give it the null device rather than an
     * invalid handle, which some CRT builds treat as a read error. */
    HANDLE null_input = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ,
                                    &inheritable, OPEN_EXISTING,
                                    FILE_ATTRIBUTE_NORMAL, NULL);

    wchar_t command[PATH_MAX_W];
    _snwprintf(command, PATH_MAX_W - 1, L"\"%s\" \"%s\"", rscript, launch_script);
    command[PATH_MAX_W - 1] = L'\0';
    log_line(L"starting: %s", command);

    STARTUPINFOW startup;
    ZeroMemory(&startup, sizeof(startup));
    startup.cb = sizeof(startup);
    if (server_log != INVALID_HANDLE_VALUE) {
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdOutput = server_log;
        startup.hStdError = server_log;
        startup.hStdInput = null_input;
    }

    PROCESS_INFORMATION process;
    ZeroMemory(&process, sizeof(process));

    /* CREATE_NO_WINDOW keeps R headless; CREATE_SUSPENDED lets the job take
     * ownership before any child of R can be spawned outside it. */
    BOOL started = CreateProcessW(rscript, command, NULL, NULL, TRUE,
                                  CREATE_NO_WINDOW | CREATE_SUSPENDED,
                                  NULL, app_dir, &startup, &process);
    if (!started) {
        log_line(L"CreateProcess failed with error %lu", GetLastError());
        fail(L"uFVS could not start its bundled R runtime.");
    }
    if (job != NULL) AssignProcessToJobObject(job, process.hProcess);
    ResumeThread(process.hThread);
    if (server_log != INVALID_HANDLE_VALUE) CloseHandle(server_log);
    if (null_input != INVALID_HANDLE_VALUE) CloseHandle(null_input);

    /* --- wait for the server, then open the browser ------------------------ */
    int ready_port = 0;
    for (int elapsed = 0; elapsed < START_TIMEOUT_SECONDS; elapsed++) {
        if (WaitForSingleObject(process.hProcess, 0) == WAIT_OBJECT_0) {
            fail(L"uFVS stopped while starting up.");
        }
        /* Prefer the port R reports: if the pre-chosen one was taken in the
         * meantime, R will have bound a different one. */
        int reported = port_from_session_file(g_session_path);
        int candidate = (reported > 0) ? reported : port;
        if (candidate > 0 && server_is_answering(candidate)) {
            ready_port = candidate;
            break;
        }
        Sleep(1000);
    }

    if (ready_port == 0) {
        fail(L"uFVS did not finish starting up in time.");
    }
    log_line(L"server ready on port %d", ready_port);
    open_in_browser(ready_port);

    /* Hold the job open for as long as uFVS runs. R exits when the last browser
     * window closes; closing the job then removes anything it left behind. */
    WaitForSingleObject(process.hProcess, INFINITE);

    DWORD status = 0;
    GetExitCodeProcess(process.hProcess, &status);
    log_line(L"uFVS exited with status %lu", status);

    DeleteFileW(g_session_path);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    if (job != NULL) CloseHandle(job);
    if (instance_mutex != NULL) {
        ReleaseMutex(instance_mutex);
        CloseHandle(instance_mutex);
    }
    WSACleanup();
    log_line(L"---- uFVS launcher finished ----");
    return 0;
}

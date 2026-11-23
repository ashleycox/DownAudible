#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

#define PATH_BUFFER 32768

static int launch_error(const wchar_t *message)
{
    MessageBoxW(NULL, message, L"DownAudible", MB_OK | MB_ICONERROR);
    return 1;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR arguments, int show)
{
    static wchar_t directory[PATH_BUFFER];
    static wchar_t resources[PATH_BUFFER];
    static wchar_t python[PATH_BUFFER];
    static wchar_t python_gui[PATH_BUFFER];
    static wchar_t command[PATH_BUFFER];
    static wchar_t running_path[PATH_BUFFER];
    wchar_t launcher_pid[16];
    wchar_t *separator;
    DWORD length;
    DWORD status = 1;
    HANDLE running;
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};

    (void)instance;
    (void)previous;
    (void)show;
    length = GetModuleFileNameW(NULL, directory, PATH_BUFFER);
    if (length == 0 || length >= PATH_BUFFER)
        return launch_error(L"DownAudible could not locate its installation directory.");
    separator = wcsrchr(directory, L'\\');
    if (!separator)
        return launch_error(L"DownAudible could not locate its installation directory.");
    *separator = L'\0';

    if (swprintf(resources, PATH_BUFFER, L"%ls\\resources", directory) < 0 ||
        swprintf(python, PATH_BUFFER, L"%ls\\python\\python.exe", directory) < 0 ||
        swprintf(python_gui, PATH_BUFFER, L"%ls\\python\\pythonw.exe", directory) < 0 ||
        swprintf(running_path, PATH_BUFFER, L"%ls\\.running", directory) < 0 ||
        swprintf(command, PATH_BUFFER, L"\"%ls\" -B -X utf8 -m downaudible_windows %ls", python_gui, arguments) < 0)
        return launch_error(L"DownAudible’s launch command is too long.");

    swprintf(launcher_pid, sizeof(launcher_pid) / sizeof(*launcher_pid), L"%lu", GetCurrentProcessId());
    if (!SetEnvironmentVariableW(L"DOWNAUDIBLE_RESOURCES", resources) ||
        !SetEnvironmentVariableW(L"DOWNAUDIBLE_PYTHON", python) ||
        !SetEnvironmentVariableW(L"DOWNAUDIBLE_LAUNCHER_PID", launcher_pid))
        return launch_error(L"DownAudible could not configure its private runtime.");

    /* A read handle blocks deletion while Python is running; read-only portable folders still work. */
    running = CreateFileW(running_path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_ALWAYS,
                          FILE_ATTRIBUTE_HIDDEN, NULL);
    startup.cb = sizeof(startup);
    if (!CreateProcessW(python_gui, command, NULL, NULL, FALSE, 0, NULL, directory, &startup, &process)) {
        if (running != INVALID_HANDLE_VALUE)
            CloseHandle(running);
        return launch_error(L"DownAudible could not start Python. Keep the launcher with the python and resources folders.");
    }

    CloseHandle(process.hThread);
    if (WaitForSingleObject(process.hProcess, INFINITE) == WAIT_OBJECT_0)
        GetExitCodeProcess(process.hProcess, &status);
    CloseHandle(process.hProcess);
    if (running != INVALID_HANDLE_VALUE)
        CloseHandle(running);
    return (int)status;
}

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <shellapi.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

bool IsRunningAsAdmin() {
  BOOL is_admin = FALSE;
  PSID admin_group = nullptr;

  SID_IDENTIFIER_AUTHORITY nt_authority = SECURITY_NT_AUTHORITY;
  if (!AllocateAndInitializeSid(&nt_authority, 2, SECURITY_BUILTIN_DOMAIN_RID,
                               DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0,
                               &admin_group)) {
    return false;
  }

  if (!CheckTokenMembership(nullptr, admin_group, &is_admin)) {
    is_admin = FALSE;
  }

  if (admin_group) {
    FreeSid(admin_group);
  }

  return is_admin == TRUE;
}

std::wstring GetSelfExePath() {
  DWORD size = MAX_PATH;

  for (;;) {
    std::wstring buffer;
    buffer.resize(size);

    DWORD written = GetModuleFileNameW(nullptr, buffer.data(), size);
    if (written == 0) {
      return L"";
    }

    // If the buffer was big enough, Windows returns the length not including the null terminator.
    if (written < size - 1) {
      buffer.resize(written);
      return buffer;
    }

    size *= 2;
  }
}

std::wstring GetFullCommandLineArgs() {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv || argc <= 1) {
    if (argv) {
      LocalFree(argv);
    }
    return L"";
  }

  std::wstring args;
  for (int i = 1; i < argc; i++) {
    if (!args.empty()) {
      args += L" ";
    }
    args += L"\"";
    args += argv[i];
    args += L"\"";
  }

  LocalFree(argv);
  return args;
}

void RelaunchAsAdminAndExit() {
  const std::wstring exe_path = GetSelfExePath();
  const std::wstring args = GetFullCommandLineArgs();

  if (exe_path.empty()) {
    ExitProcess(EXIT_FAILURE);
  }

  HINSTANCE result =
      ShellExecuteW(nullptr, L"runas", exe_path.c_str(),
                    args.empty() ? nullptr : args.c_str(), nullptr, SW_SHOWNORMAL);

  // If the user cancels UAC or the launch fails, just exit.
  // ShellExecuteW returns <= 32 on error.
  if ((INT_PTR)result <= 32) {
    ExitProcess(EXIT_FAILURE);
  }

  ExitProcess(EXIT_SUCCESS);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Request admin rights on startup (needed for bcdedit/shutdown).
  // If not elevated, relaunch with UAC prompt and exit.
  if (!IsRunningAsAdmin()) {
    RelaunchAsAdminAndExit();
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"hypervisorfix", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

#include "window_frame_storage.h"

#include <shlobj.h>

#include <fstream>
#include <sstream>
#include <string>

namespace {

constexpr int kMinWidth = 480;
constexpr int kMinHeight = 360;

std::wstring GetStoragePath() {
  wchar_t* path = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &path))) {
    return L"";
  }
  std::wstring storage = std::wstring(path) + L"\\DirectDrop\\window_frame.txt";
  CoTaskMemFree(path);
  return storage;
}

bool EnsureParentDirectory(const std::wstring& file_path) {
  const size_t pos = file_path.find_last_of(L"\\/");
  if (pos == std::wstring::npos) {
    return false;
  }
  const std::wstring dir = file_path.substr(0, pos);
  return CreateDirectoryW(dir.c_str(), nullptr) || GetLastError() == ERROR_ALREADY_EXISTS;
}

bool IsRectValid(const RECT& rect) {
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  return width >= kMinWidth && height >= kMinHeight;
}

bool IsRectVisible(const RECT& rect) {
  return MonitorFromRect(&rect, MONITOR_DEFAULTTONULL) != nullptr;
}

}  // namespace

namespace WindowFrameStorage {

void Restore(HWND hwnd) {
  if (!hwnd) {
    return;
  }

  const std::wstring path = GetStoragePath();
  if (path.empty()) {
    return;
  }

  std::wifstream input(path);
  if (!input.is_open()) {
    return;
  }

  LONG left = 0;
  LONG top = 0;
  LONG right = 0;
  LONG bottom = 0;
  input >> left >> top >> right >> bottom;
  if (!input.good()) {
    return;
  }

  RECT rect{left, top, right, bottom};
  if (!IsRectValid(rect) || !IsRectVisible(rect)) {
    return;
  }

  WINDOWPLACEMENT placement{};
  placement.length = sizeof(WINDOWPLACEMENT);
  if (!GetWindowPlacement(hwnd, &placement)) {
    return;
  }

  placement.showCmd = SW_SHOWNORMAL;
  placement.rcNormalPosition = rect;
  SetWindowPlacement(hwnd, &placement);
}

void Save(HWND hwnd) {
  if (!hwnd || !IsWindow(hwnd) || IsIconic(hwnd)) {
    return;
  }

  WINDOWPLACEMENT placement{};
  placement.length = sizeof(WINDOWPLACEMENT);
  if (!GetWindowPlacement(hwnd, &placement)) {
    return;
  }

  if (placement.showCmd == SW_SHOWMINIMIZED) {
    return;
  }

  const RECT& rect = placement.rcNormalPosition;
  if (!IsRectValid(rect)) {
    return;
  }

  const std::wstring path = GetStoragePath();
  if (path.empty() || !EnsureParentDirectory(path)) {
    return;
  }

  std::wofstream output(path, std::ios::trunc);
  if (!output.is_open()) {
    return;
  }

  output << rect.left << L" " << rect.top << L" " << rect.right << L" "
         << rect.bottom;
}

}  // namespace WindowFrameStorage

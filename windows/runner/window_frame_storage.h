#ifndef RUNNER_WINDOW_FRAME_STORAGE_H_
#define RUNNER_WINDOW_FRAME_STORAGE_H_

#include <windows.h>

namespace WindowFrameStorage {

// Kayıtlı pencere boyutu/konumunu uygular.
void Restore(HWND hwnd);

// Geçerli pencere durumunu diske yazar.
void Save(HWND hwnd);

}  // namespace WindowFrameStorage

#endif  // RUNNER_WINDOW_FRAME_STORAGE_H_

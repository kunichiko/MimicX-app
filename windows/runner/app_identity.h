#pragma once

// アプリのウィンドウタイトル / 表示名。
// デフォルトはローカル開発用 (dev) で、リリース版とは別タイトルで動作することで
// 同時起動しても区別がつくようにする。
// GitHub Actions のリリースビルドは、ビルド前にこのファイルを prod 値に上書きする
// (.github/workflows/release-build.yml の "Use prod identity" ステップ参照)。
#define APP_DISPLAY_NAME L"Mimic X Dev"

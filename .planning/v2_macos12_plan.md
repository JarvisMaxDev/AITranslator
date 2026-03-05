# V2: Поддержка macOS 12 + Intel ✅

## Статус: Завершено, замерджено в main

**Версия:** 2.0.0  
**Ветка:** `v2/macos12-intel` → merged into `main`

## Что изменено

### 1. project.yml

- `deploymentTarget.macOS`: `14.0` → `12.0`
- `MACOSX_DEPLOYMENT_TARGET`: `14.0` → `12.0`

### 2. AITranslatorApp.swift

- Убрана `Window(id: "settings")` scene — настройки через AppDelegate NSWindow
- Убрана `.defaultSize()`, `.windowResizability()`, `.defaultPosition()`
- Заголовок окна: `macOS Translator` → `AI Translator`

### 3. AppDelegate.swift

- Добавлен NSWindow handler для настроек (`showSettingsWindow()`)
- NotificationCenter observer для `.openSettings` notification
- Работает на всех версиях macOS (12+)

### 4. TranslatorView.swift

- Убран `@Environment(\.openWindow)` (macOS 13+)
- Кнопка ⚙️ и Cmd+, → `post(.openSettings)` notification

### 5. SettingsView.swift

- `SMAppService` обёрнут в `#available(macOS 13)`
- Toggle «Запускать при входе» скрыт на macOS 12

### 6. Мелкие фиксы совместимости

- `.fontWeight()` → `.font().weight()` (LanguageSelectorView, ConsoleView)
- `.scrollContentBackground(.hidden)` → `.background(Color.clear)` (TranslationPanel)

### 7. CI Workflow

- `ARCHS="arm64 x86_64"`, `ONLY_ACTIVE_ARCH=NO`

## Нужно проверить

- [ ] Тест на реальном Intel Mac
- [ ] Тест на macOS 12 (виртуалка или реальная машина)

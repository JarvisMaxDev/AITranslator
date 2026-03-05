# V2: Поддержка macOS 12 + Intel

## Цель

Опустить deployment target с macOS 14.0 до macOS 12.0 и добавить Universal Binary (arm64 + x86_64) для поддержки Intel Mac.

## Анализ совместимости

### ✅ Уже совместимо с macOS 12

- `async/await`, `Task {}` — Swift concurrency (macOS 12 с Xcode 13.2+)
- `NLLanguageRecognizer` — macOS 10.14+
- `AVSpeechSynthesizer` — macOS 10.14+
- `AXUIElement` — macOS 10.0+
- `CGEvent` — macOS 10.4+
- `URLSession.data(for:)` — macOS 12+
- `NSStatusItem`, `NSMenu` — macOS 10.0+
- `@StateObject`, `@Published` — macOS 10.15+ (Combine)
- `GroupBox`, `Toggle`, `Picker` — macOS 10.15+
- `.onChange(of:) { newValue in }` — macOS 12+ (старый синтаксис, ОК)

### ⚠️ Требует #available fallback (macOS 13+)

| API                          | Используется в        | Fallback                                                     |
| ---------------------------- | --------------------- | ------------------------------------------------------------ |
| `SMAppService.mainApp`       | SettingsView.swift    | `LSSharedFileListInsertItemURL` (deprecated) или `launchctl` |
| `Window(id:)` scene          | AITranslatorApp.swift | `NSWindow` + `NSHostingView` (ручное создание)               |
| `@Environment(\.openWindow)` | TranslatorView.swift  | NotificationCenter → NSWindow                                |
| `.windowResizability()`      | AITranslatorApp.swift | Убрать (не критично)                                         |
| `.defaultSize()`             | AITranslatorApp.swift | `.frame()` внутри view                                       |
| `.defaultPosition()`         | AITranslatorApp.swift | `window.center()`                                            |

### 🔧 Universal Binary (Intel + Apple Silicon)

- Добавить `ARCHS = "arm64 x86_64"` в Build Settings
- Или `ONLY_ACTIVE_ARCH = NO` для Release
- CI workflow: добавить `destination 'arch=x86_64'` или `ARCHS="arm64 x86_64"`

## Предлагаемые изменения

### 1. Xcode Project

- `MACOSX_DEPLOYMENT_TARGET` = `12.0`
- `ARCHS` = `arm64 x86_64` (Universal Binary)

### 2. AITranslatorApp.swift

- Обернуть `Window(id:)` в `if #available(macOS 13, *)`
- Для macOS 12: использовать NSWindow через AppDelegate для settings

### 3. TranslatorView.swift

- Обернуть `@Environment(\.openWindow)` в `if #available(macOS 13, *)`
- Для macOS 12: NotificationCenter → AppDelegate → NSWindow

### 4. SettingsView.swift

- `SMAppService`: `if #available(macOS 13, *) { ... }` + скрыть toggle на macOS 12
- Или: использовать `LoginItem` helper app (сложнее)

### 5. CI Workflow

- `xcodebuild ... ARCHS="arm64 x86_64"`
- Тестировать на macOS-latest (ARM) — Intel собирается кросс-компиляцией

## Риски

> [!WARNING]
> Основное ограничение: **нет возможности протестировать на реальном Intel Mac и macOS 12**. Можем только убедиться что код компилируется. Рантайм-тестирование потребует виртуалку или реальный Intel Mac.

> [!IMPORTANT]
> `Window(id:)` — центральная архитектурная зависимость. На macOS 12 окно настроек нужно создавать вручную через NSWindow. Это увеличивает сложность кода.

## Порядок выполнения

1. Изменить deployment target и архитектуру
2. Собрать — увидеть все ошибки компиляции
3. Поочерёдно исправить каждую ошибку с `#available` fallback
4. Протестировать сборку
5. Обновить CI workflow

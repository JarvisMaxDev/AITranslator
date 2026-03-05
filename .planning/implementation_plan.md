# AI Translator — План и документация проекта

Нативное macOS-приложение (Swift/SwiftUI) для перевода текста через AI с глобальным хоткеем.

---

## Статус проекта

### ✅ Реализовано (MVP)

| Функция                  | Детали                                                                 |
| ------------------------ | ---------------------------------------------------------------------- |
| Двухпанельный переводчик | Источник → перевод, TextEditor с placeholder                           |
| **4 AI-провайдера**      | Qwen, Claude, OpenAI, Gemini                                           |
| Qwen + Claude OAuth      | Device code flow (Qwen), PKCE + localhost callback (Claude)            |
| OpenAI + Gemini          | API key auth, OpenAI-совместимый формат                                |
| Загрузка моделей         | `/v1/models` API + hardcoded fallback                                  |
| Настройки                | Нативное окно, выбор модели, Save/Cancel (всегда видны)                |
| Выбор языка              | Popover + поиск + флаги + недавние языки                               |
| Авто-определение языка   | `NLLanguageRecognizer`, отображение "(auto)"                           |
| ⇄ Swap языков/текстов    | Работает с Auto Detect                                                 |
| Глобальный хоткей        | ⌘⇧C (настраиваемый через HotkeyRecorder)                               |
| Auto-refresh токенов     | Qwen (`x-www-form-urlencoded`) + Claude (JSON)                         |
| Cmd+Enter                | Отправка перевода                                                      |
| Понятные ошибки          | Локализованные сообщения                                               |
| Локализация RU/EN        | По языку системы + переключатель в настройках                          |
| Консоль отладки          | AppLogger + ConsoleView (⌘L), JSON payload/response                    |
| **Стриминг перевода**    | SSE, токен за токеном, анимированный курсор                            |
| **OCR**                  | Cmd+V картинки или загрузка файла → Vision → перевод                   |
| **Размер шрифта**        | 10-24pt, Cmd+/Cmd-, сохраняется в UserDefaults                         |
| **Outlook Cmd+C**        | CGEvent combinedSessionState + AppleScript fallback                    |
| **Undo/Redo**            | Cmd+Z / Cmd+Shift+Z для текстовых изменений                            |
| **TTS**                  | Системный TTS, автовыбор лучшего голоса (Premium > Enhanced > Default) |
| **Автозагрузка**         | SMAppService, toggle в настройках                                      |
| **Авто-перевод**         | Автоматический перевод при смене целевого языка                        |

### ✅ CI/CD (полностью автоматизировано)

| Функция                   | Детали                                                              |
| ------------------------- | ------------------------------------------------------------------- |
| **Semantic release**      | Анализ conventional commits → auto patch/minor/major                |
| **Code signing**          | `AITranslator Dev` self-signed cert, импорт в CI из secrets         |
| **Auto-versioning**       | Git tag → `MARKETING_VERSION` + commit count build number           |
| **Auto-changelog**        | Группировка по типу (feat/fix/perf/refactor)                        |
| **GitHub Release**        | Автосоздание с DMG + changelog                                      |
| **Homebrew Cask**         | Автообновление homebrew-tap через git clone+push                    |
| **Accessibility persist** | Code signing сохраняет Accessibility permissions между обновлениями |

### 📋 Следующие задачи

- [ ] Кастомный OpenAI-совместимый эндпоинт (Ollama, LM Studio, OpenRouter)
- [ ] История переводов

### 💤 Может быть потом

- [ ] Перевод документов (.pdf/.docx с сохранением форматирования — требует pymupdf)

---

## Как работает релиз

```
git commit -m "fix: описание"  →  auto patch (1.1.5 → 1.1.6)
git commit -m "feat: описание" →  auto minor (1.1.6 → 1.2.0)
git commit -m "feat!: описание"→  auto major (1.2.0 → 2.0.0)
git commit -m "ci: описание"   →  пропуск (без релиза)
git push origin main            →  CI всё делает автоматически
```

---

## Архитектура

```
AITranslator/
├── App/              # AITranslatorApp, AppDelegate (хоткей, статус-бар, Accessibility)
├── Models/           # Provider, Language, Translation
├── Services/
│   ├── Providers/    # AIProvider protocol + Qwen/Anthropic/OpenAI/Gemini
│   ├── Auth/         # OAuthService, KeychainService, LocalCallbackServer
│   ├── AppLogger     # Singleton логгер
│   ├── ModelService  # Загрузка моделей с API
│   ├── OCRService    # Vision framework OCR
│   └── TranslationService # Оркестратор перевода
├── ViewModels/       # TranslatorViewModel, SettingsViewModel
├── Views/            # TranslatorView, SettingsView, Console, Components
└── Resources/        # Info.plist, en/ru Localizable.strings, Entitlements
```

## Ключевые решения

| Решение                  | Почему                                                                              |
| ------------------------ | ----------------------------------------------------------------------------------- |
| **Токены в файлах**      | `~/.aitranslator/credentials/` — без Keychain-промптов                              |
| **Self-signed cert**     | `AITranslator Dev` (CN=AITranslator Dev, O=JarvisMaxDev) — стабильный Accessibility |
| **TAP_GITHUB_TOKEN**     | PAT для cross-repo push в homebrew-tap                                              |
| **xcodegen**             | `project.yml` → автогенерация `.xcodeproj`                                          |
| **Conventional commits** | `fix:/feat:/ci:` → автоматический семантик-релиз                                    |

## Как продолжить разработку

1. **Сборка**: `xcodegen generate && xcodebuild -scheme AITranslator build`
2. **Релиз**: просто `git push origin main` с conventional commit
3. **Добавление провайдера**: `XxxProvider.swift` (протокол `AIProvider`) → добавить в `ProviderType` → `TranslationService`
4. **Локализация**: оба `Localizable.strings`
5. **Отладка**: консоль ⌘L

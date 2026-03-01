# AI Translator — План и документация проекта

Нативное macOS-приложение (Swift/SwiftUI) для перевода текста через AI с глобальным хоткеем.

---

## Статус проекта

### ✅ Реализовано (MVP)

| Функция | Детали |
|---------|--------|
| Двухпанельный переводчик | Источник → перевод, TextEditor с placeholder |
| **4 AI-провайдера** | Qwen, Claude, OpenAI, Gemini |
| Qwen + Claude OAuth | Device code flow (Qwen), PKCE + localhost callback (Claude) |
| OpenAI + Gemini | API key auth, OpenAI-совместимый формат |
| Загрузка моделей | `/v1/models` API + hardcoded fallback |
| Настройки | Нативное окно, выбор модели, Save/Cancel (всегда видны) |
| Выбор языка | Popover + поиск + флаги + недавние языки |
| Авто-определение языка | `NLLanguageRecognizer`, отображение "(auto)" |
| ⇄ Swap языков/текстов | Работает с Auto Detect |
| Глобальный хоткей | ⌘⇧C (настраиваемый через HotkeyRecorder) |
| Auto-refresh токенов | Qwen (`x-www-form-urlencoded`) + Claude (JSON) |
| Cmd+Enter | Отправка перевода |
| Понятные ошибки | Локализованные сообщения |
| Локализация RU/EN | По языку системы + переключатель в настройках |
| Переключатель языка апки | RU/EN в настройках + alert о рестарте |
| Консоль отладки | AppLogger + ConsoleView (⌘L), JSON payload/response |

### 🔄 В работе
- [x] OpenAI / GPT провайдер ✅

### 📋 Следующие задачи

#### Сейчас
- [ ] Стриминг перевода (токен за токеном)
- [ ] Перевод документов
- [ ] OCR (скриншот → текст → перевод)
- [ ] TTS (озвучка перевода)
- [ ] Браузерное расширение (Chrome/Safari)

#### Потом
- [ ] Стиль перевода (формальный/разговорный/технический) по провайдеру

#### Может быть
- [ ] Google Gemini провайдер (код готов, нужен API key через AI Studio)
- [ ] Кастомный OpenAI-совместимый эндпоинт (Ollama, LM Studio, OpenRouter)
- [ ] История переводов (последние N)

#### При установке в систему
- [ ] Автозагрузка при входе в систему (hidden, без окна)

---

## Архитектура

```
AITranslator/
├── App/              # AITranslatorApp (точка входа), AppDelegate (хоткей, статус-бар, меню)
├── Models/
│   ├── Provider.swift    # ProviderType enum (qwen/anthropic/openai/gemini), ProviderConfig
│   ├── Language.swift    # Language struct, LanguageList (список языков + флаги)
│   └── Translation.swift # TranslationRequest, TranslationResponse
├── Services/
│   ├── Providers/
│   │   ├── AIProvider.swift       # Протокол AIProvider + AIProviderError
│   │   ├── QwenProvider.swift     # OAuth + API key, OpenAI-совместимый
│   │   ├── AnthropicProvider.swift# OAuth + API key, Messages API
│   │   ├── OpenAIProvider.swift   # API key only, chat/completions
│   │   └── GeminiProvider.swift   # API key only, OpenAI-совместимый endpoint
│   ├── Auth/
│   │   ├── OAuthService.swift     # OAuth flows (device code, PKCE, token refresh)
│   │   ├── KeychainService.swift  # Файловое хранилище токенов (~/.aitranslator/credentials/)
│   │   └── OAuthCallbackServer.swift # Localhost HTTP server для OAuth callback
│   ├── AppLogger.swift            # Singleton логгер для консоли отладки
│   ├── ModelService.swift         # Загрузка моделей с API
│   └── TranslationService.swift   # Оркестратор перевода (выбор провайдера, error handling)
├── ViewModels/
│   ├── TranslatorViewModel.swift  # Состояние переводчика, авто-детект языка, swap
│   └── SettingsViewModel.swift    # Draft state, save/cancel, OAuth flow, API key management
├── Views/
│   ├── TranslatorView.swift       # Главное окно (двухпанельный переводчик)
│   ├── Settings/
│   │   └── SettingsView.swift     # Настройки (провайдеры, хоткей, язык апки)
│   ├── Components/
│   │   ├── LanguageSelectorView.swift  # Popover с поиском + флаги
│   │   └── HotkeyRecorderView.swift    # Запись кастомного хоткея
│   └── Console/
│       └── ConsoleView.swift      # Консоль отладки (фильтры, JSON, авто-скролл)
├── Utilities/
│   └── Constants.swift            # OAuth client IDs, URLs
└── Resources/
    ├── en.lproj/Localizable.strings
    └── ru.lproj/Localizable.strings
```

## Ключевые решения

| Решение | Почему |
|---------|--------|
| **Токены в файлах** | `~/.aitranslator/credentials/` — без Keychain-промптов при каждом запуске |
| **Qwen refresh** | `x-www-form-urlencoded` (не JSON!) |
| **Claude refresh** | JSON body, `anthropic-beta: oauth-2025-04-20` header |
| **Хоткей** | Carbon `RegisterEventHotKey` + AXUIElement для захвата выделенного текста |
| **Модели** | `/v1/models` API (Claude) + hardcoded fallback (все провайдеры) |
| **Gemini endpoint** | `generativelanguage.googleapis.com/v1beta/openai` — OpenAI-совместимый формат |
| **Code signing** | Team ID `GM23JF485V` — для стабильных Accessibility permissions |
| **xcodegen** | `project.yml` → автогенерация `.xcodeproj` при добавлении новых файлов |

## Как продолжить разработку

1. **Сборка**: `xcodegen generate && xcodebuild -scheme AITranslator build`
2. **Добавление провайдера**: создать `XxxProvider.swift` (протокол `AIProvider`), добавить case в `ProviderType`, зарегистрировать в `TranslationService.setupProvider`
3. **Локализация**: добавить строки в оба `Localizable.strings`
4. **Новые файлы**: после создания → `xcodegen generate` для обновления проекта
5. **Отладка**: консоль ⌘L показывает все API запросы/ответы в JSON

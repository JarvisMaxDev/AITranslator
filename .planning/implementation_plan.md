# AI Translator — План реализации

Нативное macOS-приложение (Swift/SwiftUI) для перевода текста через AI с глобальным хоткеем.

## MVP (Текущая фаза)

### Сделано ✅
- Двухпанельный интерфейс переводчика (источник → перевод)
- Qwen провайдер (OAuth device code flow + API key)
- Claude провайдер (OAuth PKCE + API key)
- Динамическая загрузка моделей с API (`/v1/models` для обоих провайдеров)
- Выбор модели в настройках (сохраняется)
- Настройки как нативное macOS окно
- Выбор языка с поиском + флаги + недавние языки наверху
- Сохранение/Отмена в настройках (всегда видны, disabled когда нет изменений)
- Файловое хранение OAuth токенов (без Keychain-промптов)
- Иконка в статус-баре + меню
- Локализация (RU/EN) — по языку системы
- Глобальный хоткей ⌘⇧C (настраиваемый в Настройках)
- Auto-refresh токенов (Qwen + Claude)
- Cmd+Enter для перевода
- Понятные сообщения об ошибках

---

## v1.1 — Полировка
- [ ] Автозагрузка при входе в систему (hidden, без окна)
- [ ] Переключатель языка апки в настройках (RU/EN)
- [ ] Double ⌘C (с Developer certificate для постоянного Accessibility)
- [ ] Авто-определение языка из текста
- [ ] История переводов (последние N)
- [ ] Анимация при смене языков

## v1.2 — Больше провайдеров
- [ ] OpenAI / GPT
- [ ] Google Gemini
- [ ] Кастомный OpenAI-совместимый эндпоинт
- [ ] Настройки модели по провайдеру (temperature и т.д.)

## v2.0 — Продвинутые функции
- [ ] Перевод документов (вставить файл, перевести абзацы)
- [ ] OCR (скриншот → текст → перевод)
- [ ] TTS (озвучка перевода)
- [ ] Браузерное расширение (Chrome/Safari)
- [ ] Стриминг перевода (токен за токеном)

---

## Архитектура

```
AITranslator/
├── App/
│   ├── AITranslatorApp.swift      # Точка входа, сцены, общие ViewModels
│   └── AppDelegate.swift          # Хоткей, статус-бар, меню
├── Models/
│   ├── Provider.swift             # ProviderType, ProviderConfig, модели
│   ├── Language.swift             # Список языков + флаги
│   └── Translation.swift          # Request/Response модели
├── Services/
│   ├── ModelService.swift         # Динамическая загрузка моделей из API
│   ├── Providers/
│   │   ├── AIProvider.swift       # Протокол
│   │   ├── QwenProvider.swift     # OpenAI-совместимый + auto-refresh
│   │   └── AnthropicProvider.swift # Claude Messages API + auto-refresh
│   ├── Auth/
│   │   ├── OAuthService.swift     # OAuth потоки + refresh token
│   │   ├── KeychainService.swift  # Хранение учётных данных
│   │   └── LocalCallbackServer.swift # Localhost callback для PKCE
│   └── TranslationService.swift   # Оркестратор
├── ViewModels/
│   ├── TranslatorViewModel.swift
│   └── SettingsViewModel.swift
├── Views/
│   ├── MainWindow/
│   │   ├── TranslatorView.swift
│   │   ├── TranslationPanel.swift
│   │   └── LanguageSelectorView.swift # С секцией "Недавние"
│   ├── Settings/
│   │   └── SettingsView.swift
│   └── Components/
│       └── HotkeyRecorderView.swift   # Запись комбинации клавиш
└── Resources/
    ├── en.lproj/Localizable.strings
    └── ru.lproj/Localizable.strings
```

## Ключевые технические решения
- **OAuth токены**: хранятся в `~/.aitranslator/credentials/` — без промптов
- **Qwen refresh**: `Content-Type: application/x-www-form-urlencoded` (не JSON!)
- **Claude API**: `anthropic-beta: oauth-2025-04-20` для OAuth; refresh через JSON
- **Хоткей**: Carbon `RegisterEventHotKey` + AXUIElement для чтения выделения
- **Модели**: загружаются динамически из `/v1/models`, есть hardcoded fallback
- **Development certificate**: Team ID `GM23JF485V` — стабильная подпись

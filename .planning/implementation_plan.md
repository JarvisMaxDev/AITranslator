# AI Translator — План реализации

Нативное macOS-приложение (Swift/SwiftUI) для перевода текста через AI с глобальным хоткеем.

## MVP ✅

- Двухпанельный интерфейс переводчика (источник → перевод)
- Qwen + Claude провайдеры (OAuth + API key)
- Загрузка моделей с API (`/v1/models`)
- Настройки: нативное окно, выбор модели, Save/Cancel (всегда видны)
- Выбор языка с поиском + флаги + недавние языки
- Авто-определение языка из текста (NLLanguageRecognizer)
- ⇄ Swap языков/текстов (работает с Auto Detect)
- Глобальный хоткей ⌘⇧C (настраиваемый)
- Auto-refresh токенов (Qwen + Claude)
- Cmd+Enter для перевода
- Понятные сообщения об ошибках
- Локализация (RU/EN) по языку системы

---

## Следующие задачи

### Сейчас
- [ ] Переключатель языка апки в настройках (RU/EN)
- [ ] OpenAI / GPT провайдер
- [ ] Google Gemini провайдер (API key через AI Studio)

### Потом
- [ ] Кастомный OpenAI-совместимый эндпоинт (Ollama, LM Studio, OpenRouter — ввод URL + ключ)
- [ ] Настройки модели (temperature, max_tokens, стиль перевода) по провайдеру

### Может быть
- [ ] История переводов (последние N)

### При установке в систему
- [ ] Автозагрузка при входе в систему (hidden, без окна)

---

## v2.0 — Продвинутые функции
- [ ] Перевод документов
- [ ] OCR (скриншот → текст → перевод)
- [ ] TTS (озвучка перевода)
- [ ] Браузерное расширение (Chrome/Safari)
- [ ] Стриминг перевода (токен за токеном)

---

## Архитектура

```
AITranslator/
├── App/           # Точка входа, AppDelegate (хоткей, статус-бар)
├── Models/        # Provider, Language, Translation
├── Services/
│   ├── Providers/ # AIProvider протокол, Qwen, Anthropic
│   ├── Auth/      # OAuth (device code, PKCE), Keychain, Callback
│   ├── ModelService, TranslationService
├── ViewModels/    # Translator, Settings
├── Views/         # MainWindow, Settings, Components (HotkeyRecorder)
└── Resources/     # en/ru Localizable.strings
```

## Ключевые решения
- **Токены**: `~/.aitranslator/credentials/` (без Keychain-промптов)
- **Qwen refresh**: `x-www-form-urlencoded`; **Claude**: JSON
- **Хоткей**: Carbon `RegisterEventHotKey` + AXUIElement
- **Модели**: `/v1/models` API + hardcoded fallback
- **Certificate**: Team ID `GM23JF485V`

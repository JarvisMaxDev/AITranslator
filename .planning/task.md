# AI Translator — Текущие задачи

## Сделано

- [x] Qwen OAuth + API (device code flow, enable_thinking=false)
- [x] Claude OAuth + API (PKCE, localhost callback, anthropic-beta header)
- [x] Настройки: нативное окно, выбор модели (API), сохранить/отмена
- [x] Модель в статус-баре
- [x] Выбор языка с поиском и флагами
- [x] Локализация (EN/RU)
- [x] Глобальный хоткей ⌘⇧C (AXUIElement читает выделенный текст → переводит)
- [x] Development certificate (Team GM23JF485V) — стабильный Accessibility
- [x] Auto-refresh токенов Qwen (x-www-form-urlencoded)
- [x] Auto-refresh токенов Claude (JSON, подтверждено через curl)
- [x] Cmd+Enter для перевода в главном окне
- [x] Понятные сообщения об ошибках (catch AIProviderError)
- [x] Настраиваемая комбинация клавиш в настройках

## MVP завершён! 🎉

## Публикация и CI/CD

- [x] Залить код в репозиторий Jarvis на GitHub
- [x] Добавить `.github/workflows/release.yml` для автоматической сборки приложения (xcodebuild archive)
- [x] Настроить создание архива/образа (ZIP или DMG)
- [x] Настроить авто-релизы в GitHub при создании тэга (напр. v1.0.0)
- [x] Автоверсия из git tag → CFBundleShortVersionString + build number
- [x] Опубликовать Homebrew Cask формулу (`aitranslator.rb`) для быстрой установки

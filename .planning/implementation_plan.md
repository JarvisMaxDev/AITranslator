# AI Translator — Implementation Plan

Native macOS app (Swift/SwiftUI) for AI-powered translation with global hotkey.

## MVP (Current Phase)

### Done ✅
- Two-panel translator UI (source → target)
- Qwen provider (OAuth device code flow + API key)
- Claude provider (OAuth PKCE + API key)
- Dynamic model loading from Anthropic `/v1/models` API
- Model selector in settings (persisted)
- Settings as native macOS Window
- Language selector with search + flags
- Save/Cancel in settings (draft state)
- File-based OAuth token storage (no Keychain prompts)
- Status bar icon + menu
- Localization (RU/EN)

### In Progress 🔧
- Global hotkey ⌘⇧C (select + copy + translate)
  - Carbon RegisterEventHotKey — works without Accessibility for the shortcut itself
  - CGEvent simulate ⌘C — needs Accessibility for copy simulation
- Customizable hotkey in settings (planned)

### Remaining for MVP
- [ ] Verify hotkey works end-to-end with Accessibility
- [ ] Cmd+Enter to translate in main window
- [ ] Error messages: human-readable (not raw JSON)
- [ ] Token refresh (currently shows "session expired")

---

## v1.1 — Polish
- [ ] Customizable hotkey picker in settings
- [ ] Double ⌘C support (with Developer certificate for persistent Accessibility)
- [ ] Auto-detect language from text
- [ ] Translation history (last N translations)
- [ ] Swap languages button animation
- [ ] Cursor/placeholder vertical alignment fix

## v1.2 — More Providers
- [ ] OpenAI / GPT provider
- [ ] Google Gemini provider
- [ ] Custom OpenAI-compatible endpoint
- [ ] Provider-specific model settings (temperature, etc.)

## v2.0 — Advanced Features
- [ ] Document translation (paste file, translate paragraphs)
- [ ] OCR (screenshot → text → translate)
- [ ] TTS (read translation aloud)
- [ ] Browser extension (Chrome/Safari)
- [ ] Streaming translation (token-by-token)

---

## Architecture

```
AITranslator/
├── App/
│   ├── AITranslatorApp.swift      # Entry, scenes, shared ViewModels
│   └── AppDelegate.swift          # Hotkey, status bar, menu
├── Models/
│   ├── Provider.swift             # ProviderType, ProviderConfig, available models
│   ├── Language.swift             # Language list + flags
│   └── Translation.swift          # Request/Response models
├── Services/
│   ├── ModelService.swift         # Dynamic model fetching from APIs
│   ├── Providers/
│   │   ├── AIProvider.swift       # Protocol
│   │   ├── QwenProvider.swift     # OpenAI-compatible
│   │   └── AnthropicProvider.swift # Claude Messages API + OAuth beta
│   ├── Auth/
│   │   ├── OAuthService.swift     # OAuth flows (device code, PKCE)
│   │   ├── KeychainService.swift  # Credential storage (file + keychain)
│   │   └── LocalCallbackServer.swift # Localhost callback for PKCE
│   └── TranslationService.swift   # Orchestrator (not yet extracted)
├── ViewModels/
│   ├── TranslatorViewModel.swift
│   └── SettingsViewModel.swift
├── Views/
│   ├── MainWindow/
│   ├── Settings/
│   ├── Popup/                     # PopupTranslatorView (future use)
│   └── Components/
└── Resources/
    ├── en.lproj/Localizable.strings
    └── ru.lproj/Localizable.strings
```

## Key Technical Decisions
- **OAuth tokens**: stored in `~/.aitranslator/credentials/` (not Keychain) to avoid dev build prompts
- **Claude API**: requires `anthropic-beta: oauth-2025-04-20` header for OAuth tokens
- **Claude token exchange**: JSON body with `state` field required by `platform.claude.com/v1/oauth/token`
- **Hotkey**: Carbon `RegisterEventHotKey` (no Accessibility) + CGEvent copy simulation (needs Accessibility)
- **Models**: fetched dynamically from `/v1/models`, hardcoded fallback

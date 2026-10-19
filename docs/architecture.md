# Как это работает

Диаграммы ниже — актуальное описание того, что происходит в коде. Mermaid рендерится
прямо на GitHub.

- Приложение: `macapp/` (Swift, menu bar, `LSUIElement`)
- Распознавание: `backend/worker.py` (Python-сайдкар, GigaAM-v3, MPS/CPU)
- Контракт между ними: построчный JSON через pipe

---

## 1. Компоненты

```mermaid
flowchart TB
    KB["Клавиатура: Right ⌥"]
    MIC["Микрофон"]
    FOCUS["Активное приложение<br/>любое поле ввода"]

    subgraph app["Transcribator.app — Swift"]
        direction TB
        HM["HotkeyMonitor<br/>NSEvent global monitor<br/>fallback: CGEventTap"]
        AR["AudioRecorder<br/>16 kHz · mono · int16"]
        AC["AppController<br/>стейт-машина"]
        SC["ASRSidecar<br/>Process + JSON-lines"]
        TI["TextInjector<br/>буфер + Cmd+V"]
        CFG["ConfigStore<br/>config.json"]
    end

    subgraph py["Python sidecar — .venv"]
        direction TB
        W["worker.py<br/>протокол · VAD · чанки"]
        G["GigaAM-v3 e2e_rnnt / ctc"]
        CACHE[("~/.cache/gigaam<br/>ckpt 220–430 МБ")]
    end

    KB --> HM
    MIC --> AR
    HM --> AC
    AR --> AC
    AC <-->|"JSON per line"| SC
    SC <--> W
    W --> G
    G --- CACHE
    AC -->|"text"| TI
    TI --> FOCUS
    AC --- CFG
```

Два процесса, потому что GigaAM — это PyTorch + SentencePiece + CTC/RNNT-декодинг.
Держать тёплый Python-сайдкар дешевле, чем переписывать декодер на Swift.

---

## 2. Запись: зажал → сказал → отпустил

```mermaid
sequenceDiagram
    autonumber
    actor U as Пользователь
    participant HM as HotkeyMonitor
    participant AC as AppController
    participant AR as AudioRecorder

    U->>HM: зажимает Right ⌥
    HM->>AC: onEdge(down: true)
    AC->>AC: проверка isRecording / isTranscribing
    AC->>AR: start()
    AR->>AR: AVAudioEngine tap, buffer 4096
    AR-->>AC: onLevel(peak)
    AC->>AC: NSSound "Tink", иконка mic.fill
    Note over AR: AVAudioConverter 48 kHz → 16 kHz mono int16<br/>буфер копится в Data под NSLock

    U->>HM: отпускает Right ⌥
    HM->>AC: onEdge(down: false)
    AC->>AR: stop() → [Int16]
    AC->>AC: NSSound "Pop"
    Note over AC: короче 0.3 с — считаем случайным нажатием
```

---

## 3. Распознавание и вставка

```mermaid
sequenceDiagram
    autonumber
    participant AC as AppController
    participant SC as ASRSidecar
    participant W as worker.py
    participant TI as TextInjector
    participant AP as Активное приложение

    AC->>SC: transcribe(pcm)
    SC->>W: {"id":N,"cmd":"transcribe"}<br/>pcm_b64 = int16 LE 16 kHz
    W->>W: base64 → float32 → 16 kHz
    W->>W: trim_silence, затем чанки ≤ 20 с
    W->>W: log-mel → encoder MPS fp16
    W->>W: greedy decode CTC / RNNT → BPE
    W-->>SC: {"id":N,"ok":true,<br/>"text":"Привет, мир."}
    SC-->>AC: completion(.success)
    AC->>AC: HistoryLog.append → history.txt
    AC->>TI: insert(text, mode: paste)
    TI->>TI: снимок буфера обмена
    TI->>TI: через 20 мс post Cmd+V
    TI->>AP: текст в поле, где стоял курсор
    TI->>TI: через 350 мс вернуть прежний буфер
```

Задержка после отпускания клавиши: отправка PCM по pipe (~1 мс), VAD + mel (~10 мс),
энкодер и декодер (~300–500 мс на 11 с аудио). Итого ≈ 0.5 с — модель уже прогрета.

---

## 4. Старт приложения и права

```mermaid
sequenceDiagram
    autonumber
    participant L as launchd
    participant AC as AppController
    participant T as TCC
    participant PY as python sidecar

    L->>AC: applicationDidFinishLaunching
    AC->>T: AXIsProcessTrusted()
    alt Accessibility есть
        AC->>AC: HotkeyMonitor → NSEvent monitor<br/>mechanism = "nsevent"
    else есть Input Monitoring
        AC->>AC: CGEventTap listenOnly<br/>mechanism = "cgeventtap"
    else прав нет
        AC->>T: AXIsProcessTrustedWithOptions(prompt)
        AC->>AC: watchdog раз в 2 с
        Note over AC: права применяются к живому процессу,<br/>перехват поднимется без перезапуска
    end
    AC->>T: AVCaptureDevice.requestAccess(.audio)

    AC->>PY: Process(worker.py --model --device)
    PY->>PY: import torch → load_model
    PY->>PY: warmup 2 с шума (компиляция графов Metal)
    PY-->>AC: {"event":"ready","load_ms":...,"warmup_ms":...}
```

Права:

| Разрешение | Зачем | Когда запрашивается |
| --- | --- | --- |
| Микрофон | запись | при старте |
| Универсальный доступ (Accessibility) | перехват клавиши + Cmd+V | при старте, если перехват не поднялся |
| Мониторинг ввода (Input Monitoring) | запасной CGEventTap | по кнопке «Запросить доступы…» |

---

## 5. Что происходит с аудио внутри воркера

```mermaid
flowchart TD
    A["pcm_b64 + sample_rate"] --> B["base64 → int16 → float32"]
    B --> C{"16 kHz?"}
    C -->|нет| D["resample_linear"]
    C -->|да| E["как есть"]
    D --> F{"≥ 0.15 c?"}
    E --> F
    F -->|нет| X1["text = '' · too_short"]
    F -->|да| G["trim_silence<br/>кадры 20 мс, RMS<br/>порог = max(шум·3, пик·0.02, 5e-4)"]
    G --> H{"что-то осталось?"}
    H -->|нет| X2["text = '' · silence"]
    H -->|да| I["split_long_audio<br/>куски ≤ 20 c<br/>рез по минимуму энергии"]
    I --> J["log-mel 64×T"]
    J --> K["Conformer encoder, MPS fp16"]
    K --> L{"e2e / rnnt?"}
    L -->|CTC| M["argmax + схлопывание"]
    L -->|RNNT| N["greedy joint, ≤10 символов на кадр"]
    M --> O["SentencePiece BPE<br/>или charwise"]
    N --> O
    O --> P["склейка кусков → text"]
```

VAD не роскошь: в push-to-talk вокруг фразы всегда много тишины. Обрезка экономит
20–40 % инференса и не даёт модели «галлюцинировать» на шуме.

---

## 6. Протокол приложение ↔ воркер

```mermaid
sequenceDiagram
    autonumber
    participant SC as ASRSidecar
    participant W as worker.py

    Note over W: stdout — только протокол,<br/>логи и tqdm — в stderr
    W-->>SC: {"event":"ready","protocol":1,"model":"v3_e2e_rnnt"}
    SC->>W: {"id":1,"cmd":"ping"}
    W-->>SC: {"id":1,"ok":true,"ready":true}
    SC->>W: {"id":2,"cmd":"transcribe"}<br/>sample_rate 16000, pcm_b64
    W-->>SC: {"id":2,"ok":true,<br/>"text":"Привет, мир.","decode_ms":460}
    SC->>W: {"id":3,"cmd":"transcribe",...}
    W-->>SC: {"id":3,"ok":true,"text":"","skipped":"silence"}
    SC->>W: {"cmd":"shutdown"}
```

Ответы сопоставляются по `id`. Если процесс умер — `terminationHandler` переводит
состояние в `.failed`, это видно в меню.

---

## 7. Состояния иконки в меню-баре

```mermaid
stateDiagram-v2
    [*] --> Loading: launch
    Loading --> Ready: event ready
    Loading --> Failed: event error / exit
    Failed --> Loading: Перезапустить бэкенд
    Ready --> Recording: зажал клавишу
    Recording --> Ready: отпустил, < 0.3 c
    Recording --> Transcribing: отпустил
    Transcribing --> Ready: пустой текст
    Transcribing --> Inserting: есть текст
    Inserting --> Ready: Cmd+V отправлен
    Transcribing --> Failed: ошибка
```

| Состояние | Иконка | Подпись в меню |
| --- | --- | --- |
| Loading | ⌛ hourglass | «Загружаю v3_ctc… 12 с» / «Скачиваю… 220–430 МБ» |
| Ready | 🎙 mic | «Готов: v3_ctc (mps)» |
| Recording | 🎙 mic.fill, красная | — |
| Transcribing | 〜 waveform, оранжевая | — |
| Failed | ⚠︎ треугольник | текст ошибки из воркера |

---

## 8. Смена модели и самолечение кэша

```mermaid
flowchart TD
    S["Сохранить настройки"] --> C{"model или device изменились?"}
    C -->|нет| S1["бэкенд не трогаем · 0 с"]
    C -->|да| C2["stop: shutdown → SIGTERM → ждём ≤ 2 c → SIGKILL"]
    C2 --> N["spawn нового worker.py"]
    N --> L["gigaam.load_model(model)"]
    L --> K{"файл есть в кэше?"}
    K -->|нет| D["скачивание 220–430 МБ"]
    K -->|есть| H{"md5 совпал?"}
    H -->|да| W["load_state_dict + прогрев"]
    H -->|нет| R["удалить битый ckpt"]
    R --> D
    D --> W
    W --> RDY["ready: model, device, load_ms, warmup_ms"]
```

Типичная «долгая загрузка» — это скачивание, а не сама модель: до 430 МБ на каждый
новый вариант. Из кэша переключение занимает ~4 с. Недокачанный `ckpt` (прерванное
переключение) ломает md5 — воркер это замечает, удаляет файл и качает заново.

---

## 9. Тайминги на M1 Pro / 16 ГБ

| Операция | Время |
| --- | --- |
| Старт приложения → `ready` | ~6 с |
| Распознавание 11.3 с аудио (MPS) | 0.48 с |
| То же на CPU | 0.6–0.7 с |
| VAD: 8 с записи с паузами | ~8 мс, остаётся 5.8 с |
| Смена модели из кэша | ~4 с |
| Память сайдкара (RSS) | ~1.8 ГБ |

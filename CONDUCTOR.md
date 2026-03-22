# oneBtnVoice

> Conductor AI agent orchestrator. Tags: `#project/onebtnvoice` `#agent/claude-code` `#agent/codex` `#agent/gemini`

## Operating Mode

> Project workflow for autonomous development with a single orchestrator.

1. We discuss a product/task idea with `codex` as the primary orchestrator.
2. `codex` converts the discussion into one backlog item or an epic plus executable tasks.
3. New tasks are written to this board first.
4. After creating a task, `codex` explicitly asks whether to launch it now.
5. Only after your confirmation does `codex` move the task into `In Progress` and start implementation.
6. When a task is finished, `codex` moves it to `Review` or `Done`, then proposes the next task in queue.
7. Large requests are decomposed into dependent tasks and executed sequentially unless parallel work is clearly safe.

## Working Agreement

- One conversational entry point: `codex`.
- One source of truth for task state: this file.
- Default behavior: discuss -> create task -> ask whether to launch.
- Exception: if you explicitly say `запускай`, that message counts as launch approval for the next queued task.

## Inbox

> Drop rough ideas here.

- Развить OneBtnVoice из базового диктора в более самостоятельный voice utility: улучшить menu bar UX, добавить историю транскрибаций, режим зафиксированной записи по двойному нажатию hotkey и блок статистики использования. #project/onebtnvoice #agent/codex #type/feature #priority/high

## Ready to Dispatch

> Move tagged tasks here to dispatch an agent.

- Добавить окно истории транскрибаций из menu bar: список по дате и времени, превью текста, быстрый просмотр полной записи и действие Copy in one click для любого элемента. #project/onebtnvoice #agent/codex #type/feature #priority/high

- Переработать menu bar меню под новые сценарии: выделить быстрые действия для History и Statistics, показать более понятные рабочие статусы и убрать ощущение служебного debug-only меню. #project/onebtnvoice #agent/codex #type/feature #priority/high

- Реализовать режим toggle dictation по двойному нажатию hotkey: второе быстрое нажатие фиксирует запись без удержания, повторное нажатие этой же кнопки завершает сессию. Нужны корректные переходы состояний, защита от ложных срабатываний и визуальная индикация locked режима. #project/onebtnvoice #agent/codex #type/feature #priority/high

- Добавить сбор и агрегацию пользовательской статистики: общее время наговорённого аудио, количество сессий, количество транскрибированных слов и другие базовые счётчики, считаемые из завершённых сессий. #project/onebtnvoice #agent/codex #type/feature #priority/high

- Добавить окно Statistics из menu bar: показать суммарные метрики, понятные подписи, форматирование в секундах/минутах/часах и минимальную разбивку по периоду, если данные уже есть. #project/onebtnvoice #agent/codex #type/feature #priority/medium

- Покрыть новую функциональность тестами: история и статистика в persistence/domain слое, переходы состояний coordinator для toggle mode и базовые smoke-проверки menu actions. #project/onebtnvoice #agent/codex #type/chore #priority/high

## Dispatching

## In Progress

- Спроектировать и реализовать слой хранения истории сессий диктовки: сохранять текст, дату/время, длительность записи, число слов, результат вставки и технический статус сессии. История должна переживать перезапуск приложения и стать источником данных для экрана статистики. #project/onebtnvoice #agent/codex #type/feature #priority/high

## Review

## Done

## Blocked

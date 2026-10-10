# Рабочая память — Generals iOS multiplayer

Обновляй этот файл в ветке `memory-notes` после каждой сессии: что проверено, что изменено (с коммитами), что НЕ изменено, результаты сборки/тестов и следующий конкретный шаг. Не записывай неподтверждённое как факт.

## Защищённые ограничения
- Основной репозиторий: `spideywva-spec/Generals-Mac-iOS-iPad`.
- Рабочая ветка пользователя: `generealss-spideywv`; не путать с другим репозиторием `spideywv-command-zero-hour`.
- Никогда не изменять `a13-ios-build` случайно. Сохранять A12/A13 Vulkan workaround, русскоязычный `IOSProfileLauncher`, настройки `build-ios-shell.yml` и не трогать `SDL3GameEngine` без доказанной необходимости.
- Цель: разобраться с multiplayer desync/таймаутами. Не объявлять успех только потому, что Actions workflow завершился успешно; проверять содержимое логов и подтверждать тестами.

## Референсы
- Android-порт: `MYSOREZ/GeneralsZH-Android-Port`; исходники `GeneralsMD/Code/GameEngine/Source/GameNetwork/GeneralsOnline/NetworkMesh.cpp`, `NextGenTransport.cpp`, заголовок `NetworkMesh.h`.
- iOS reference: `dvorovrus/Generals-Mac-iOS-iPad`, branch `feature/online-deterministic-math`. Выбирать детерминированную математику/FPU/CRC отдельно от transport fixes; не переносить весь NetworkMesh или teardown вслепую.
- Ветка `memory-notes` — только постоянные заметки/handoff. Кодовые изменения делать в `generealss-spideywv` или отдельной рабочей ветке, не в memory branch.

## Диагностика игрового лога (2026-10-10)
- Содержимое `logs/generals-stderr.log` из ветки `logs` проанализировано через GitHub connector; raw URL не скачался, поэтому не утверждать, что файл сохранён локально.
- Lobby ID `141339`, карта `Defcon 6 (6)`, 6 игроков.
- iOS использует relay-only ICE; TURN credentials/candidates присутствуют. Peer ID `92042` перестаёт отвечать вскоре после старта: таймауты 5, 8, 11 подряд; последнее сообщение примерно 7.8 секунды назад.
- SteamNetworking сообщает о socket lock около 5.2 ms; отдельно это не доказывает причину.
- CRC/state trace на кадрах 0/100/200 есть, но сопоставленных CRC двух устройств на одинаковых кадрах нет. Пока подтверждены сетевые таймауты, но не доказан simulation desync.
- После анализа лога код не менялся; fix/build/retest не выполнялись.

## Проверка исходников (2026-10-10)
- Сравнены реальные `NetworkMesh.cpp` из Android `main` и нашей `generealss-spideywv`. В обоих есть правила: учитывать join order, не пересигналивать ушедшему peer (`bPeerLeft`), повторять signalling при ошибке, продолжать восстановление соединения в матче, не заставлять host покидать лобби из-за одного peer. Значит, базовая retry-policy уже присутствует в нашей ветке; нельзя просто копировать её заново и заявлять исправление.
- Наша `NetworkMesh.cpp` длиннее Android reference (66990 против 57614 символов) и содержит дополнительные механизмы deferred deletion, mutex/ожидания TURN credentials. Следующий поиск причины должен быть в конкретных различиях жизненного цикла callback/handle, relay credentials/signalling, packet delivery и таймаутах.
- Android `NextGenTransport.cpp` проверяет channel prefix, magic, CRC, длины сообщения и освобождение полученных SteamNetworking messages. Нужна отдельная проверка остального файла и сопоставление этих packet-level safeguards с нашей реализацией.
- `Core/Libraries/Source/WWVegas/WWMath/wwmath.h` в нашей ветке и в указанной dvorov ветке имеет одинаковый blob SHA `01e507a6650fe7dd65865efd6f7d11b7673fc5d8`: deterministic wrappers уже совпадают на уровне этого файла. Не переносить его повторно.
- В dvorov `feature/online-deterministic-math` есть `GameLogic/FPUControl.h` с `ScopedFPUGuard`, документация `docs/HOWTO/INVESTIGATING_DESYNCS.md` и расширенный `XferCRC.cpp`/Deep CRC instrumentation. Документ подчёркивает, что для доказательства desync нужны deep-CRC dumps от обеих сторон одного матча; одного игрового stderr недостаточно.
- Сравнение dvorov `main` → `feature/online-deterministic-math`: ветка разошлась (72 commits ahead, 22 behind); diff затрагивает много online и build файлов. Не cherry-pick/merge всей ветки в iOS без выборочного анализа.
- Текущая сессия не меняла игровые исходники и не запускала сборку.


- Дополнительная проверка FPU (2026-10-10): в нашей ветке `GameLogic.cpp` встречается `setFPMode()`, но отсутствует использование `ScopedFPUGuard`; в dvorov branch `feature/online-deterministic-math` есть дополнительный `ScopedFPUGuard fpuGuard;` примерно около строки 3883 в `GameLogic.cpp`, а в `FPUControl.h` добавлен RAII guard, восстанавливающий FPU mode при выходе из scope. Это конкретное различие для выборочного анализа, но пока не доказано, что оно вызывает данный сетевой симптом.
- Проверка macro: `cmake/gamemath.cmake` в нашей ветке принимает option `SAGE_USE_DETERMINISTIC_MATH` и при включении выставляет compile definition `USE_DETERMINISTIC_MATH=1`; значит, названия option и кода различаются намеренно, не являются автоматически ошибкой. Надо ещё проверить фактический build preset/workflow, включена ли опция в конкретном Actions запуске.
- Наша `NextGenTransport.cpp` содержит packet diagnostics (BAD MAGIC/CRC mismatch) и retry при ошибке `SendGamePacket`; сравнить конкретный `doSend`/receive lifecycle с Android source перед правками.

## Постоянный handoff / следующие шаги
1. Изучить различия в Android `NetworkMesh.cpp` целиком, особенно `SetDisconnected`, signalling callback, `Tick`, relay/credential timing; сопоставить с нашей реализацией.
2. Сравнить Android `NextGenTransport.cpp` с нашей версией по отправке/приёму пакетов, очередям, ACK/sequence/CRC и таймаутам.
3. Проверить в нашей ветке фактическое включение deterministic math macro и FPU mode во всех game-logic paths; `SAGE_USE_DETERMINISTIC_MATH` и `USE_DETERMINISTIC_MATH` не считать взаимозаменяемыми без проверки CMake definitions.
4. Вносить только доказанные исправления в рабочую ветку; не менять `a13-ios-build`. После build скачать Actions artifact/log и проверить содержимое; затем повторить матч с логами обеих сторон и, если есть, двумя deep-CRC dumps.
5. В конце каждой следующей сессии обновлять этот файл отдельным commit в `memory-notes`.

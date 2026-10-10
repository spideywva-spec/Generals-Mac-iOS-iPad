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

## Работа по исправлению отправки игровых пакетов (2026-10-10, продолжение)

### Изменения в коде
- Создана отдельная ветка fix/multiplayer-send-result от generealss-spideywv; защищённая a13-ios-build не использовалась и не изменялась.
- Файл: GeneralsMD/Code/GameEngine/Source/GameNetwork/GeneralsOnline/NetworkMesh.cpp.
- Коммиты с исправлением: f9797d39ae2953d3985574abc56fe97bc02b93d2 (основное исправление), 97e44ad62de151b2515b3b98c68b52ad94113ec9 и 3296fe3e53412af41bf27577b351ae76c21b206f (приведение длины Steam send к int в обеих попытках). Последний SHA ветки на момент записи: 3296fe3e53412af41bf27577b351ae76c21b206f.
- Исправлена PlayerConnection::SendGamePacket:
  1. При успешном SteamNetworkingSockets()->SendMessageToConnection(...) теперь сразу возвращается фактический k_EResultOK. Раньше при успехе выполнение падало в конец функции и возвращало k_EResultFail, из-за чего вызывающий NextGenTransport::doSend ошибочно считал успешную отправку неудачной, повторял её и мог в конце удалить пакет из очереди.
  2. При активном transport plugin после вызова AnticheatPlugInterface::SendPacket(...) возвращается k_EResultOK, чтобы не сообщать вызывающему коду об ошибке только из-за общего финального return. Это подтверждает факт передачи в plugin, а не доставку до удалённого устройства.
  3. Повторная попытка Steam send теперь использует тот же буфер vecData с префиксом ENetworkChannel::NETWORK_CHANNEL_GAME. Раньше fallback отправлял исходный pBuffer без байта канала, хотя NextGenTransport::doRecv ожидает канал перед заголовком; это могло ломать framing при использовании fallback.
  4. При неудаче обеих Steam-попыток возвращается реальный код ошибки второй попытки и записывается диагностический лог; это сохраняет контракт результата для doSend.
- Автоматическая проверка перед записью файла подтвердила: определение функции единственное, есть success return, обе Steam-отправки используют vecData, сырой pBuffer не передаётся во fallback.
- Это подтверждённые дефекты кода и исправление контракта отправки. Пока не доказано, что они являются единственной причиной тайм-аута peer 92042 или всех проблем синхронизации.

### Проверки, которые НЕ выполнены
- Нативная компиляция / GitHub Actions после исправления ещё не запускались и результат сборки неизвестен.
- Не проведён новый реальный матч между двумя устройствами.
- Не получены парные deep-CRC/CRC-снимки с одинаковых кадров; нельзя утверждать, что simulation desync устранён.
- Изменён только NetworkMesh.cpp в рабочей ветке. Не изменялись NextGenTransport.cpp, deterministic math/FPU, русская IOSProfileLauncher, build-ios-shell.yml, Vulkan настройки и SDL3GameEngine.

### Как вспомнить и откатить
- Рабочая ветка с исправлением: fix/multiplayer-send-result.
- Основной исправляющий коммит: f9797d39ae2953d3985574abc56fe97bc02b93d2; последующие корректировки типов аргумента send: 97e44ad62de151b2515b3b98c68b52ad94113ec9 и 3296fe3e53412af41bf27577b351ae76c21b206f. Откатить все три можно в обратном порядке, начиная с 3296fe3e53412af41bf27577b351ae76c21b206f.
- Чтобы отменить только это исправление в этой рабочей ветке, создать обратный коммит: git revert 3296fe3e53412af41bf27577b351ae76c21b206f && git revert 97e44ad62de151b2515b3b98c68b52ad94113ec9 && git revert f9797d39ae2953d3985574abc56fe97bc02b93d2. Не делать reset/force-push в защищённой a13-ios-build.
- Ветка заметок: memory-notes; эта запись описывает и код, и ограничения проверки.

### Следующий обязательный шаг
1. Проверить diff коммита и запустить сборку на ветке fix/multiplayer-send-result (через Actions или локальную сборку).
2. При ошибке компиляции исправлять только её в этой ветке и снова записывать SHA/лог.
3. Если сборка проходит, установить сборку на оба устройства и повторить матч с той же картой/числом игроков. Сохранить stderr обеих сторон и сопоставить transport logs и CRC одного и того же кадра.
4. Если timeout остаётся, продолжить расследование lifetime/lock в NetworkMesh::Tick, обработку disconnect callbacks и детерминированность симуляции. Не считать retry-policy доказанной причиной: она уже есть в нашей ветке.


## Уточнение воспроизведения: iOS↔iOS работает, iOS↔Android-host desync (2026-10-10)

### Факт от пользователя
- Пользователь уточнил, что он передал свой текущий iOS-билд другу; друг установил именно этот билд, и они играли онлайн без проблем с синхронизацией.
- Проблема возникает в другом сценарии: пользователь подключился к лобби, которое открыл игрок на Android-порте, и матч не синхронизировался.
- Это важное разделение сценариев: iOS↔iOS (одинаковый билд) успешен; iOS↔Android-host пока неуспешен. Не сводить оба случая к общей проблеме соединения.
- Это пользовательское наблюдение; отдельные логи Android-хоста и синхронные CRC двух клиентов ещё не проверены.

### Что это меняет в диагностике
1. Сначала проверить межплатформенную детерминированность симуляции и протокольную совместимость, а не считать, что причина — только NAT/TURN или повторные подключения.
2. Успешный вход в лобби/обмен пакетами не доказывает одинаковое состояние симуляции. Сопоставить game build/revision, карту, игровой режим/настройки, INI/data files и сетевые packet/channel/version markers у iOS и Android.
3. Получить stderr/transport log с обеих сторон одного неуспешного матча. По возможности включить deep CRC/state dump и сравнить одинаковые кадры (первый кадр, где значения расходятся), а не только CRC из одного устройства.
4. Отдельно проверить выбранный dvorov `feature/online-deterministic-math` diff: `ScopedFPUGuard` в `GameLogic.cpp`, FPU control/rounding mode и фактическое включение `SAGE_USE_DETERMINISTIC_MATH` в сборках iOS и Android. Это гипотеза для проверки, не установленная причина.
5. Сравнить точные Android MYSOREZ packet/transport implementation с iOS веткой (packet size limits, channel prefix, serialization, sequence/ACK/CRC и send/receive contracts). Не переносить весь Android `NetworkMesh.cpp` без анализа.

### Ограничения и текущий статус
- Исправление `SendGamePacket` в ветке `fix/multiplayer-send-result` остаётся отдельным непроверенным изменением до компиляции и реального теста; оно может относиться к отправке пакетов, но не доказывает исправление именно iOS↔Android desync.
- Никакая новая сборка или межплатформенный матч в рамках этого уточнения не запускались.
- Защищённая `a13-ios-build` не изменялась.
- Следующее действие: проверить полный diff `fix/multiplayer-send-result` (метод был значительно сокращён), затем собрать ветку и провести контрольный матч iOS↔iOS и тестовый матч iOS↔Android с логами обеих сторон. Если iOS↔iOS проходит, а Android-host снова расходится — сначала локализовать первый отличающийся CRC/пакет/игровой кадр и только после этого выбирать точечный fix.


## Рабочая сессия (2026-10-10): iOS↔Android/PC compatibility branch
- Создана отдельная ветка `fix/ios-android-lobby-compat` от `generealss-spideywv`. Защищённая `a13-ios-build` не изменялась. Сравнение refs показывает 5 коммитов поверх базовой ветки и только 4 изменённых исходных файла.
- В `GeneralsMD/Code/GameEngine/Source/GameNetwork/GeneralsOnline/OnlineServices_LobbyInterface.cpp` добавлено автоматическое имя `[iOS] ` только при создании лобби на Apple. Префикс не добавляется повторно; ручной `[iOS]` без пробела нормализуется. Изменяется поле имени в запросе создания лобби, не игровые пакеты или состояние симуляции.
- В `GeneralsMD/Code/GameEngine/Source/GameNetwork/GeneralsOnline/NetworkMesh.cpp`, `PlayerConnection::SendGamePacket`, исправлены обнаруженные при сравнении с MYSOREZ Android ошибки: успешная отправка раньше проваливалась к `k_EResultFail`; plugin-send тоже не возвращал успех; повторная отправка после ошибки посылала сырой `pBuffer` без channel prefix. Теперь возвращается результат реальной отправки, а fallback использует тот же буфер `vecData` с `NETWORK_CHANNEL_GAME`.
- В `GeneralsMD/Code/GameEngine/Include/GameLogic/FPUControl.h` добавлен `ScopedFPUGuard`; в `GeneralsMD/Code/GameEngine/Source/GameLogic/System/GameLogic.cpp` он создаётся в начале каждого `GameLogic::update()`, чтобы восстановить заданный FPU-режим при выходе из кадра. Это выборочная реализация подхода из dvorov `feature/online-deterministic-math`, не перенос всей ветки.
- Коммиты ветки:
  - `4d9cb07e7a663236c57ba6c6901bafdc84177e9d` — автоматический iOS lobby prefix.
  - `2121db5c2298965bbb670331a6c6a6604e450309` — send result/channel framing.
  - `11f6dd16e5f235df258674c47073c18ee6c50f45` — scoped FPU guard declaration.
  - `00ffb6157d6e17787359e967474d7ce24cae74f1` — FPU guard per simulation frame.
  - `dce2db94c75f362e6f3912deb00e9fe045406119` — normalize prefix without duplicate space.
- Проверки исходников после записи: ветка содержит нужный `return k_EResultOK` для успешной отправки и plugin path; fallback использует `vecData.data()`, а не raw `pBuffer`; lobby JSON использует `strPublishedLobbyName`; guard и его include присутствуют; diff относительно `generealss-spideywv` ограничен этими четырьмя файлами. В запросе GitHub Actions для новой ветки пока не было workflow runs.
- ВАЖНО: компиляция, GitHub Actions build и реальный тест iOS↔iOS / iOS↔Android / iOS↔PC ещё не выполнялись. Эти изменения — точечные исправления на основе исходников, а не подтверждённое решение всех трёх типов сбоев. Нельзя говорить, что межплатформенная синхронизация уже исправлена.
- Следующие шаги: проверить CI/build для этой ветки; прогнать prefix edge cases; тестировать вход в лобби/старт/матч отдельно с Android-host и PC-host; собрать stderr/transport logs обеих сторон и сравнить первый несовпадающий CRC. Если сборка не запускается автоматически, проверить доступные workflows и запустить подходящий.

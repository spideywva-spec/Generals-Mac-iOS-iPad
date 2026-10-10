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
- Создан Draft PR #1: https://github.com/spideywva-spec/Generals-Mac-iOS-iPad/pull/1 (base `generealss-spideywv`, head `fix/ios-android-lobby-compat`; не объединён).
- Следующие шаги: проверить CI/build для этой ветки; прогнать prefix edge cases; тестировать вход в лобби/старт/матч отдельно с Android-host и PC-host; собрать stderr/transport logs обеих сторон и сравнить первый несовпадающий CRC. Если сборка не запускается автоматически, проверить доступные workflows и запустить подходящий.


## Обязательное правило работы с GitHub Actions (пользовательское указание, 2026-10-10)
- Когда пользователь говорит «запусти сейчас», «сделай» или напоминает, что у ассистента есть доступ, не отвечать отказом по памяти и не предполагать отсутствие прав. Сначала реально проверить доступные GitHub tools/подключение, workflow-файлы, существующие runs и permissions; затем использовать доступный механизм запуска (workflow dispatch, rerun, либо подходящий push/PR-trigger), если он действительно доступен.
- Не утверждать, что workflow запущен, пока GitHub не вернул идентификатор run или другой однозначный результат. Если конкретного инструмента запуска нет или GitHub отверг запрос, сообщить точное ограничение и не подменять запуск ссылкой на страницу Actions.
- Для multiplayer PR #1 (ветка `fix/ios-android-lobby-compat`, HEAD `dce2db94c75f362e6f3912deb00e9fe045406119`, base `generealss-spideywv`): на 2026-10-10 проверка `fetch_commit_workflow_runs` вернула пустой список. PR открыт и draft, сборка и реальный iOS↔Android/PC матч не подтверждены. Не трогать `a13-ios-build`.
- В текущем GitHub connector доступны чтение workflow, просмотр run/artifacts/logs и rerun существующих runs; в списке инструментов не обнаружен отдельный workflow_dispatch/start-run action. `mcp__GitHub__fetch` — GET-only. Перед следующим ответом обязательно повторно проверить доступные инструменты, не считать это вечным отсутствием доступа.

- Follow-up 2026-10-10: successfully launched a real iOS shell workflow for PR branch by adding `fix/ios-android-lobby-compat` to the existing `.github/workflows/build-ios-shell.yml` push branch filter and committing on that same PR branch. Run ID `38038325029`, commit `100ea08797c2278bf1ea814662db7525ad8a055e`, event `push`, status was `queued` at confirmation. This is a verified launch; check run status/artifacts next. This changes only the PR branch, not `a13-ios-build`.


## Новая проверка игрового лога: подтверждённый desync на frame 111 (2026-10-10)

- Пользователь указал конкретный лог: https://github.com/spideywva-spec/Generals-Mac-iOS-iPad/blob/logs/generals-stderr.log, ветка `logs`. Файл проверен целиком через GitHub file fetch: blob SHA `6ffe1a31fc1fb32529383a4820afe9a6c4063582`, размер 439,683 символа, 2,682 строки. Не утверждать, что он был скачан в локальную файловую систему: в этой сессии его полный текст был получен/проанализирован через GitHub connector.
- Лог относится к iOS / Apple A13 GPU, runtime 1.4, build 601, `networkVersion=0x00010004`; `[ONLINE-MATH-CRC] value=0x97B538BF platform=apple`.
- Матч: lobby ID `143118`, match ID `4281908`, карта `Bear Town Beatdown (4)`, 4 игрока; пользователь `weyva`, localSlot 3 / networkSlot 3. Лобби переключилось в state=1 в 14:54:37, после чего игра загрузила матч. SteamNetworking ICE-соединения успешно установились через relay: user 127240 за 1765 ms, user 127244 за 2091 ms, user 74426 за 2852 ms; каждый с signalling attempt 1. Поэтому для этого лога нет основания называть первичной причиной невозможность соединения/TURN: peer connections установились.
- Ключевое подтверждение: `[ONLINE-DESYNC] detected frame=111 cached=4 connected=4 localPlayerIndex=5 localStateCRC=0xE2830B1B rngBase=0x7A21EEC7 rngCRC=0x5E465A44` (строка 2382).
- Подробности того же события (строки 2383–2387):
  - playerIndex=2, networkSlot=0, remote connected=1, CRC `0xC2BDF524`
  - playerIndex=3, networkSlot=1, remote connected=1, CRC `0xC2BDF524`
  - playerIndex=4, networkSlot=2, remote connected=1, CRC `0xC2BDF524`
  - playerIndex=5, networkSlot=3, local=1, connected=1, CRC `0xE5C74D69`
  - `gameFrame=111 validatedFrame=100 runAhead=10`, RNG base `0x7A21EEC7`, RNG CRC `0x5E465A44`.
- Следовательно, это уже не просто предположение по тайм-аутам: в этом логе детектор явно фиксирует несовпадение состояния симуляции на кадре 111. Все три удалённых player CRC совпадают друг с другом (`0xC2BDF524`), а локальный CRC отличается (`0xE5C74D69`). Это указывает, что локальное состояние расходится с состоянием, которое сообщают другие игроки. Один лог не позволяет определить конкретную первопричину (FPU/deterministic math, разница игровых данных/версий, RNG/порядок симуляции или сетевые команды) без логов хоста/других клиентов и сравнения одинакового кадра.
- До desync лог показывает:
  - frame 0: final CRC `0x52CB1B87`, objectCount 270, rngBase `0x7A21EEC7`, rngCRC `0x799F33C4`.
  - frame 100: final CRC `0xE5C74D69`, objectCount 270, rngCRC `0x6E724194`; legacy-wide probe повторяет тот же final CRC.
  - frame 200: final CRC `0x80220A89`, objectCount 271, rngCRC `0x93D629D4`.
  Эти значения взяты из одного локального лога, поэтому не доказывают cross-device equality сами по себе. Заметь: локальный frame-100 final CRC совпадает с локальным CRC, который напечатан в desync-диагностике; три remote CRC отличаются.
- Лог содержит `[NGMP] Failed to join lobby: Lobby is full` около 14:54:13 — это отдельная попытка входа в заполненное лобби до фактического матча; не смешивать её с причиной desync в lobby 143118.
- После frame-200 CRC trace лог продолжает рендер/сброс display; в доступном хвосте нет явной строки Steam peer timeout/disconnect или точного сообщения о закрытии сервера. Пользователь сообщил, что игра всё равно не синхронизируется и сервер/хост закрывает матч; причина закрытия не подтверждена только этим логом.
- Следующие обязательные действия: сохранить этот факт в памяти проекта; сравнить лог хоста и ещё одного клиента для match 4281908, получить их CRC на frame 100/111/200 и first divergence; проверить build/revision, ExeCRC/IniCRC, map/data files, RNG seeding and simulation commands across platforms; исследовать почему локальный frame 100 CRC `0xE5C74D69` differs from three peer CRCs `0xC2BDF524`. Не считать TURN/connectivity виновником только по этому логу; соединения были установлены. Не менять `a13-ios-build` и не объявлять desync исправленным до реального теста.
- Постоянное пользовательское правило: когда пользователь даёт ссылку/говорит, что загрузил игровой лог, проверить именно этот файл и записать подтверждённые выводы в этот канонический файл `memory-notes/MEMORY.md` (путь `MEMORY.md`, branch `memory-notes`); не путать с `memory.md`/другими ветками и не выдумывать, что проверка/сборка/тест были выполнены.


## Проверка совместимости с GeneralsOnline / playgenerals.online (2026-10-10)
- Пользователь повторно уточнил цель: его iOS порт должен играть с игроками экосистемы GeneralsOnline (Android, Windows PC, Linux, macOS), а не только с копиями того же iOS билда. Ориентир: https://www.playgenerals.online/.
- Проверена актуальная страница playgenerals.online через веб-поиск: сервис описывает себя как переосмысление multiplayer Generals/Zero Hour на базе SuperHackers, с полноценными GameSpy-подобными функциями и P2P relays. Сам факт использования одного сервиса не гарантирует, что любые платформенные сборки совместимы по симуляции.
- Важная историческая запись на официальных patch notes GeneralsOnline: update 011526 (15 Jan 2026) говорит, что ARM processors были временно ограничены от доступа к GO из-за mismatches, с планом позже маркировать ARM lobbies и разрешить ARM игрокам играть вместе. Источник: https://www.playgenerals.online/patchnotes/011526. Это прямо релевантно к наблюдаемому iOS/ARM desync; прежде чем считать это текущим ограничением сервера, нужно проверить последующие patch notes/текущую политику лобби.
- MYSOREZ Android README на main (blob SHA 1887e4582806a31916a206dc388cfcb68b187d69) заявляет cross-play с Windows GeneralsOnline: с версии Android 1.3.0; против текущего PC release 100126 — с Android 1.4.0; при тесте PC игрок должен выключить anti-cheat. Источник: https://github.com/MYSOREZ/GeneralsZH-Android-Port/blob/main/README.md. Это конкретная матрица совместимости, а не доказательство, что iOS build уже соответствует той же версии/настройкам.
- Проверены реальные исходники MYSOREZ NetworkMesh.cpp (SHA 008b5847b10e8b27f6733ee73719a6e6abf83836, 57,614 chars) и NextGenTransport.cpp (SHA f2afe832a40150d9b925f60028f41782dd547444, 16,775 chars), а также iOS ветки fix/ios-android-lobby-compat (NetworkMesh.cpp SHA 5a6cddbd6d0a4c8424b334f79dc7aef20dd9bae5, NextGenTransport.cpp SHA 10c155fbdb5c397753568ccd8050cb0ca57b2a4f). Наш transport files отличаются размером и реализацией; требуется точечный diff packet framing, sequence/CRC, send/receive contract и callbacks, не wholesale copy.
- Проверен .github/workflows/build-ios-shell.yml на fix/ios-android-lobby-compat: configure команда реально содержит -DSAGE_USE_DETERMINISTIC_MATH=ON; в cmake/gamemath.cmake option по умолчанию OFF, но workflow override включает её. Следовательно, для сборок через этот workflow нельзя утверждать, что deterministic math выключена. Надо проверить конкретный Actions run/артефакт и сравнить его build SHA/настройки с тестировавшимся IPA и с Android release.
- В GeneralsMD/Code/Main/CMakeLists.txt build metadata содержит version 1.4, build 601; это не само по себе доказательство совпадения версии игрового simulation code с PC/Android releases.
- Новый подтверждённый диагностический вывод: кроме транспортных различий, нужно исследовать известное ARM mismatch/лобби-флагирование на стороне GeneralsOnline и точную версию игрового simulation patchset. На последнем логе все три remote CRC одинаковы, local отличается на frame 111; это consistent with simulation mismatch, но конкретная причина пока не установлена.
- Не менялись игровые исходники, workflow или защищённая ветка a13-ios-build в рамках этой проверки; новая сборка и реальный тест не выполнялись. Следующий шаг: проверить более поздние patch notes/current GO ARM lobby policy, сравнить Android release 1.4.0 vs iOS build 601 source patches/INI/data/60Hz-vs-30Hz settings, проверить exact tested IPA SHA and Actions run, затем получить парные логи iOS + Android/PC с одним матчем и deep CRC на первом divergent frame.


## Confirmed transport send-result fix (2026-10-10, follow-up)

- On branch `fix/ios-android-lobby-compat`, changed `GeneralsMD/Code/GameEngine/Source/GameNetwork/GeneralsOnline/NextGenTransport.cpp`.
- Commit: `ace201fc7fe26adbc5ac66b3c4006d99f7638244`; new file blob SHA `aaaf2ba1e0a95b06ea0da40a11e5e61ba0ffe1e4`.
- Confirmed defect: `PlayerConnection::SendGamePacket` returns Steam `EResult` codes, where failures such as `k_EResultFail` are positive values. `NextGenTransport::doSend()` previously treated every `sendResult >= 0` as success, so a failed send could be counted as sent and its outgoing game packet cleared from the queue. That can drop a simulation command and plausibly cause desync.
- Fix: only `sendResult == static_cast<int>(k_EResultOK)` counts as a successful send; all other results enter the existing retry path and log the error. The updated source was fetched back from GitHub and verified to contain the new comparison and no old `sendResult >= 0` condition.
- This is a concrete transport correctness fix, not proof it was the sole cause of frame-111 desync. The existing Android `NextGenTransport.cpp` has a similar `sendResult >= 0` pattern, but its legacy `SendGamePacket` implementation/return contract differs; do not blindly transplant that legacy behavior into the iOS branch.
- Commit was pushed to `fix/ios-android-lobby-compat`, which is included in the existing workflow's push branch filter and `GeneralsMD/**` path filter. `fetch_commit_workflow_runs` returned an empty list because that connector endpoint only returns pull-request-triggered runs; it does not confirm whether the push-triggered run has started. Do not invent a run ID. Check the Actions run/log when a run ID is discoverable.
- Prior successful shell workflow remains run `38042315366` on commit `a47b1b598cb7f10dda246f95abef5d7d440ed026`; it predates this fix, so it does NOT validate commit `ace201fc7fe26adbc5ac66b3c4006d99f7638244`.
- `a13-ios-build`, `SDL3GameEngine`, Vulkan configuration, and Russian launcher were not changed. No cross-platform real-match test has been performed after this fix.


## Follow-up session (2026-10-10): Actions build and local artifact-log inspection

- Resumed from this canonical `MEMORY.md`; code work stayed on `fix/ios-android-lobby-compat`. Protected `a13-ios-build` was not changed.
- Checked the actual branch ref: HEAD is `26429268848989f7a372d745347b01d891a8e60d` (`Keep failed packet status and peer ordering consistent`), four commits after `ace201fc7fe26adbc5ac66b3c4006d99f7638244`: `b86cfc2` documentation comparison, `6832cb2` per-peer packet sequence, `976ecc8` preserve per-peer order on send failure, `2642926` keep failed status and ordering consistent.
- Confirmed GitHub Actions run **38045368900** is completed with conclusion `success` on exactly HEAD `26429268848989f7a372d745347b01d891a8e60d`. Job ID `114193745874`; all listed steps succeeded, including Configure, Build engine, Verify binary, Package unsigned shell, Upload shell, and Upload logs.
- Downloaded the workflow log artifact via the GitHub connector to the local session path `/mnt/data/GeneralsXZH-ios-build-logs.zip` (1.7 MB), extracted it locally to `/tmp/gxlogs`, and inspected both logs locally. The ZIP contains `build_ios_hub_online.log` (42,707,730 bytes) and `configure_ios_hub_online.log` (41,897 bytes). Build log reaches link of `GeneralsMD/GeneralsXZH.app/GeneralsXZH`; no actual compiler error, undefined reference, `FAILED:`, or linker error was found. There are numerous compiler/deprecation warnings and duplicate-library linker warnings. Actions package/verify steps passed.
- Workflow artifacts currently available: unsigned IPA artifact ID `11667249069` (27,713,279 bytes) and logs artifact ID `11667144179` (1,758,970 bytes). The IPA is unsigned and is not proof of installation/runtime success.
- Verified workflow command explicitly configures `-DSAGE_USE_DETERMINISTIC_MATH=ON`; the A12/A13 DXVK patch forces only `samplerMirrorClampToEdge` false and the workflow's sanity check does not disable Vulkan 1.2/1.3. The current branch changes `NextGenTransport.cpp` and its header for outgoing packet sequence/order and failure retention.
- Inspected current `NextGenTransport::doSend` and `queueSend`: queued packets are sorted by monotonically assigned sequence; after a send failure, later packets to the same address are blocked for that update, while other peers can proceed; success is recognized only when result equals `k_EResultOK`. This code compiled in the successful run. This does not prove that the send/ordering fixes eliminate cross-platform desync.
- Checked the public GeneralsOnline patch-notes index; it lists later updates through 28 Sep 2026, but the summaries available in that search do not establish whether the January 2026 ARM restriction was removed. Do not assume ARM access is currently enabled or disabled without verifying the exact current policy/lobby behavior.
- **Not performed:** no iOS device installation, no live iOS↔Android or iOS↔PC match, no paired logs/deep CRCs after this build. Therefore multiplayer compatibility and desync fix remain unverified despite the successful build.
- Next concrete step: use the unsigned IPA only through the user's normal signing/install path, test the same map/settings with an Android host and a PC GeneralsOnline host, and capture both sides' logs plus CRCs at frame 100/111/200 (or first divergent frame). If the game still desyncs, compare game/data patch revisions and lobby/platform eligibility before making another speculative transport change.


## Follow-up research (2026-10-10): current GeneralsOnline patch notes
- Resumed from canonical `memory-notes/MEMORY.md`; no game source or protected branch changed in this follow-up.
- Checked the public GeneralsOnline patch-notes index. The latest entry listed there is 28 Sep 2026, while the latest dated patch note successfully opened in this check was Update 082826 (28 Aug 2026). Do not claim the ARM restriction was removed: the Jan 15 note explicitly restricted ARM processors due to mismatches and described a future plan for ARM lobbies, but the later accessible notes do not explicitly confirm that rollout.
- Update 081326 (13 Aug 2026) says GeneralsOnline added Community Data Patch v1.0.0, recommends enabling it for vanilla gameplay, and includes latest SuperHackers changes plus fixes related to custom lobby settings and 60Hz rendering/gameplay. Update 082826 (28 Aug 2026) lists Game Data Patch v1.0.1 and multiple 60Hz simulation/gameplay fixes (supply drop payouts, particle timing, projectile orientation, low-acceleration movement), along with lobby/async-state stability fixes.
- Sources checked: https://playgenerals.online/patchnotes/011526 ; https://playgenerals.online/patchnotes/081326 ; https://mail.playgenerals.online/patchnotes/082826 ; patch-notes index https://mail.playgenerals.online/patchnotes .
- Diagnostic implication: the frame-111 CRC mismatch could be due to simulation/data patchset or timing differences as well as transport. Compare iOS build 601 against the exact GeneralsOnline client patchset and data-pack state, including Community Data Patch v1.0.1 and 60Hz fixes, before another speculative networking change. This is a hypothesis to verify, not a confirmed root cause.
- No new game build, device installation, or cross-platform match was run in this follow-up. Existing successful Actions run 38045368900 still validates compilation/package only; it does not prove multiplayer compatibility.
- Next step remains: identify the exact PC/Android GeneralsOnline client revision/data-pack settings used in a failing match, then collect both sides' logs and CRCs at the first divergent frame. Keep `a13-ios-build`, its A12/A13 Vulkan settings, Russian `IOSProfileLauncher`, and `SDL3GameEngine` untouched.


## Follow-up source comparison (2026-10-10): NextGenTransport wire framing
- Compared full `NextGenTransport.cpp` in `fix/ios-android-lobby-compat` (blob SHA `f0912fe3958d2e986012772f4fe2c2e114669dbb`) against MYSOREZ Android `main` (blob SHA `f2afe832a40150d9b925f60028f41782dd547444`), and compared both `NetworkMesh.cpp` implementations (iOS SHA `5a6cddbd6d0a4c8424b334f79dc7aef20dd9bae5`, Android SHA `008b5847b10e8b27f6733ee73719a6e6abf83836`).
- Confirmed the channel framing is present on both sides: `PlayerConnection::SendGamePacket` prepends `ENetworkChannel::NETWORK_CHANNEL_GAME`; both receive paths strip/check that channel byte before parsing `TransportMessageHeader`. iOS `doSend` constructs header+payload bytes explicitly, while Android passes the buffer starting at the transport header with `totalLen = header + payload`; this appears intended to put the same header/payload bytes on the wire, but should be validated with packet captures/hex logs rather than assumed from source alone.
- Confirmed a meaningful transport behavior difference: Android's legacy `doSend` sets success from `sendResult >= 0` and drops a failed packet; iOS now treats only `k_EResultOK` as success, retains failed packets, and blocks newer packets to the same peer from overtaking them. Because the Android implementation's send-return contract differs in other respects, do not copy its `>= 0` check into iOS.
- iOS receive path also pumps `NetworkMeshLibrary::Tick()` from `doRecv()` to process Steam callbacks during map-transfer loops; Android does not do this in `NextGenTransport::doRecv()`. This difference alone is not evidence of a simulation mismatch.
- No proven additional packet-framing defect was found in this narrow comparison. Do not make a speculative edit based only on file-size differences. Next source investigation should prioritize exact simulation/data patch compatibility (GeneralsOnline Community Data Patch v1.0.1 and SuperHackers 60Hz fixes) and capture matching packet/CRC traces from both peers.
- No game source was changed and no build/test was run during this comparison. The only repository mutation in this follow-up was the documentation update in `memory-notes` commit `4f3c78eb70de89952831fa95b72a14bd281667ed`; protected `a13-ios-build` remains untouched.

## Локальная проверка Actions logs ветки errors (2026-10-10)
- По просьбе пользователя скачан именно artifact логов, а не только просмотрена страница Actions: artifact `GeneralsXZH-ios-build-logs`, ID `11663650850`, из run `38033498168` ветки `errors/actions-147-local-check`, commit `5711ebe7994b9617cfdef7bb7d3d11281d6ae2bd`.
- ZIP скачан в рабочую файловую систему как `/mnt/data/errors-branch-ios-build-logs.zip` и распакован локально в `/mnt/data/errors-branch-ios-build-logs-extracted/`. Внутри `build_ios_hub_online.log` (42,707,730 байт) и `configure_ios_hub_online.log` (209,826 байт).
- В Actions run/job все шаги завершились `success`, включая Configure, Build, Verify binary, Package и Upload logs. В локально скачанном build log явных compiler `error:`, `fatal error:`, linker errors или `FAILED:` не найдено; есть предупреждения, в том числе несовпадение регистра include: `NextGenTransport.cpp:3 #include "Common/CRC.h"`, фактический путь компилятор предлагает как `Common/crc.h`. Это предупреждение, не ошибка данной сборки на macOS, но стоит исправить регистр для переносимости на case-sensitive FS.
- Configure log явно подтверждает `GameMath deterministic math enabled (fdlibm backend)` и bit-exact math. При этом feature `DebugIncludeDebugLogInCrcLog` отключён, поэтому этот билд не включает дополнительный подробный CRC debug logging, нужный для диагностики desync.
- В build log отмечено `[1603/1604] Linking ... GeneralsXZH`, после чего лог заканчивается предупреждением линкера; отдельно Actions step `Verify binary` и весь job успешны. Поэтому по статусу Actions сборка прошла, но логовый artifact сам по себе не содержит результатов реального запуска игры/матча.
- Это build/configuration log, не игровой `generals-stderr.log`: в нём нет CRC-сравнения двух устройств или доказательства, что cross-platform multiplayer sync исправлен. Код в этой проверке не менялся, новая игра/матч не запускались, `a13-ios-build` не трогалась.
- Следующий шаг: исправлять include-case warning отдельным минимальным изменением только в рабочей ветке при необходимости; главное — собрать диагностический вариант с подробным CRC logging включённым и получить парные deep-CRC dumps с iOS и PC/Android в одном матче. Не объявлять сетевую синхронизацию исправленной по одной успешной сборке.

## FPU scope fix and local build-log review (2026-10-10)
- Downloaded and extracted Actions artifact from run 38033498168 locally: `build_ios_hub_online.log` (~42.7 MB) and `configure_ios_hub_online.log` (~210 KB). Build succeeded; compile log contained no fatal errors. It showed a real non-portable include-case warning in `GeneralsMD/Code/GameEngine/Source/GameNetwork/GeneralsOnline/NextGenTransport.cpp:3`: include used `Common/CRC.h`, filesystem spelling is `Common/crc.h`.
- Created isolated branch `fix/ios-online-log-portability` from `errors/actions-147-local-check`; no changes to protected `a13-ios-build`, Vulkan configuration, Russian launcher, or `SDL3GameEngine`.
- Commit `9ee0677f4207b06b20db400e0f78761eaab6374f` fixes the include casing warning.
- Source comparison against `dvorovrus/Generals-Mac-iOS-iPad:feature/online-deterministic-math` found a specific FPU-state difference: reference branch has `ScopedFPUGuard` in `GameLogic::update()` and its header, ours did not. Added the same scope-exit reassertion of `setFPMode()` in `GeneralsMD/Code/GameEngine/Include/GameLogic/FPUControl.h` and at the beginning of `GameLogic::update()`. Commits: `a1650b39a33a8133c6e688adb55d355333eba35f` (guard) and `d397244792ce7154f60fb254dd4795e8e02f6537` (use guard). This is a narrowly scoped deterministic-FPU consistency fix; it is a plausible contributor, not yet proven to fix all cross-platform desync.
- Added the isolated branch to `.github/workflows/build-ios-shell.yml` trigger in commit `9183a74b94391c858a7ffe2cc653ffe344bfafcf`. CI run `38051927605` was queued at handoff; compile result not yet known.
- The downloaded configure log confirms GameMath/fdlibm is enabled for this iOS build. It does not establish whether the PC/Android clients in the target GeneralsOnline lobby use the same deterministic math/data patch. CRC deep logging was not enabled in this build; no matched cross-device CRC dumps or real cross-platform match are available yet.


## Работа по модам и межплатформенной синхронизации (2026-10-10)

### Созданная рабочая ветка / PR
- Рабочая ветка: `fix/mods-visible-cross-platform-sync`, основана на `generealss-spideywv`; защищённая `a13-ios-build` напрямую не менялась.
- PR: https://github.com/spideywva-spec/Generals-Mac-iOS-iPad/pull/2 (открыт, не слит).
- Последний коммит ветки: `e891ca525c9acd96149075407282ba873d6afcb5`.
- Коммиты по порядку:
  - `616ddfca090681a50769800e870b8943689d5c93` — исправление контракта результата отправки игровых пакетов и framing fallback.
  - `0415a8bc71827203cfe8bea177df6b04a59da484` — возврат канонической папки модов в Documents/Mods и восстановление старых данных.
  - `9567456ef708ad3a2ae5658b858ebb387690f8ee` — включение deterministic math в общий preset `default-vcpkg` для современных не-VC6 сборок.
  - `e891ca525c9acd96149075407282ba873d6afcb5` — добавлена рабочая ветка в push-trigger iOS build workflow для проверки.

### Изменения
- `GeneralsMD/Code/Main/IOSModManager.mm`: канонический путь снова `Documents/Mods`, чтобы папка была видна в iOS Files. При запуске профили переносятся из прежнего `Library/Application Support/GeneralsX/Hub/Mods`, если целевого профиля ещё нет; если обе копии есть, копируются только отсутствующие файлы, старый источник не удаляется, существующие файлы не перезаписываются.
- `GeneralsMD/Code/GameEngine/Source/GameNetwork/GeneralsOnline/NetworkMesh.cpp`: `PlayerConnection::SendGamePacket` теперь возвращает `k_EResultOK` после успешной отправки/передачи в transport plugin. Ранее успешный путь проваливался в `k_EResultFail`. Повторная отправка сохраняет префикс `NETWORK_CHANNEL_GAME`; прежний fallback отправлял необрамлённый `pBuffer`, что несовместимо с ожидаемым framing при приёме.
- `CMakePresets.json`: `SAGE_USE_DETERMINISTIC_MATH=ON` добавлен в общий `default-vcpkg`, чтобы наследующие его современные Windows/Linux/macOS пресеты использовали детерминированную математику. VC6-пресеты не менялись.
- `.github/workflows/build-ios-shell.yml`: добавлена только новая рабочая ветка в список push-триггеров; A12/A13 workaround и Vulkan 1.2/1.3 настройки не менялись.

### Проверки и ограничения
- Статическая проверка исходников подтвердила: успешный send возвращает OK; fallback повторно использует framed `vecData`, а не сырой `pBuffer`; CMakePresets.json разбирается как валидный JSON; iOS workflow по-прежнему содержит A12/A13 workaround `samplerMirrorClampToEdge=VK_FALSE`.
- Нативная сборка этой ветки и реальный матч iOS↔Android/Windows/Linux/macOS пока НЕ подтверждены. Успех межплатформенной синхронизации не заявлять до парных логов/CRC с одного матча.
- Android reference repo `MYSOREZ/GeneralsZH-Android-Port` имеет `SAGE_USE_DETERMINISTIC_MATH` по умолчанию OFF в `cmake/gamemath.cmake`, а workflow `.github/workflows/build-android.yml` не передаёт эту опцию. Сам reference repo не менялся. Поэтому полная math-детерминированность iOS↔Android пока не обеспечена этим PR; нужно согласовать/проверить соответствующую настройку в фактическом Android build, который использует пользователь.
- Render не менялся: он публикует web launcher, но не управляет локальной папкой модов и не может сам исправить игровые пакеты.


## Новая диагностика лога и исправление сохранения графики (2026-10-10, продолжение)

### Лог пользователя: `logs/generals-stderr.log`
- Прочитан raw-файл из ветки `logs`; размер 716,719 байт, 7,831 строк.
- Стартовый лог показывает iOS build `1.4 build=601`, API `playgenerals.online` отвечает HTTP 200, имя лобби содержит `[iOS]`. Это подтверждает регистрацию/получение данных лобби, но не подтверждает межплатформенную синхронизацию симуляции.
- Сеть: в этом логе несколько раз для peer/user `81311` возникает SteamNetworking reason `5003: Timed out attempting to connect`; повтор сигнализации исчерпан на `2/2`, затем происходит локальное удаление peer. Есть сообщение `Invalid lane count 1; Connection only has 0 lanes configured`. Лог также показывает лобби `152685` с 7 игроками из 8 и `Lobby is full` при некоторых попытках присоединения; нельзя автоматически считать все эти события причиной desync — они могут относиться к другим попыткам подключения в лобби-браузере.
- В логе есть `[ONLINE-CRC-TRACE]` с кадрами 0/100/200 и подробным CRC-дампом объектов для frame 200, после чего отображается `Menus/ScoreScreen.wnd`. Это одна сторона; без лога Android/PC участника и CRC того же матча/кадра нельзя доказать равенство или расхождение симуляции.
- Графическая диагностика: `bitDepth=16`, `filter=0`, `anisotropy=4`, `msaa=0`, заявлены pixel shader `0xffff0104` и vertex shader `0xfffe0101`. В этом логе нет подтверждения, что опции игры были записаны в файл; `[HUB-SETTINGS] web saved profile='online'` относится к web-настройкам профиля, а не к факту сохранения всех engine graphics options.
- `ios/config/Options.ini` в репозитории — только короткий шаблон (LOD, TextureReduction, HeatEffects, DynamicLOD); реальный iOS путь в `IOSProfileLauncher.mm` и `GlobalData::BuildUserDataPathFromRegistry()` совпадает: `~/Library/Application Support/GeneralsX/GeneralsZH/Options.ini`. Поэтому не объявлять путь причиной без проверки фактического файла устройства.

### Исправление, внесённое в отдельную ветку
- Создана ветка `fix/ios-graphics-settings-persistence` от `generealss-spideywv`; `a13-ios-build`, русский `IOSProfileLauncher` и `build-ios-shell.yml` не изменялись.
- Коммит: `54d5ed30899cef867d9e20bbb76da49e1c5e3908` — `Fix saving updated graphics options`.
- Файл `GeneralsMD/Code/GameEngine/Source/GameClient/GUI/GUICallbacks/Menus/OptionsMenu.cpp`: при сохранении шести параметров запись в `Options.ini` брала значения из `TheGlobalData` вместо обновлённых `TheWritableGlobalData`: `UseCloudMap`, `UseLightMap`, `ShowSoftWaterEdge`, `ExtraAnimations`, `DynamicLOD`, `HeatEffects`. Все шесть сохранений теперь читают writable instance, где соответствующие UI значения только что обновлены.
- 2D/3D shadow keys уже записывались из `TheWritableGlobalData`, но этот блок advanced graphics settings выполняется только при выборе `StaticGameLOD = Custom`. Для штатного игрового меню нужно выбрать Custom и нажать подтверждение расширенных параметров, затем подтвердить основное меню.
- Отдельного подтверждённого параметра «reflections» в текущем `OptionsMenu.cpp` не найдено; не добавлять декоративный переключатель без реализации в renderer/engine.
- На момент записи Actions/build и реальный повторный тест на устройстве ещё не проверены. Не заявлять, что сохранение или синхронизация уже исправлены.

### Следующие обязательные проверки
1. Проверить Actions для `54d5ed30899cef867d9e20bbb76da49e1c5e3908`; если будет ошибка — скачать артефакт/лог и исследовать локально.
2. На iOS изменить один из параметров (например, Dynamic LOD/Heat Effects), сохранить, перезапустить игру, проверить содержимое `~/Library/Application Support/GeneralsX/GeneralsZH/Options.ini` и фактическое значение при повторном открытии меню.
3. Проверить 2D/3D shadows при `StaticGameLOD=Custom`; не обещать аппаратно полноценные тени/отражения только по наличию чекбоксов.
4. Для межплатформенной синхронизации запросить лог Android/PC второй стороны того же матча. Сравнить build/revision, карту/режим, сетевой packet/channel/version и CRC на одинаковых кадрах; текущий iOS лог сам по себе не доказывает desync.


### Дополнительная находка: graphics options не применялись при старте
- После первого исправления проверены `OptionPreferences.cpp` и `GlobalData.cpp`: в `OptionPreferences` уже есть getters для 2D/3D shadows, cloud shadows, lightmap, smooth water, trees, extra animations, heat effects, Dynamic LOD, building occlusion и particle cap, но `GlobalData::load` не переносил эти сохранённые значения в `TheWritableGlobalData`.
- Добавлен второй коммит в ту же рабочую ветку: `f1ef78bed0b1a966adc065922e31cce8781a4173` — `Load persisted graphics options at startup`.
- В `GeneralsMD/Code/GameEngine/Source/Common/GlobalData.cpp` сразу после базовых option preferences добавлено применение этих 11 параметров из `OptionPreferences` в writable global data. Это дополняет предыдущий fix, где сохранение шести полей было переключено с `TheGlobalData` на `TheWritableGlobalData`.
- Проверено по заголовку `Core/GameEngine/Include/Common/OptionPreferences.h`, что используемые getters объявлены. Компиляция ещё не выполнена; остаётся проверить Actions и реальный перезапуск игры.


### Корректировка семантики ExtraAnimations
- При ревизии добавленного startup mapping обнаружено, что `getExtraAnimationsDisabled()` уже возвращает значение для `m_useDrawModuleLOD` (это видно по веткам метода и по `OptionsMenu.cpp`). Первоначальная инверсия в строке загрузки была лишней.
- Исправлено в коммите `39f2dd1e91f6570f24337a714b764b1b7242646f`: `m_useDrawModuleLOD = optionPref.getExtraAnimationsDisabled();`. Не использовать дополнительное `!`.
- Ветка сборки `build-ios-shell.yml` сейчас запускается по push только на `main`, `a13-ios-build` и `generealss-spideywv`; рабочая ветка `fix/ios-graphics-settings-persistence` не запускает workflow автоматически. Не заявлять, что Actions проверен. Не менять workflow только ради запуска без необходимости; нужна отдельная разрешённая ручная dispatch-проверка либо запуск на целевой ветке после согласованного переноса.


## 2026-10-10 — Graphics preferences persistence moved to cross-platform sync branch
- User requested running the graphics-preferences persistence build on `fix/mods-visible-cross-platform-sync` because its warmed CI caches should make subsequent builds much faster than the first cold build.
- Commit `0c82bc689ebdcd09ebede0453d82dc7d5bb4d8ff`: OptionsMenu writes the six graphics preference values from `TheWritableGlobalData`, not stale `TheGlobalData`.
- Commit `2657ee883e8a93527138c70c7e1c8543832a679e`: `GlobalData::parseGameDataDefinition` restores persisted graphics preferences at startup, including shadows, cloud/light maps, smooth water, trees, extra animations, heat effects, dynamic LOD, building markers, and particle cap.
- The target branch's `.github/workflows/build-ios-shell.yml` already includes `fix/mods-visible-cross-platform-sync` in push triggers, and uses vcpkg binary caching plus ccache restore/save. The file changes match the `GeneralsMD/**` trigger path.
- Protected `a13-ios-build` was not modified. Build completion/status has not yet been independently confirmed.

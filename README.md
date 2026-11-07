# MobaXtermSync

Автономный синхронизатор закладок MobaXterm для нескольких компьютеров под Windows.

Скрипты лежат в папке, синхронизируемой через Yandex.Disk / Syncthing. Журнал операций — append-only набор отдельных JSON-файлов (без общего изменяемого SQLite). Локальные runtime-данные и резервные копии INI хранятся только в `%LOCALAPPDATA%\MobaBookmarkSync\<NodeId>\`.

Требования: Windows PowerShell 5.1+, без сторонних модулей.

## Смысл тегов

Каждая глобальная закладка получает префикс компьютера происхождения:

- `[RM] Home Entware` — впервые создана на компьютере с Tag `RM`
- `[MITX] Octoglass` — впервые создана на `MITX`
- `[LAPTOP] n3050` — впервые создана на `LAPTOP`

Префикс **не меняется** при правках на других компьютерах. В операции обновляется `lastChangedBy`.

Политика **AutoTag**: новые непомеченные закладки на инициализированном компьютере автоматически получают текущий Tag.

## Установка первого компьютера

1. Закройте MobaXterm.
2. Скопируйте/разверните папку синхронизации (должна содержать маркер `.moba-sync-root`).
3. Запустите интерактивный установщик:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1
```

Меню:

1. **DryRun** — классификация закладок без записи  
2. **Install / Reinstall** — путь к `MobaXterm.ini`, Tag, подтверждение  
3. **Edit common settings** — `config\common.json`  
4. **Edit this computer** — Tag, IniPath, Enabled  
5. Status / 6. Ручной sync / 7. Uninstall  

Либо сразу с параметрами (без меню):

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\app\Install-MobaSync.ps1 `
  -Tag RM `
  -IniPath "C:\Users\Vlad\Documents\MobaXterm\MobaXterm.ini" `
  -InitialImportMode AutoTag
```

При пустом журнале `data\operations\` текущий компьютер становится первым источником: все закладки импортируются с префиксом Tag, удаления не создаются.

Установщик регистрирует:

- задание при входе пользователя — `Watch-MobaXterm.ps1` (скрытый наблюдатель);
- еженедельное задание — `Invoke-MobaSync.ps1` (день/время из `config\common.json`).

## Установка следующего компьютера

На втором ПК (та же синхронизируемая папка уже содержит операции первого):

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\app\Install-MobaSync.ps1 `
  -Tag MITX `
  -IniPath "C:\Users\You\Documents\MobaXterm\MobaXterm.ini" `
  -InitialImportMode AutoTag
```

Перед записью выводится классификация:

1. **Точный дубль** — имя и полная строка параметров совпадают → используется глобальная запись.
2. **Вероятный конфликт** — похожий протокол/адрес, но другие детали → обе записи сохраняются, конфликт логируется.
3. **Уникальная локальная** — добавляется с Tag текущего ПК.
4. **Входящая глобальная** — добавляется в локальный INI.

Первая установка **никогда** не трактует отсутствие записи как глобальное удаление.

## DryRun

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\app\Install-MobaSync.ps1 `
  -Tag RM `
  -IniPath "C:\Users\Vlad\Documents\MobaXterm\MobaXterm.ini" `
  -DryRun
```

Ничего не записывается: ни config, ни INI, ни задания Планировщика. Выводится план и классификация.

## Подтверждение массового удаления

Защита от массового удаления: если доля удалений относительно `lastApplied` **строго больше** `MassDeleteLimitPercent`.

В `config\common.json` значение **`100` отключает** эту защиту (текущая настройка по умолчанию). Чтобы снова включить, поставьте например `50`.

Если защита включена и сработала:

- глобальный журнал не меняется;
- создаётся `%LOCALAPPDATA%\MobaBookmarkSync\<NodeId>\pending-delete.json`;
- после проверки INI подтвердите:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\app\Invoke-MobaSync.ps1 -ApprovePendingDelete
```

## Ручной запуск синхронизации

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\app\Invoke-MobaSync.ps1
```

Пока открыт хотя бы один `MobaXterm*.exe`, INI не изменяется: пишется `pending-sync.json`, наблюдатель выполнит синхронизацию после закрытия.

## Перенос синхронизируемой папки

1. Перенесите всю папку целиком (включая `.moba-sync-root`, `config\`, `data\operations\`).
2. SyncRoot **не** хранится в конфиге компьютера — скрипты ищут `.moba-sync-root` вверх от `$PSScriptRoot`.
3. При необходимости обновите только `IniPath` в `config\computers\<COMPUTERNAME>.json`.
4. Переустановите задания Планировщика (см. ниже), если ярлыки/пути заданий устарели.

## Переустановка заданий Планировщика

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\app\Install-MobaSync.ps1 `
  -Tag RM `
  -IniPath "C:\Users\Vlad\Documents\MobaXterm\MobaXterm.ini" `
  -ForceReinstall
```

## Удаление синхронизатора

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\app\Uninstall-MobaSync.ps1
```

Удаляет задания этого компьютера и завершает локальный watcher. **Не** удаляет общий журнал, `MobaXterm.ini` и конфигурации других компьютеров. Локальный runtime-каталог можно сохранить или удалить по запросу.

## Журналы и резервные копии

| Что | Где |
|-----|-----|
| Операции (глобальный журнал) | `data\operations\<UTC>_<NodeId>_<OperationId>.json` |
| Состояние узла | `%LOCALAPPDATA%\MobaBookmarkSync\<NodeId>\state.json` |
| Логи | `%LOCALAPPDATA%\MobaBookmarkSync\<NodeId>\logs\` |
| Бэкапы INI | `%LOCALAPPDATA%\MobaBookmarkSync\<NodeId>\backups\` |
| Отложенная синхронизация | `pending-sync.json` в том же runtime-каталоге |
| Массовое удаление | `pending-delete.json` в том же runtime-каталоге |

Полные копии `MobaXterm.ini` **не** кладутся в синхронизируемую папку.

## Конфигурация

`config\common.json` — общие параметры (`AutoTag`, `DeleteWins`, `DebounceSeconds`, `MassDeleteLimitPercent`, еженедельное расписание).

`config\computers\<COMPUTERNAME>.json` — узел: `NodeId` (постоянный GUID), уникальный `Tag`, явный `IniPath`, флаги `Enabled` / `Initialized`.

## Тесты

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

Без внешних модулей. Покрывают первый/второй компьютер, AutoTag, дубли, удаления, stale-узел, DeleteWins, rename, повреждённый INI, MassDeleteLimit, BOM/CRLF, pending-sync, mutex, битый JSON операции.

# prl

Список открытых pull request'ов в организации GitHub, где текущий пользователь — автор или assignee.

Для каждого PR: дата создания, DRAFT/READY, статус CI, число аппрувов, ссылка и первые три строки описания. Сортировка от старых к новым.

## Запуск

Нужны [GitHub CLI](https://cli.github.com/) (`gh auth login`) и `jq`.

```bash
./prl.sh
```

Организация по умолчанию — `ChatPush`. Можно переопределить:

```bash
ORG=OtherOrg ./prl.sh
```

## Установка

Оставьте git-клон репозитория и сделайте symlink в каталог из `PATH` (обычно `~/.local/bin`). Цель `ln` должна быть **абсолютным** путём — относительная ссылка вроде `prl.sh` указывает на файл рядом с symlink, а не на клон.

Если `~/.local/bin` ещё нет в `PATH`, добавьте в `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Затем:

```bash
mkdir -p ~/.local/bin
chmod +x /path/to/prl/prl.sh
ln -sf /path/to/prl/prl.sh ~/.local/bin/prl
```

`/path/to/prl` — каталог клона. После этого команда `prl` доступна из любой директории.

Обновление: `git pull` в клоне. Symlink пересоздавать не нужно, пока имя файла `prl.sh` не меняется.

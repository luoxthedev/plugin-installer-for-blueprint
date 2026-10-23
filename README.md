# Blueprint plugin installer

Reinstalls [Blueprint](https://blueprint.zip) extensions on a Pterodactyl panel that is **already installed**.

The script does not install Pterodactyl, Blueprint, Node, yarn, or Docker. If either the panel or Blueprint is missing, it stops.

## What it looks for

Pterodactyl, as described in the [panel install guide](https://docs.pterodactyl.io/v1/panel/getting-started):

- `artisan`, `config/pterodactyl.php`, `vendor/autoload.php`
- `composer.json` package name `pterodactyl/panel`
- a non-empty `APP_KEY` in `.env`

Searched in `/var/www/pterodactyl`, then `/var/www/panel` and `/opt/pterodactyl`. Inside the panel container, Blueprint uses `/app`.

Blueprint, as described in the [install guide](https://blueprint.zip/guides/admin/install) and `blueprint.sh`:

- `blueprint.sh`, `scripts/commands/extensions/install.sh` and `scripts/libraries/misc.sh`
- `app/BlueprintFramework`
- a finished install: `db/is_installed` (current releases) or `* blueprint.setupFinished;` in `db/database` (beta-2024-12 and older)

A running [Blueprint Docker](https://github.com/BlueprintFramework/framework-docker) stack is detected from `/srv/pterodactyl/docker-compose.yml`. Extensions are read from `/app` inside the `panel` container (the host `extensions/` folder is only where you drop files; the container syncs them).

## Usage

```bash
sudo bash install.sh
sudo bash install.sh /var/www/pterodactyl
```

Extensions are reinstalled with one `blueprint -install` call, which is the command from the [extensions guide](https://blueprint.zip/guides/admin/extensions). Blueprint then rebuilds assets, refreshes caches, applies the ownership from `.blueprintrc`, and migrates. On Docker, Blueprint skips migrations itself. The Node.js version check follows the Blueprint copy that is already installed (22 on current releases, 17 on beta-2024-12). Missing tools are reported and not installed.

After a panel update, restore Blueprint with [`blueprint -upgrade`](https://blueprint.zip/guides/admin/updateblueprint) before using this script. A wiped `app/BlueprintFramework` is detected and left untouched.

# Charge Limit

Cap where your laptop starts and stops charging, straight from the Omarchy
tray. Keeping a battery around 60–80% dramatically slows its aging when the
machine is mostly plugged in.

Works on any laptop whose battery exposes the standard kernel interface
(`charge_control_end_threshold`) — ThinkPads, ASUS, Framework, many others.

## Install

```sh
omarchy plugin add https://github.com/Confined-/charge-limit.git --enable
```

Then add **Charge Limit** to your bar (Command center → Bar → widgets), or:

```sh
omarchy plugin enable confined.charge-limit right
```

## First use

Open the panel from the tray icon and tap **Grant access**. One polkit prompt
installs two root-owned pieces:

- `/usr/local/bin/battery-charge-limit` — a tiny helper that validates values
  (integers 20–100) and writes them to every battery exposing
  `charge_control_end_threshold`
- `/etc/sudoers.d/battery-charge-limit` — a sudoers drop-in allowing your user
  passwordless execution of *that helper only* (validated with `visudo -c`
  before activation)

After that, all changes are instant and passwordless.

## Use

**Click the bar item. That's it.**

- ON — charging stops at **80%** and resumes below **70%**
  (`charge_control_end_threshold=80`, `charge_control_start_threshold=70`).
- OFF — both reset to the kernel default (100/0).

The icon shows `󰁼 80%` while active and a plain battery glyph when off; hover
for battery status. The first click prompts once via polkit to install the
helper + sudoers rule; every later toggle is instant and passwordless.

If **Apply after reboot** is on (default, see Configure), an
`omarchy post-boot.d` hook re-applies your last state at login.

## Configure

Entry settings in `~/.config/omarchy/shell.json` (`bar.layout.*` →
`confined.charge-limit`):

| Key              | Type    | Default | Description                          |
|------------------|---------|---------|--------------------------------------|
| `pollIntervalSec`| integer | 30      | How often the tray state refreshes   |
| `applyAtBoot`    | boolean | true    | Re-apply the limit after reboot      |

## Uninstall

```sh
omarchy plugin remove confined.charge-limit
sudo rm -f /usr/local/bin/battery-charge-limit /etc/sudoers.d/battery-charge-limit
rm -rf ~/.local/state/battery-charge-limit ~/.config/omarchy/hooks/post-boot.d/post-boot.sh
```

Removing the plugin does not change your hardware's current limit.

## Requirements

- Omarchy 4 (Quattro) shell
- A battery exposing `/sys/class/power_supply/BAT*/charge_control_end_threshold`
- `polkit`/`pkexec` (preinstalled on Omarchy)

Multiple batteries are supported — the limit is applied to all of them.

## License

MIT — see [LICENSE](LICENSE).

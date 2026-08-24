# Charge Limit

One-click **80% battery charge limit** toggle for Omarchy. Keeping a lithium
battery at 80% dramatically slows its aging when the machine spends
most of its time plugged in.

Click the lightning bolt in the bar: charging stops at **80%** and resumes
below **70%**. Click again to remove the limit entirely (100/0).

## Install

```sh
omarchy plugin add https://github.com/Confined-/charge-limit.git --enable
```

Requires a battery exposing the kernel interface
`/sys/class/power_supply/BAT*/charge_control_end_threshold`
(ThinkPads, ASUS, Framework, and many others). Multiple batteries are supported.
On unsupported hardware the bolt stays dimmed and the tooltip says so.

## Use

- **Left/right-click the bar item** to toggle the limit on or off.
- Icon is a lightning bolt in your theme's accent color while active, muted
  gray when off or unsupported.
- Hover the icon for status: limit state, battery percentage, charging.
- The first click asks once via polkit (fingerprint/password) to install two
  root-owned pieces:
  - `/usr/local/bin/battery-charge-limit` — a helper that validates values
    (integers, start < end) and writes them to every qualifying battery;
    it can only set these two sysfs files
  - `/etc/sudoers.d/battery-charge-limit` — a sudoers drop-in allowing your
    user passwordless execution of exactly `that helper set …` (validated with
    `visudo -c` before activation)

Every later toggle is instant and passwordless. Your hardware keeps whatever
limit was last applied even if you uninstall the plugin.

### Re-apply after reboot

With the default `applyAtBoot: true`, each successful toggle saves its state
and installs an `omarchy post-boot.d` hook (`confined.charge-limit.sh`) that
re-applies the saved values at desktop start. Set `applyAtBoot` to `false` to
disable this; the hook then removes itself on the next toggle.

## Configure

Entry settings in `~/.config/omarchy/shell.json` (`bar.layout.*` →
`confined.charge-limit`):

| Key               | Type    | Default | Description                        |
|-------------------|---------|---------|------------------------------------|
| `pollIntervalSec` | integer | 30      | How often the bar state refreshes  |
| `applyAtBoot`     | boolean | true    | Save state + install the boot hook |

The limits themselves are fixed at 80/70 in v1.

## Uninstall

```sh
omarchy plugin remove confined.charge-limit
rm -f ~/.config/omarchy/hooks/post-boot.d/confined.charge-limit.sh
rm -rf ~/.local/state/battery-charge-limit
sudo rm -f /usr/local/bin/battery-charge-limit /etc/sudoers.d/battery-charge-limit
```

`omarchy plugin remove` alone deletes only the plugin folder — run the three
extra lines to fully remove the boot hook, saved state, root helper, and
passwordless sudoers rule. The last line needs sudo because that privilege is
the plugin's whole purpose; everything it grants is listed above.

## Security notes

- No plugin code runs at install time; privileged setup happens only when you
  click and approve the polkit prompt.
- The sudoers rule grants exactly one command shape:
  `/usr/local/bin/battery-charge-limit set *`. The helper validates both
  integers and rejects start ≥ end before touching sysfs.
- When running as root the helper ignores all environment overrides: it always
  writes to `/sys/class/power_supply` and never dry-runs. The test-only sysfs
  redirect works solely for unprivileged callers against a user-owned tree.
- Multi-battery updates are transactional: if any battery rejects a value,
  every battery already changed is restored to its previous state before the
  error is reported.
- The helper refuses to write user state when invoked as root, and its
  version is checked against the plugin on every poll so stale deployments
  surface immediately instead of failing silently.

## License

MIT — see [LICENSE](LICENSE).

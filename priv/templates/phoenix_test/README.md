# Phoenix_test integration templates

Source files copied verbatim (with module-name substitution) into an
operator's project by `mix soot.gen.phoenix_test`.

These are **not** loaded by Soot's own application or test suite —
they live in `priv/` so they can be authored and reviewed as plain
Elixir rather than as strings inside an Igniter task.

## Placeholder names

The igniter rewrites these tokens at copy time:

| Token         | Replaced with                                  |
| ------------- | ---------------------------------------------- |
| `MyAppWeb`    | Operator's web module (e.g. `MyIotWeb`)        |
| `MyApp`       | Operator's app module (e.g. `MyIot`)           |
| `:my_app`     | Operator's app atom (e.g. `:my_iot`)           |

Substitution is in that order — `MyAppWeb` first so it doesn't get
clobbered by the more general `MyApp` rule.

## What's covered

- `home_test.exs` — `/` renders.
- `auth_test.exs` — `/sign-in` renders; `/admin` redirects when
  unauthenticated.
- `admin_test.exs` — registers a user, signs them in via session,
  visits `/admin` and `/admin/devices`.

These are deliberately minimal smoke tests: they prove the router is
wired, the auth gate is in effect, and the admin LiveViews mount.
Operators are expected to extend the suite with their own scenarios
once they own the file.

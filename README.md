# cardputer-pwnagotchi

Pwnagotchi APPLaunch client for CardputerZero, implemented in the same style as `cardputer-xiaozhi`:
- C++ app loop for input and page state
- Python bridge for local `pwnagotchi` / `bettercap` aggregation
- Python framebuffer renderer for small-screen UI

## Features

- Three native pages: `Home`, `Stats`, `Control`
- Local status aggregation from:
  - `systemd` service state
  - `bettercap` REST session endpoint
  - `config.toml`
  - handshake directory counts
- Control actions:
  - `Start`
  - `Stop`
  - `Restart`
  - `Manual`
  - `Auto`
- APPLaunch `.deb` packaging
- Bootstrap script for fresh `jayofelony/pwnagotchi` installs

## Build

Stub build:

```bash
bash ./build.sh
```

Simulator build:

```bash
bash ./build.sh --sim
```

Device build:

```bash
bash ./build.sh --device
```

Package build:

```bash
bash ./build.sh --aarch64 --package
```

## Environment

See [.env.template](/Users/jdaie/repositories/m5stack/cardputer-pwnagotchi/.env.template).

Supported variables:
- `PWNAGOTCHI_CONFIG`
- `PWNAGOTCHI_HANDSHAKES_DIR`
- `PWNAGOTCHI_SERVICE_NAME`
- `BETTERCAP_API_URL`
- `BETTERCAP_USERNAME`
- `BETTERCAP_PASSWORD`

## Runtime layout

- [main/src/application.cpp](/Users/jdaie/repositories/m5stack/cardputer-pwnagotchi/main/src/application.cpp)
  Page state machine and input handling
- [main/src/pwnagotchi_client.cpp](/Users/jdaie/repositories/m5stack/cardputer-pwnagotchi/main/src/pwnagotchi_client.cpp)
  C++ to Python bridge transport
- [main/tools/pwnagotchi_bridge.py](/Users/jdaie/repositories/m5stack/cardputer-pwnagotchi/main/tools/pwnagotchi_bridge.py)
  Local aggregation and service control
- [main/tools/display_bridge.py](/Users/jdaie/repositories/m5stack/cardputer-pwnagotchi/main/tools/display_bridge.py)
  Framebuffer rendering

## Notes

- `Manual` / `Auto` switching is implemented through `/etc/default/pwnagotchi-cardputer` plus a systemd override wrapper installed by `tools/install.sh`.
- On an existing device, run the packaged installer first so the service override exists before using mode switching.

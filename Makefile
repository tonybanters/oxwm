include config.mk

build:
    $(CARGO) build $(PROFILE)

install: build
    cp -f target/$(PROFILE)/oxwm $(PREFIX)/bin/oxwm
    chmod 755 $(PREFIX)/bin/oxwm
    echo "[done] oxwm installed. Restart X or hit Mod+Shift+R"

uninstall:
    rm -f $(PREFIX)/bin/oxwm

clean:
    $(CARGO) clean

test:
    pkill Xephyr || true
    Xephyr -screen 1280x800 :1 & sleep 1
    DISPLAY=:1 cargo run

#!/usr/bin/env bash

#
# This script is autostarted from dwm.c:
#   scan();
#   system("$HOME/.config/dwm/autostart.sh &");
#   run();
#

###############################################################################
# Start status bar as a background process
###############################################################################

(exec -a dwmbar_extra sh -c "$(cat <<'EOF'
while true; do

    #################################################
    # Battery
    #################################################
    batt=""
    if [ -d /sys/class/power_supply/BAT0 ]; then
        cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)
        stat=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null)

        symbol="BAT"
        [ "$stat" = "Charging" ] && symbol="CHG"
        [ "$stat" = "Discharging" ] && symbol="BAT"

        batt="$symbol $cap%"
    fi

    #################################################
    # PipeWire / PulseAudio Volume
    #################################################
    vol=""
    if command -v wpctl >/dev/null 2>&1; then

        # Extract default sink ID
        sink=$(
            wpctl status 2>/dev/null \
            | awk '
                /Sinks:/ { s=1; next }
                s && /\*/ {
                    for(i=1;i<=NF;i++) {
                        if ($i ~ /^[0-9]+\.$/) {
                            print substr($i,1,length($i)-1)
                            exit
                        }
                    }
                }
            '
        )

        if [ -n "$sink" ]; then
            line=$(wpctl get-volume "$sink" 2>/dev/null)

            if echo "$line" | grep -q "MUTED"; then
                vol="VOL Muted"
            else
                pct=$(echo "$line" | awk '{print int($2*100)}')
                vol="VOL ${pct}%"
            fi
        fi

    elif command -v pactl >/dev/null 2>&1; then

        sink=$(pactl info 2>/dev/null | grep "Default Sink" | awk '{print $3}')

        if [ -n "$sink" ]; then
            mute=$(pactl get-sink-mute "$sink" 2>/dev/null | grep -o "yes\|no")
            if [ "$mute" = "yes" ]; then
                vol="VOL Muted"
            else
                pct=$(pactl get-sink-volume "$sink" 2>/dev/null | head -1 | awk '{print $5}' | tr -d "%")
                vol="VOL ${pct}%"
            fi
        fi

    fi

    #################################################
    # Wi-Fi
    #################################################
    wifi=""
    if command -v nmcli >/dev/null 2>&1; then
        wifi_state=$(nmcli -t -f WIFI g 2>/dev/null)
        if [ "$wifi_state" = "enabled" ]; then
            ssid=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | grep "^yes:" | cut -d ":" -f 2)
            [ -z "$ssid" ] && ssid="Disconnected"
            wifi="WIFI $ssid"
        else
            wifi="WIFI Off"
        fi
    fi

    #################################################
    # Clock
    #################################################
    time="$(date '+%Y-%m-%d %I:%M:%S %p')"

    #################################################
    # Update DWM bar
    #################################################
    xsetroot -name "${batt} | ${wifi} | ${vol} | ${time}"
    sleep 1

done
EOF
)") &

###############################################################################
# Startup applications
###############################################################################

export GTK_THEME="Adwaita:dark"

# Notification daemon
dunst &

###############################################################################
# Wallpaper
###############################################################################

WALLPAPER=""
if [ -f "$HOME/.config/dwm/wallpaper/drwp1.jpeg" ]; then
    WALLPAPER="$HOME/.config/dwm/wallpaper/drwp1.jpeg"
elif [ -f "/usr/local/share/dwm/wallpaper/drwp1.jpeg" ]; then
    WALLPAPER="/usr/local/share/dwm/wallpaper/drwp1.jpeg"
fi

if [ -n "$WALLPAPER" ] && [ -f "$WALLPAPER" ]; then
    if command -v feh >/dev/null 2>&1; then
        feh --bg-scale "$WALLPAPER" &
    elif command -v nitrogen >/dev/null 2>&1; then
        nitrogen --set-scaled "$WALLPAPER" &
    elif command -v xwallpaper >/dev/null 2>&1; then
        xwallpaper --zoom "$WALLPAPER" &
    fi
fi


# WiFiHop

A macOS menu bar app for homes with several Wi-Fi networks under different names. When the signal gets weak, it moves the Mac to whichever of your networks is stronger.

## The problem

macOS stays on the network it joined until the connection drops completely. If your home has two routers with different names, the Mac keeps the far one at one bar while you sit next to the other. You have to open the Wi-Fi menu and switch by hand every time you change rooms.

## Do you need it?

You need it if your routers or extenders broadcast different network names and you can't change that.

You don't need it if:

- A mesh system gives you one network name everywhere. The Mac already roams between access points that share a name.
- You can rename the networks. Giving every router the same name and password is the simpler fix.

## Requirements

- macOS 13 or later.
- Apple's command line tools to build it. Install them with `xcode-select --install`.
- Full Xcode if you want to run the tests.

## Install

Clone this repository, then run:

```sh
./build.sh
```

The script builds the app, copies it to `~/Applications/WiFiHop.app`, and starts it. A router icon appears in the menu bar, and WiFiHop adds itself to your login items. You can turn that off in Settings.

## Set up

Settings opens by itself on first launch.

1. Tick the networks that belong to your home. You need at least two.
2. Type each network's password and press Save.
3. Pick how eagerly it should switch, or leave it on Balanced.

The list shows networks this Mac has joined before and can see right now. If one is missing:

- A router at the far end of your home may be out of range. Carry the Mac closer and press Rescan, or tick "Show saved networks that are out of range".
- If the Mac has never joined the network, join it once from the Wi-Fi menu and press Rescan.

## How it decides

WiFiHop reads the signal strength every 10 seconds.

1. When the signal stays below the weak threshold for three readings in a row, it looks for your other ticked networks.
2. It switches only if one of them is stronger by at least the required gain.
3. After a switch it waits 60 seconds before considering another.
4. If a network rejects a join, WiFiHop skips it for 10 minutes.

It acts only while the Mac is on one of the ticked networks. On a phone hotspot or at the office it does nothing.

A switch drops the connection for about 3 to 5 seconds, so a video call will stutter when it happens.

| Setting  | Weak threshold | Required gain |
|----------|----------------|---------------|
| Sooner   | -65 dBm        | 8 dB          |
| Balanced | -70 dBm        | 10 dB         |
| Later    | -75 dBm        | 12 dB         |

Sooner suits homes where a wall cuts the signal off sharply. Later suits people who would rather keep a slow connection than interrupt a call.

## What it does with your passwords

WiFiHop keeps each password in your login Keychain, in an item named `WiFiHop: <network>`.

To join a network it runs Apple's `networksetup -setairportnetwork` and passes the password as an argument. While that command runs, which takes a few seconds, other programs on the same Mac can read the password from the process list.

It works this way because of two macOS restrictions. macOS refuses the direct Wi-Fi join call from an app that isn't signed with an Apple Developer ID. And macOS won't reuse its own saved Wi-Fi password when another program asks it to join.

WiFiHop doesn't ask for Location permission and makes no network requests of its own.

## Limits

- It supports networks with an ordinary Wi-Fi password. It doesn't support open networks or enterprise logins with a username.
- Every build counts as a new app to the Keychain. After you rebuild, macOS asks for your login password the first time WiFiHop reads a stored Wi-Fi password. Choose Always Allow, or enter the Wi-Fi passwords again in Settings.
- The app isn't notarized. A copy sent to another Mac is blocked until its owner chooses Open Anyway in System Settings. Building from source avoids that.
- It has been run on macOS 27.2 only.

## Command line

The app's executable accepts three commands, which help when something isn't working.

```sh
APP=~/Applications/WiFiHop.app/Contents/MacOS/WiFiHop

# List the saved networks in range and their signal.
$APP --survey

# Join a network now with its stored password.
$APP --join "Network name"

# Store a password read from standard input.
$APP --set-password "Network name" < password.txt
```

## Troubleshooting

WiFiHop logs every scan and decision to `~/Library/Logs/WiFiHop.log`. Show Log in the menu opens it.

To try a threshold that isn't one of the three presets, override a single value from Terminal. The running app picks the change up within 10 seconds.

```sh
defaults write local.wifihop weakRSSI -int -68
defaults delete local.wifihop weakRSSI
```

The other keys are `minImprovement`, `weakSamples`, `switchCooldown`, `rescanInterval` and `failedJoinBackoff`.

## Uninstall

1. Turn off "Start at login" in Settings, then quit WiFiHop from its menu.
2. Delete `~/Applications/WiFiHop.app`.
3. Run `defaults delete local.wifihop`.
4. In Keychain Access, delete the items named `WiFiHop: <network>`.
5. Delete `~/Library/Logs/WiFiHop.log`.

## Development

```sh
swift test
```

`Sources/RoamCore` holds the switching rules and the setup list. It has no access to Wi-Fi, so the tests run it without a radio. `Sources/WiFiHop` is the app: the timer loop, the Wi-Fi and Keychain calls, the menu, and the Settings window.

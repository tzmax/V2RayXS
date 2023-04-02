# V2RayXS: A simple GUI for Xray on macOS

[![GitHub release (latest SemVer)](https://img.shields.io/github/v/release/tzmax/V2RayXS)](https://github.com/tzmax/V2RayXS/releases)
![GitHub release (latest by date)](https://img.shields.io/github/downloads/tzmax/V2RayXS/latest/total)
[![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/tzmax/V2RayXS/build-actions.yml)](https://github.com/tzmax/V2RayXS/actions/workflows/build-actions.yml)

**Attention**: If you want to use v2ray-core version please install the original project. <https://github.com/Cenmrev/V2RayX>

> This repo is based on the [Cenmrev/V2RayX](https://github.com/Cenmrev/V2RayX) project for maintenance and update, uses the [Xray-core](https://github.com/XTLS/Xray-core) implementation to support the VLESS and XTLS protocol, and the copyright of the application belongs to the original author [@Contents](https://github.com/Cenmrev). Pay tribute to [@Contents](https://github.com/Cenmrev), Thanks to the [@XTLS](https://github.com/XTLS) community and all contributors

## What is XTLS? Xray?

**READ THIS**: [XTLS? Xray? V2Ray?](https://xtls.github.io).

**YOU SHOULD READ XTLS'S OFFICIAL INSTRUCTION BEFORE USING V2RAYXS!**

## What is Tun Mode? (Experimental)

**Warn**: You must read this part of the document before using tun mode.

First of all, please note that this function is an experimental function and is still under development and design. Due to the particularity of the tun mode, I hope you can use it after fully understanding it.

This mode adopts the tun2socks method to forward all traffic, realizes the creation of a utun virtual network card device, and transmits the traffic of the tun device to your server through the socks5 proxy, and then the application sets up the routing table, and sets the default gateway to this tun device (please Note that this step may cause the default gateway routing settings of your device to be damaged. Although I have done a backup and repair process in the application, I cannot guarantee that it will be effective on all devices, please use it with caution!)

Finally, if you are interested in this technology, you can also try to contact me or submit a PR to help me improve this function. If you can recommend this software to friends or post a blog and be able to link this project in other post replies, I will Very happy 😋, thank you for your attention and contribution (Welcome to contribute documents in other languages)

1. Please understand what transparent proxy is (recommended reference this page [What is a transparent proxy?](https://xtls.github.io/Xray-docs-next/document/level-2/transparent_proxy/transparent_proxy.html)), if PAC mode and global mode can meet your needs, please try to use it.

2. You have a certain understanding of the computer network and can solve the network problem of your device independently.

### Have you encountered a problem?

Q: After using tun mode, the device is disconnected from the network? 

A: It may be that the route of the default gateway is broken. You can check your routing table by executing the `netstat -r` command through the device terminal. Normally, there will be a `default` route, as follows

```
tzmaxdeMacBookPro: tzmax$ netstat -r
Routing tables

Internet:
Destination        Gateway            Flags           Netif Expire
default            192.168.1.1        UGScg             en0       
127                localhost          UCS               lo0       
localhost          localhost          UH                lo0    
………
```

Q: How to fix you gateway? (if you can't access the Internet after turning off tun mode after using tun mode, you can try to fix it like this. If it still doesn't work, you can try to restart your device)

A: If you know your default gateway, after turning off tun mode, you can set the default gateway through the `/sbin/route add -net` command

for example: `sudo /sbin/route add -net default 192.168.1.1`

Q: Which tun device does the V2RayXS create?

A: The name of the tun device on macos will be determined by the system, but the tun device created by V2RayXS will be bound to the `10.0.0.0` network segment by default, which can be used as a reference to find

for more questions, you can also check issues first, and submit issues if you do not find a solution.

## Download V2RayXS

Download from [Releases](https://github.com/tzmax/V2RayXS/releases).

## How to build

V2RayXS.app is built by running one of the following commands in your terminal. You can install this via the command-line with curl.

`sh -c "$(curl -fsSL https://raw.githubusercontent.com/tzmax/V2RayXS/master/compilefromsource.sh)"`

or step by step:

`git clone --recursive https://github.com/tzmax/V2RayXS.git`

open V2RayXS.xcodeproj and use Xcode to build V2RayXS.

## How does V2RayXS work

V2RayXS provides a GUI to generate the config file for V2Ray. It includes Xray's binary executable in the app bundle. V2RayXS starts and stops V2Ray with `launchd` of macOS.

V2RayXS also allows users to change system proxy settings and switch proxy servers on the macOS menu bar.

As default, V2RayXS will open a socks5 proxy at port `1081` as the main inbound, as well as a http proxy at port `8001` as an inboundDetour.

V2RayXS provide three modes:

-   Global Mode: V2RayXS asks macOS to route all internet traffic to xray core if the network traffic obeys operating system's network rules.
-   PAC Mode: macOS will determine the routing based on a pac file and some traffic may be routed to xray core.
-   Manual Mode: V2RayXS will not modify any macOS network settings, but only start or stop xray core.
-   Tun Mode (**Experimental**): V2RayXS will create a virtual network card, and then try to set the default gateway to take over and proxy the full traffic of the device.


Options in menu list `Routing Rule` determine how xray core deals with incoming traffic. Core routing rules apply to all three modes above.

### auto-run on login

Open macOS System Preferences -> Users & Group -> Login Items, add V2RayXS.app to
the list.

### manually update xray-core

replace `V2RayXS.app/Contents/Resources/v2ray` with the newest xray
version from [xray-core
repo](https://github.com/XTLS/Xray-core/releases). However, compatibility is not guaranteed.

> If you want to use v2ray-core version please install the original project. <https://github.com/Cenmrev/V2RayX>

### Uninstall

V2RayXS will create the following files and folders:

-   `/Library/Application Support/V2RayXS`
-   `~/Library/Application Support/V2RayXS`
-   `~/Library/Preferences/cenmrev.V2RayXS.plist`

So, to totally uninstall V2RayXS, just delete V2RayXS.app and the files above. :)

## Acknowledge

This repo is based on the [Cenmrev/V2RayX](https://github.com/Cenmrev/V2RayX) project for maintenance and update.

V2RayXS uses [GCDWebServer](https://github.com/swisspol/GCDWebServer) to provide a local pac server. V2RayXS also uses many ideas and codes from [ShadowsocksX](https://github.com/shadowsocks/shadowsocks-iOS/tree/master), especially, the codes of [v2rays_sysconfig](https://github.com/tzmax/V2RayXS/blob/master/v2rayx_sysconf/main.m) are simply copied from [shadowsocks_sysconf](https://github.com/shadowsocks/shadowsocks-iOS/blob/master/shadowsocks_sysconf/main.m) with some modifications.

## Donation

If Project V2Ray or V2RayX (V2RayXS) helped you, you can also help us by donation **in your will**. 

To donate to Project V2Ray, you may refer to [this page](https://www.v2ray.com/chapter_00/02_donate.html).

To donate to Project Xray, you may refer to [this page](https://xtls.github.io/#%E5%B8%AE%E5%8A%A9-xray-%E5%8F%98%E5%BE%97%E6%9B%B4%E5%BC%BA).

## Disclaimer

V2rayXS will not be updated frequently. Users can replace V2RayXS.app/Contents/Resources/xray with the newest Xray-core downloaded from <https://github.com/XTLS/Xray-core/releases>.

The developer currently does not have enough time to add more features to V2RayXS. However, welcome to the contribution at any time, and the fork and your own version.

# V2RayX: A simple GUI for V2Ray on macOS

[![Build Status](https://travis-ci.org/tzmax/V2RayXS.svg?branch=master)](https://travis-ci.org/tzmax/V2RayXS)

**Attention**: If you want to use v2ray-core version please install the original project. <https://github.com/Cenmrev/V2RayX>

> This repo is based on the [Cenmrev/V2RayX](https://github.com/Cenmrev/V2RayX) project for maintenance and update, uses the [Xray-core](https://github.com/XTLS/Xray-core) implementation to support the VLESS and XTLS protocol, and the copyright of the application belongs to the original author [@Contents](https://github.com/Cenmrev). Pay tribute to [@Contents](https://github.com/Cenmrev), Thanks to the [@XTLS](https://github.com/XTLS) community and all contributors


## What is V2Ray?

**READ THIS**: [Project V2Ray](http://www.v2ray.com).

**YOU SHOULD READ V2RAY'S OFFICIAL INSTRUCTION BEFORE USING V2RAYX!**

> ~~Other V2Ray clients on macOS: [V2RayU](https://github.com/yanue/v2rayu).
(Not related to or endorsed by authors of this repo. USE AT YOUR OWN RISK. The project may have failed.)~~

## What is XTLS? Xray?

**READ THIS**: [XTLS? Xray? V2Ray?](https://xtls.github.io).

**YOU SHOULD READ XTLS'S OFFICIAL INSTRUCTION BEFORE USING V2RAYXS!**
## Download V2RayX

Download from [Releases](https://github.com/tzmax/V2RayXS/releases). (compiled by [travis-ci.org](https://travis-ci.org/tzmax/V2RayXS)).

By [Homebrew-Cask](https://caskroom.github.io/).

```sh
brew cask install v2rayx
```

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

V2RayXS uses [GCDWebServer](https://github.com/swisspol/GCDWebServer) to provide a local pac server. V2RayXS also uses many ideas and codes from [ShadowsocksX](https://github.com/shadowsocks/shadowsocks-iOS/tree/master), especially, the codes of [v2rays_sysconfig](https://github.com/tzmax/V2RayXS/blob/master/v2rayx_sysconf/main.m) are simply copied from [shadowsocks_sysconf](https://github.com/shadowsocks/shadowsocks-iOS/blob/master/shadowsocks_sysconf/main.m) with some modifications.

## Donation

If Project V2Ray or V2RayX (V2RayXS) helped you, you can also help us by donation **in your will**. 

To donate to Project V2Ray, you may refer to [this page](https://www.v2ray.com/chapter_00/02_donate.html).

 To donate to Project Xray, you may refer to [this page](https://xtls.github.io/#%E5%B8%AE%E5%8A%A9-xray-%E5%8F%98%E5%BE%97%E6%9B%B4%E5%BC%BA).

## Disclaimer

This tool is mainly for personal usage. For professional users and technique
support, commercial software like proxifier is recommended. Please refer to [#60](https://github.com/tzmax/V2RayXS/issues/60#issuecomment-369531443).

The Maintaining developers need to complete school courses. So V2rayXS will not be updated frequently. Users can replace V2RayXS.app/Contents/Resources/xray with the newest Xray-core downloaded from <https://github.com/XTLS/Xray-core/releases>.

The developer currently does not have enough time to add more features to V2RayXS, nor to merge PRs. However, forking and releasing your own version are always welcome.

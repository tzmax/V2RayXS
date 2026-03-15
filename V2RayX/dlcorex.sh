#!/bin/bash
VERSION="26.2.6"
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NORMAL='\033[0m'

osArch=$(uname -m)
targetArch="${ARCHS:-$osArch}"
case "$targetArch" in
    *arm64*)
        coreArch="arm64"
        archName="arm64-v8a"
        ;;
    *x86_64*)
        coreArch="x86_64"
        archName="64"
        ;;
    *)
        coreArch="$osArch"
        if [[ "$coreArch" == "arm64" ]]; then
            archName="arm64-v8a"
        else
            archName="64"
        fi
        ;;
esac

cd "$SRCROOT"
output="v${VERSION}"
existingArch=""
if [[ -f ./xray-core-bin/xray ]]; then
    archInfo=$(/usr/bin/lipo -info ./xray-core-bin/xray 2>/dev/null || true)
    if [[ "$archInfo" == *"architecture: arm64"* ]] || [[ "$archInfo" == *"are: arm64"* ]]; then
        existingArch="arm64"
    elif [[ "$archInfo" == *"architecture: x86_64"* ]] || [[ "$archInfo" == *"are: x86_64"* ]]; then
        existingArch="x86_64"
    fi

    if [[ "$existingArch" == "$coreArch" ]]; then
        output=$(./xray-core-bin/xray --version)
    fi
fi
existingVersion=${output:5:${#VERSION}}

if [[ "$VERSION" != "$existingVersion" ]] || [[ "$existingArch" != "$coreArch" ]]; then
    getCore=0
    [ -d "xray-core-bin" ] && rm -rf xray-core-bin
    mkdir -p xray-core-bin
    cd xray-core-bin
    curl -s -L -o xray-macos.zip https://github.com/XTLS/Xray-core/releases/download/v${VERSION}/Xray-macos-${archName}.zip
    if [[ $? == 0 ]]; then
        unzip -o xray-macos.zip
        getCore=1
    else
        unzip -o ~/Downloads/xray-macos.zip
        if [[ $? != 0 ]]; then
            getCore=0
        else
            chmod +x xray-macos/xray
            output=$(xray-macos/xray --version)
            existingVersion=${output:5:${#VERSION}}
            echo "existingVersion ${existingVersion}"
            if [[ "$VERSION" != "$existingVersion" ]]; then
                echo "${RED}xray-macos.zip in the Downloads folder does not contain version ${VERSION}."
                echo "下载文件夹里的xray-macos.zip不是${VERSION}版本。${NORMAL}"
                getCore=0
            else
                getCore=1
            fi
        fi
    fi
    if [[ $getCore == 0 ]]; then
        echo "${RED}download failed!"
        echo "Use whatever method you can think of, get xray-macos.zip of version ${VERSION} from xtls.github.io, and put it in the folder 'Downloads' and try this script again."
        echo "用你能想到任何办法，从 xtls.github.io 下载好${VERSION}版本的 xray-macos.zip，放在“下载”文件夹里面，然后再次运行这个脚本。${NORMAL}"
        exit 1
    fi
    chmod +x ./xray
    rm -r xray-*
else
    exit 0
fi

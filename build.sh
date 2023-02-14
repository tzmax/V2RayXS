#!/usr/bin/env bash
###
 # @Author: Bin
 # @Date: 2023-02-14
 # @FilePath: /V2RayXS/build.sh
### 

VERSION=$(git describe --tags --always)
PROJECT_ROOT=$(git rev-parse --show-toplevel)

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NORMAL='\033[0m'
datetime=$(date "+%Y-%m-%dTIME%H%M%S")

useArch=$(uname -m)
if [[ -n "$ARCHS" ]]; then
    useArch="$ARCHS"
fi
if [[ -n "$1" ]]; then
    useArch="$1"
fi

XCODEBUILD_ARGS=(
    -project V2RayXS.xcodeproj 
    -target V2RayXS 
    -configuration Release 
    ARCHS="${useArch}"
)

if [[ ! -f /Applications/Xcode.app/Contents/MacOS/Xcode ]]; then
    echo -e "${RED}Xcode is needed to build V2RayXS, Please install Xcode from App Store!${NORMAL}"
    echo -e "${RED}编译 V2RayXS 需要 Xcode.app，请从 App Store 里安装 Xcode.${NORMAL}"
else
    echo -e "${BOLD}-- Start building V2RayXS --${NORMAL}"
    echo -e "${BOLD}-- 开始编译 V2RayXS --${NORMAL}"
    xcodebuild "${XCODEBUILD_ARGS[@]}"
    if [[ $? == 0 ]]; then
        echo -e "${GREEN}-- Build succeeded --${NORMAL}"
        echo -e "${GREEN}-- 编译成功 --${NORMAL}"
        echo -e "${BOLD}V2RayXS.app: $(pwd)/build/Release/V2RayXS.app${NORMAL}"

        echo -e "${BOLD}-- Start packing --${NORMAL}"
        isbeta=$(git describe --abbrev=0 --tags | grep beta)
        if [[ "$isbeta" != "" ]] 
        then 
            xcodebuild -project V2RayXS.xcodeproj -target V2RayXS -configuration Debug -s
            cd build/Debug/
        else
            cd build/Release/
        fi

        zip -r V2RayXS.app.zip V2RayXS.app && mkdir -p ../out/ && rsync -a V2RayXS.app.zip "../out/V2RayXS_${useArch}.app.zip"
        echo -e "${GREEN}-- Packaging succeeded --${NORMAL}"
        cd ->/dev/null 2>&1

    else
        echo -e "${RED}-- Build failed --${NORMAL}"
        echo -e "${RED}-- 编译失败 --${NORMAL}"
    fi
fi
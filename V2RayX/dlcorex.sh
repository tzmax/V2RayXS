VERSION="1.6.5"
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NORMAL='\033[0m'

cd "$SRCROOT"
output="v${VERSION}"
if [[ -f ./xray-core-bin/xray ]] || [ "$1" == "" ]; then
    output=$(./xray-core-bin/xray --version)
fi
existingVersion=${output:5:${#VERSION}}
osArch=$(uname -m)
if [[ "$VERSION" != "$existingVersion" ]] || [ "$1" != "" ]; then
    getCore=0
    mkdir -p xray-core-bin
    cd xray-core-bin
    osArchName="64" # intel
    if [[ "$osArch" != "x86_64" ]] || [ "$1" == "arm64" ]; then
        osArchName="arm64-v8a" # m1
    fi
    curl -s -L -o xray-macos.zip https://github.com/XTLS/Xray-core/releases/download/v${VERSION}/Xray-macos-${osArchName}.zip
    if [[ $? == 0 ]]; then
        unzip -o xray-macos.zip
        getCore=1
    else
        unzip -o ~/Downloads/xray-macos.zip
        if [[ $? != 0 ]]; then
            getCore=0
        else
            chmod +x xray-${VERSION}-macos/xray
            output=$(xray-${VERSION}-macos/xray --version)
            existingVersion=${output:5:${#VERSION}}
            if [ "$VERSION" != "$existingVersion" ]; then
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
